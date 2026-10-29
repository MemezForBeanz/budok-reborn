extends Node

# Automatic character notes. One queue of characters without notes, fed by
# triggers and drained by workers that only write schemas, each in its own
# context, so the chatbot that is playing does not have to:
#   agent  - a separate notes agent: a headless Claude Code agent that budok
#            starts itself (core/NotesAgent.gd) and that exits when the queue
#            is empty, or any MCP session that asks for work with
#            get_schema_task {"worker": true} (a second chat running the
#            notes_worker prompt).
#   api    - the in-game AI (ai.annotate, needs an API key), in the background.
#   player - only if allowed: the chatbot that is playing, before its first
#            move, and only when no notes agent can do it.
# Triggers (settings schemas.auto.*):
#   match_start - a match starts and its character or opponent has no notes:
#                 they go to the front, and bots wait for them before playing.
#   when=connect - every character without notes, when the game boots and when
#                 a chatbot first claims a slot.

signal changed()

const Util = preload("res://budok/core/Util.gd")
const NotesAgent = preload("res://budok/core/NotesAgent.gd")
const CHECK_INTERVAL := 1.0
const SESSION_IDLE_MS := 120000
const AGENT_CONNECT_MS := 60000
const AGENT_RETRY_MS := 600000
# A job whose worker went away this many times is kept as it is (partial notes).
const MAX_ATTEMPTS := 2
const OPEN := ["queued", "assigned", "running"]

var runtime = null
var jobs := []
var _workers := {}
var _agent := {}
var _agent_error := ""
var _agent_retry_at := 0
var _seen_sessions := {}
var _boot_swept := false
var _timer := 0.0


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	runtime.matches.connect("match_started", self, "_on_match_started")
	runtime.annotator.connect("job_changed", self, "_on_annotator_job")


func setting(key: String, default_value):
	return runtime.config.get_value("schemas.auto." + key, default_value)


func enabled() -> bool:
	return bool(setting("enabled", true))


func api_available() -> bool:
	return bool(setting("use_api", true)) and bool(runtime.llm.describe_role("annotate").get("has_key", false))


# A notes agent is working, starting, or could be started.
func agent_available() -> bool:
	if not bool(setting("use_agent", true)):
		return false
	if _worker_alive() or not _agent.empty():
		return true
	return Util.now_ms() >= _agent_retry_at and NotesAgent.resolve(str(setting("agent_command", "claude"))) != ""


func player_available() -> bool:
	if not bool(setting("use_player", false)):
		return false
	for slot in ["p1", "p2"]:
		if _session_alive(runtime.matches.owners.get(slot, "")):
			return true
	return false


func writer_available() -> bool:
	return api_available() or agent_available() or player_available()


# --- triggers ---

func _on_match_started(info: Dictionary) -> void:
	if not enabled() or not bool(setting("match_start", true)):
		return
	# Opponent first, then your side; both end up at the front of the queue.
	for slot in ["p2", "p1"]:
		var entry = info.get("characters", {}).get(slot)
		if entry is Dictionary and _missing(entry):
			enqueue(entry, "match")


# A chatbot claimed a slot (claim_slot or start_match).
func on_claimed(session_id: String) -> void:
	if session_id == "" or _seen_sessions.has(session_id):
		return
	_seen_sessions[session_id] = true
	if enabled() and str(setting("when", "matches")) == "connect":
		sweep("connect")


func sweep(reason: String) -> int:
	var added = 0
	for entry in runtime.roster.list():
		if not entry["loaded"] or _missing(entry):
			if enqueue(entry, reason):
				added += 1
	return added


func enqueue(entry: Dictionary, reason: String) -> bool:
	for job in jobs:
		if job["name"] == entry["name"]:
			if job["status"] in OPEN:
				if reason == "match" and job["reason"] != "match":
					job["reason"] = "match"
					jobs.erase(job)
					jobs.push_front(job)
					emit_signal("changed")
				return false
			if job["status"] == "done" or job["status"] == "skipped" or (job["status"] == "failed" and reason != "match"):
				return false
			jobs.erase(job)
			break
	var job = {"name": entry["name"], "character": entry["display_name"], "reason": reason, "status": "queued",
		"worker": "", "session": "", "progress": "", "note": "", "attempts": 0}
	if reason == "match":
		jobs.push_front(job)
	else:
		jobs.append(job)
	emit_signal("changed")
	return true


# --- workers ---

func _process(delta: float) -> void:
	_timer += delta
	if _timer < CHECK_INTERVAL:
		return
	_timer = 0.0
	if not enabled():
		return
	if not _boot_swept and str(setting("when", "matches")) == "connect" and (api_available() or agent_available()) and _roster_ready():
		_boot_swept = true
		sweep("boot")
	_requeue_abandoned()
	_run_api_worker()
	_run_agent()


func _run_api_worker() -> void:
	if not api_available():
		return
	for job in jobs:
		if job["status"] == "running" and job["worker"] == "api":
			return
	for job in jobs:
		if job["status"] != "queued" or _defer(job):
			continue
		var entry = _ready_entry(job)
		if entry == null:
			continue
		var started = runtime.annotator.start(entry, false)
		if not started.get("ok", false):
			_finish(job, "failed", str(started.get("error", "could not start")))
			continue
		if started.has("job"):
			job["status"] = "running"
			job["worker"] = "api"
			job["progress"] = str(started["job"].get("progress", ""))
		else:
			_finish(job, "done", str(started.get("message", "")))
		emit_signal("changed")
		return


# Starts the headless notes agent when there is queued work and no notes agent
# is around, and keeps an eye on the one it started.
func _run_agent() -> void:
	if not _agent.empty():
		var running = OS.is_process_running(int(_agent["pid"]))
		if not _agent["sessions"].empty() and running:
			return
		if _agent["sessions"].empty() and running and Util.now_ms() - int(_agent["started_ms"]) <= AGENT_CONNECT_MS:
			return
		if running:
			NotesAgent.stop(int(_agent["pid"]))
		if _agent["sessions"].empty():
			_agent_error = "the notes agent %s; see %s" % ["did not connect to budok within a minute" if running else "stopped before it connected to budok", _agent["log"]]
			var said = NotesAgent.log_tail(_agent["log"])
			if said != "":
				_agent_error += " (it said: %s)" % said
			push_warning("budok: " + _agent_error)
			_agent_retry_at = Util.now_ms() + AGENT_RETRY_MS
		# Its sessions end with it, so their jobs go back to the queue now.
		for session_id in _agent["sessions"]:
			_workers.erase(session_id)
		_agent = {}
		_requeue_abandoned()
		emit_signal("changed")
		return
	if not bool(setting("use_agent", true)) or _worker_alive() or Util.now_ms() < _agent_retry_at:
		return
	var waiting = false
	for job in jobs:
		if job["status"] == "queued" and not _defer(job):
			waiting = true
			break
	if not waiting:
		return
	var started = NotesAgent.spawn(runtime)
	if not started["ok"]:
		_agent_error = started["error"]
		_agent_retry_at = Util.now_ms() + AGENT_RETRY_MS
		emit_signal("changed")
		return
	_agent = {"pid": started["pid"], "started_ms": Util.now_ms(), "log": started["log"], "sessions": {}}
	_agent_error = ""
	print("budok: started a notes agent (%s, pid %d)" % [started["command"], started["pid"]])
	emit_signal("changed")


func _on_annotator_job(annotator_job: Dictionary) -> void:
	for job in jobs:
		if job["character"] == annotator_job.get("character") and job["worker"] == "api" and job["status"] == "running":
			job["progress"] = str(annotator_job.get("progress", ""))
			match str(annotator_job.get("status", "")):
				"done":
					_finish(job, "done", str(annotator_job.get("coverage", "")))
				"partial":
					_finish(job, "partial", str(annotator_job.get("coverage", "")))
				"failed":
					_finish(job, "failed", PoolStringArray(annotator_job.get("errors", [])).join("; "))
			emit_signal("changed")


# The task for an MCP session: its assigned job, or the next queued one.
# Notes workers (as_worker, or sessions that asked as one before) get any job;
# a playing chatbot only when use_player is on and no notes agent can do it.
func task_for(session_id: String, match_only: bool = false, as_worker: bool = false) -> Dictionary:
	if not enabled() or session_id == "":
		return {}
	var worker = as_worker or _workers.has(session_id)
	if worker:
		if not bool(setting("use_agent", true)):
			return {}
		# Worker sessions that appear while the agent runs are taken to be its own.
		if not _agent.empty() and not _workers.has(session_id):
			_agent["sessions"][session_id] = true
		_workers[session_id] = true
	elif not (bool(setting("use_player", false)) and _owns_slot(session_id)) or agent_available():
		return {}
	for job in jobs:
		if job["status"] == "assigned" and job["session"] == session_id:
			if _check_complete(job):
				return task_for(session_id, match_only, as_worker)
			if match_only and job["reason"] != "match":
				return {}
			return _task_view(job)
	for job in jobs:
		if job["status"] != "queued" or _defer(job) or (match_only and job["reason"] != "match"):
			continue
		if _ready_entry(job) == null:
			continue
		job["status"] = "assigned"
		job["worker"] = "agent" if worker else "player"
		job["session"] = session_id
		job["attempts"] += 1
		emit_signal("changed")
		return _task_view(job)
	return {}


func is_worker(session_id: String) -> bool:
	return _workers.has(session_id)


# After a notes submission: finishes the session's job when the notes are complete.
func note_progress(session_id: String, character: String) -> Dictionary:
	for job in jobs:
		if job["status"] == "assigned" and job["session"] == session_id and job["character"] == character:
			if _check_complete(job):
				var next = task_for(session_id)
				return {"finished": character, "next_task": next} if not next.empty() else {"finished": character}
			return {"task": _task_view(job)}
	return {}


func finish_task(session_id: String, character: String, skipped: bool) -> Dictionary:
	for job in jobs:
		if job["status"] == "assigned" and job["session"] == session_id and (character == "" or job["character"] == character):
			if skipped:
				_finish(job, "skipped", "handed back")
			else:
				var coverage = _coverage(job)
				_finish(job, "done" if coverage.get("complete", false) else "partial", coverage.get("text", ""))
			var next = task_for(session_id)
			return {"ok": true, "finished": job["character"], "status": job["status"], "next_task": next if not next.empty() else null}
	return {"ok": false, "error": "no schema task is assigned to this session"}


# --- holding the match for match-start jobs ---

# The match job bots should wait for before playing (unfinished notes for this
# match's characters that a worker is on, or will pick up), or {}.
func blocking_job() -> Dictionary:
	if not enabled() or not bool(setting("match_start", true)):
		return {}
	var names = []
	for slot in ["p1", "p2"]:
		var entry = runtime.matches.match_info.get("characters", {}).get(slot)
		if entry is Dictionary:
			names.append(entry["name"])
	for job in jobs:
		if job["reason"] != "match" or not (job["name"] in names) or not (job["status"] in OPEN):
			continue
		if job["status"] == "queued" and not writer_available():
			continue
		return job
	return {}


func holding() -> bool:
	return not blocking_job().empty()


func summary() -> Array:
	var out = []
	for job in jobs:
		var line = {"character": job["character"], "reason": job["reason"], "status": job["status"]}
		for key in ["worker", "progress", "note"]:
			if str(job[key]) != "":
				line[key] = job[key]
		out.append(line)
	return out


func agent_status() -> Dictionary:
	if not _agent.empty():
		return {"state": "starting" if _agent["sessions"].empty() else "working", "log": _agent["log"]}
	if _worker_alive():
		return {"state": "a notes worker chat is connected"}
	if _agent_error != "":
		return {"state": "error", "error": _agent_error}
	if bool(setting("use_agent", true)) and NotesAgent.resolve(str(setting("agent_command", "claude"))) == "":
		return {"state": "unavailable", "error": NotesAgent.NOT_FOUND}
	return {"state": "idle"}


# --- helpers ---

# Loading a character can stutter the game, so characters that are not loaded
# yet wait for the menu (match jobs are already loaded).
func _defer(job: Dictionary) -> bool:
	if job["reason"] == "match" or not runtime.matches.status().get("in_match", false):
		return false
	var entry = runtime.roster.resolve(job["name"])
	return entry == null or not entry["loaded"]


func _missing(entry: Dictionary) -> bool:
	return runtime.schemas.describe(entry)["status"] == "missing"


# Loads the job's character if needed; finishes the job when it turns out to
# have notes already (shipped by its mod, say). Returns the entry or null.
func _ready_entry(job: Dictionary):
	var entry = runtime.roster.resolve(job["name"])
	if entry == null:
		_finish(job, "failed", "character not found")
		return null
	var loaded = runtime.roster.ensure_loaded(entry)
	if not loaded["ok"]:
		_finish(job, "failed", str(loaded["error"]))
		return null
	entry = runtime.roster.resolve(job["name"])
	var status = runtime.schemas.describe(entry)["status"]
	if status != "missing" and job["status"] == "queued":
		_finish(job, "done", "already has notes (%s)" % status)
		return null
	return entry


func _coverage(job: Dictionary) -> Dictionary:
	var entry = runtime.roster.resolve(job["name"])
	if entry == null or not entry["loaded"]:
		return {}
	runtime.schemas.invalidate(entry["name"])
	var info = runtime.schemas.describe(entry)
	var coverage = info["coverage"]
	return {"complete": coverage["missing"].empty() and coverage["has_summary"],
		"text": "%d/%d moves, %s" % [coverage["annotated"], coverage["total"], "summary written" if coverage["has_summary"] else "no summary yet"],
		"missing": coverage["missing"]}


func _check_complete(job: Dictionary) -> bool:
	var coverage = _coverage(job)
	job["progress"] = coverage.get("text", "")
	if coverage.get("complete", false):
		_finish(job, "done", coverage["text"])
		return true
	return false


func _task_view(job: Dictionary) -> Dictionary:
	var coverage = _coverage(job)
	var missing = coverage.get("missing", [])
	return {
		"character": job["character"],
		"for_match": job["reason"] == "match",
		"reason": "a match with this character is starting" if job["reason"] == "match" else "it has no notes yet",
		"progress": coverage.get("text", ""),
		"moves_left": missing.slice(0, 19) if missing.size() > 20 else missing,
		"instructions": ("Write budok notes for %s: introspect_character {\"character\": \"%s\"} (page with offset/limit), read_source for moves marked dynamic, "
			+ "then submit_character_schema in batches (moves first, then summary and resources). The annotate_character prompt and yomi://knowledge/annotating "
			+ "explain the format. The task finishes by itself once every move and the summary have notes; then ask get_schema_task again.") % [
			job["character"], job["character"]],
	}


func _finish(job: Dictionary, status: String, note: String) -> void:
	job["status"] = status
	job["note"] = note
	job["session"] = ""
	emit_signal("changed")


func _exit_tree() -> void:
	if not _agent.empty() and OS.is_process_running(int(_agent["pid"])):
		NotesAgent.stop(int(_agent["pid"]))


func _requeue_abandoned() -> void:
	for session_id in _workers.keys():
		if not _session_alive(session_id):
			_workers.erase(session_id)
	for job in jobs:
		if job["status"] == "assigned" and not (_session_alive(job["session"]) and (_workers.has(job["session"]) or job["worker"] == "player")):
			if job["attempts"] >= MAX_ATTEMPTS:
				var coverage = _coverage(job)
				_finish(job, "partial", "its writers stopped %d times (%s)" % [job["attempts"], coverage.get("text", "")])
				continue
			job["status"] = "queued"
			job["worker"] = ""
			job["session"] = ""
			emit_signal("changed")


func _worker_alive() -> bool:
	for session_id in _workers:
		if _session_alive(session_id):
			return true
	return false


func _owns_slot(session_id: String) -> bool:
	return session_id != "" and not runtime.matches.slots_of(session_id).empty()


func _session_alive(session_id: String) -> bool:
	if session_id == "":
		return false
	var session = runtime.mcp.sessions.get(session_id)
	return session is Dictionary and Util.now_ms() - int(session.get("last_seen_ms", 0)) < SESSION_IDLE_MS


func _roster_ready() -> bool:
	return Util.prop(Util.autoload("Network"), "css_instance", null) != null

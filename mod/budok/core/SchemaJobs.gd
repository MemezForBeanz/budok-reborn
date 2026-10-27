extends Node

# Automatic character notes. One queue of characters without notes, fed by
# triggers and drained by two separate workers that only write schemas:
#   mcp - the connected chatbot that has claimed a slot is handed the job
#         (get_schema_task, or in place of its first turn for match jobs) and
#         writes the notes with its own tools.
#   api - the in-game AI (ai.annotate, needs an API key) writes them in the
#         background through ai/Annotator.gd.
# Both take jobs from the same queue, so they can work on two characters at
# once. Triggers (settings schemas.auto.*):
#   match_start - a match starts and its character or opponent has no notes:
#                 they go to the front, and bots wait for them before playing.
#   when=connect - every character without notes, when the game boots (API
#                 worker) and when a chatbot first claims a slot (MCP worker).

signal changed()

const Util = preload("res://budok/core/Util.gd")
const CHECK_INTERVAL := 1.0
const SESSION_IDLE_MS := 120000
const OPEN := ["queued", "assigned", "running"]

var runtime = null
var jobs := []
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
	return str(setting("workers", "both")) in ["both", "api"] and bool(runtime.llm.describe_role("annotate").get("has_key", false))


func mcp_available() -> bool:
	if not (str(setting("workers", "both")) in ["both", "mcp"]):
		return false
	for slot in ["p1", "p2"]:
		if _session_alive(runtime.matches.owners.get(slot, "")):
			return true
	return false


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
	if enabled() and str(setting("when", "matches")) == "connect" and str(setting("workers", "both")) in ["both", "mcp"]:
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
		"worker": "", "session": "", "progress": "", "note": ""}
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
	if not _boot_swept and str(setting("when", "matches")) == "connect" and api_available() and _roster_ready():
		_boot_swept = true
		sweep("boot")
	_requeue_abandoned()
	_run_api_worker()


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


# The task for an MCP session: its assigned job, or the next queued one. Only
# sessions that have claimed a slot get tasks.
func task_for(session_id: String, match_only: bool = false) -> Dictionary:
	if not enabled() or not (str(setting("workers", "both")) in ["both", "mcp"]) or not _owns_slot(session_id):
		return {}
	for job in jobs:
		if job["status"] == "assigned" and job["session"] == session_id:
			if _check_complete(job):
				return task_for(session_id, match_only)
			if match_only and job["reason"] != "match":
				return {}
			return _task_view(job)
	for job in jobs:
		if job["status"] != "queued" or _defer(job) or (match_only and job["reason"] != "match"):
			continue
		if _ready_entry(job) == null:
			continue
		job["status"] = "assigned"
		job["worker"] = "mcp"
		job["session"] = session_id
		emit_signal("changed")
		return _task_view(job)
	return {}


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
				_finish(job, "skipped", "handed back by the chatbot")
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
		if job["status"] == "queued" and not api_available() and not mcp_available():
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
			+ "explain the format. The task finishes by itself once every move and the summary have notes; finish_schema_task ends it early (skipped: true hands it back).") % [
			job["character"], job["character"]],
	}


func _finish(job: Dictionary, status: String, note: String) -> void:
	job["status"] = status
	job["note"] = note
	job["session"] = ""
	emit_signal("changed")


func _requeue_abandoned() -> void:
	for job in jobs:
		if job["status"] == "assigned" and not _session_alive(job["session"]):
			job["status"] = "queued"
			job["worker"] = ""
			job["session"] = ""
			emit_signal("changed")


func _owns_slot(session_id: String) -> bool:
	return session_id != "" and not runtime.matches.slots_of(session_id).empty()


func _session_alive(session_id: String) -> bool:
	if session_id == "":
		return false
	var session = runtime.mcp.sessions.get(session_id)
	return session is Dictionary and Util.now_ms() - int(session.get("last_seen_ms", 0)) < SESSION_IDLE_MS


func _roster_ready() -> bool:
	return Util.prop(Util.autoload("Network"), "css_instance", null) != null

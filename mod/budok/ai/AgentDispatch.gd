extends Node

# Starts and watches the command-line agents that play (core/CliAgent.gd),
# with the player's own login of that program: with agents.for_mcp, one for a
# slot set to "Chatbot (MCP)" that no chatbot has claimed; with
# agents.for_bots, one that thinks for a slot set to "AI: chat model" or "AI:
# tandem" instead of the API chat model. Each gets the prompt for its mode
# (Prompts.agent_prompt) and a ticket in its MCP address, which ties its
# session to that slot: it plays it without claiming it (a tandem slot stays
# tandem), and may not change controllers or start matches (mcp/Tools.gd).
# An agent that exits while its match goes on is started again, a few times.
#
# It also keeps what the agent window (ui/AgentWindow.gd) shows for each slot:
# your messages to whoever plays it and their replies, the agent's own words
# (read from its log) and every tool call the MCP server saw.

const Util = preload("res://budok/core/Util.gd")
const CliAgent = preload("res://budok/core/CliAgent.gd")
const Prompts = preload("res://budok/ai/Prompts.gd")
const DIR := "user://budok/agents"
const CHECK_INTERVAL := 1.0
# An agent that has not connected by then is stopped (and tried again).
const CONNECT_MS := 90000
# Waits before starting an agent that exited during its match again.
const RESTART_WAITS := [5000, 15000, 30000]
# After the match an agent may finish (save lessons) for this long.
const AFTER_MATCH_MS := 60000
# A chatbot that starts a match claims its slot right after: an agent for an
# MCP slot waits this long before it starts.
const MCP_GRACE_MS := 3000
const FEED_MAX := 300
const SLOTS := ["p1", "p2"]
# Tools a playing agent may use (Claude Code is told this list; others are
# held to it by the server).
const PLAY_TOOLS := ["wait_for_turn", "get_turn", "submit_action", "simulate", "look_ahead", "describe_character", "get_match_log",
	"get_status", "remember", "recall", "say", "operator_reply"]

var runtime = null
# slot -> {"slot", "mode", "cli", "ticket", "pid", "started_ms", "log",
# "log_pos", "partial", "sid", "state": starting, running, exited, stopped or
# failed, "error", "restarts", "retry_ms", "match"}.
var agents := {}
# What the window shows: {"p1": [entry], "p2": [entry], "other": [entry]};
# entry {"t", "kind": you, reply, text, call, status or log, "text",
# "result"?, "ms"?}. version changes with every new or updated entry.
var feeds := {"p1": [], "p2": [], "other": []}
var version := 0
var _inbox := {"p1": [], "p2": []}
var _timer := 0.0
# When this session first saw the current match: {"id", "ms"}.
var _seen := {"id": 0, "ms": 0}


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	runtime.matches.connect("match_started", self, "_on_match_started")


func _on_match_started(_info) -> void:
	for slot in SLOTS:
		_keep(slot)


# Starts (or checks) `slot`'s agent now, instead of at the next check.
func ensure(slot: String) -> void:
	_keep(slot)


func setting(key: String, default_value):
	return runtime.config.get_value("agents." + key, default_value)


# --- which slots need an agent ---

# The mode `slot`'s agent plays in now ("mcp", "ai" or "tandem"), or "" when
# it needs none.
func wanted(slot: String) -> String:
	var matches = runtime.matches
	var controller = str(matches.controllers.get(slot, "human"))
	if controller == "mcp" and bool(setting("for_mcp", true)):
		var owner = str(matches.owners.get(slot, ""))
		return "mcp" if owner == "" or owner == agents.get(slot, {}).get("sid", "") else ""
	if controller in ["ai", "tandem"] and bool(setting("for_bots", false)):
		return controller
	return ""


# Whether a CLI agent thinks for this ai or tandem slot (instead of the API
# chat model), and whether it is up: started or connected.
func thinks_for(slot: String) -> bool:
	return str(runtime.matches.controllers.get(slot, "")) in ["ai", "tandem"] and bool(setting("for_bots", false))


func ready(slot: String) -> bool:
	return agents.get(slot, {}).get("state", "") in ["starting", "running"]


func _in_match() -> bool:
	var matches = runtime.matches
	return Util.valid(matches.game) and matches.match_info.has("started_ms") and matches.last_result == null


func _match_id() -> int:
	return Util.as_int(runtime.matches.match_info.get("started_ms", 0))


func _process(delta: float) -> void:
	_timer += delta
	if _timer < CHECK_INTERVAL:
		return
	_timer = 0.0
	for slot in SLOTS:
		_keep(slot)
	_read_logs()


func _keep(slot: String) -> void:
	var agent = agents.get(slot)
	var want = wanted(slot) if _in_match() else ""
	var running = agent != null and agent["state"] in ["starting", "running"] and OS.is_process_running(int(agent["pid"]))
	if want == "":
		if running:
			# After its match an agent may still save lessons for a while.
			var ended = runtime.matches.last_result != null and agent["match"] == _match_id()
			if not ended or Util.now_ms() - int(agent.get("ended_ms", Util.now_ms())) > AFTER_MATCH_MS:
				_stop(slot, "its match ended" if ended else "the slot no longer needs it")
			elif not agent.has("ended_ms"):
				agent["ended_ms"] = Util.now_ms()
		return
	if agent == null or agent["mode"] != want or agent["match"] != _match_id():
		if running:
			_stop(slot, "the slot's mode changed")
		if _seen["id"] != _match_id():
			_seen = {"id": _match_id(), "ms": Util.now_ms()}
		if want == "mcp" and Util.now_ms() - int(_seen["ms"]) < MCP_GRACE_MS:
			return
		_start(slot, want, 0, false)
		return
	if running:
		if agent["sid"] == "" and Util.now_ms() - int(agent["started_ms"]) > CONNECT_MS:
			_stop(slot, "it did not connect to budok within %d s" % (CONNECT_MS / 1000))
			_after_exit(agent)
		return
	if agent["state"] in ["starting", "running"]:
		agent["state"] = "exited"
		_release(agent)
		var said = _log_tail(agent)
		_add(slot, "status", "the agent exited%s" % ((": " + said) if said != "" else ""))
		_after_exit(agent)
	if agent["state"] == "exited" and Util.now_ms() >= int(agent.get("retry_ms", 0)):
		_start(slot, want, int(agent["restarts"]) + 1, true)


func _after_exit(agent: Dictionary) -> void:
	agent["state"] = "exited"
	var restarts = int(agent["restarts"])
	if restarts >= RESTART_WAITS.size():
		agent["state"] = "failed"
		agent["error"] = "it stopped %d times this match; set the slot again to try once more" % (restarts + 1)
		_add(agent["slot"], "status", agent["error"])
	else:
		agent["retry_ms"] = Util.now_ms() + RESTART_WAITS[restarts]


func _start(slot: String, mode: String, restarts: int, resumed: bool) -> void:
	var cli = str(setting("cli", "claude"))
	var record = {"slot": slot, "mode": mode, "cli": cli, "ticket": Util.random_hex(12), "pid": -1, "started_ms": Util.now_ms(), "log": "",
		"log_pos": 0, "partial": "", "sid": "", "state": "failed", "error": "", "restarts": restarts, "match": _match_id()}
	agents[slot] = record
	var named = str(setting("command", "")).strip_edges()
	var command = CliAgent.resolve(named if named != "" else CliAgent.default_command(cli))
	if command == "" and cli != "custom":
		record["error"] = "%s was not found: install it, or set its full path (Play tab, CLI agents)" % (named if named != "" else CliAgent.default_command(cli))
		_add(slot, "status", record["error"])
		return
	var dir = DIR.plus_file(slot)
	Util.ensure_dir(dir)
	var token = str(runtime.config.get_value("mcp.auth_token", "")) if bool(runtime.config.get_value("mcp.require_token", true)) else ""
	var tools = PLAY_TOOLS.duplicate()
	if mode == "ai":
		tools.erase("look_ahead")
	var line = CliAgent.command_line({"cli": cli, "command": command, "model": str(setting("model", "")), "token": token, "dir": dir,
		"url": runtime.mcp.url() + "?agent=" + record["ticket"], "tools": tools, "custom": str(setting("custom_command", ""))})
	if not line["ok"]:
		record["error"] = line["error"]
		_add(slot, "status", record["error"])
		return
	for path in line["files"]:
		Util.ensure_dir(path.get_base_dir())
		Util.write_text(path, line["files"][path])
	var limit = Util.as_int(runtime.config.get_value("turns.timeout_s." + mode, 0))
	Util.write_text(dir.plus_file("prompt.txt"), Prompts.agent_prompt(runtime, slot, mode, limit, resumed))
	record["log"] = ProjectSettings.globalize_path(dir.plus_file("agent.log"))
	# The previous run's log is kept next to it (why it stopped).
	var logs = Directory.new()
	if logs.file_exists(dir.plus_file("agent.log")):
		logs.rename(dir.plus_file("agent.log"), dir.plus_file("agent.prev.log"))
	Util.write_text(dir.plus_file("agent.log"), "")
	var pid = CliAgent.launch(dir, "run", line["command"], line["args"], line["env"], ProjectSettings.globalize_path(dir.plus_file("prompt.txt")),
		record["log"], line["cwd"])
	if pid <= 0:
		record["error"] = "could not start %s" % line["command"]
		_add(slot, "status", record["error"])
		return
	record["pid"] = pid
	record["state"] = "starting"
	_add(slot, "status", "%s %s for %s (%s mode)" % ["started again:" if resumed else "started", CliAgent.label(cli), slot, mode])
	print("budok: started a %s agent for %s (%s, pid %d)" % [mode, slot, line["command"], pid])


func _stop(slot: String, why: String) -> void:
	var agent = agents.get(slot)
	if agent == null:
		return
	if OS.is_process_running(int(agent["pid"])):
		CliAgent.stop(int(agent["pid"]))
	_release(agent)
	agent["state"] = "stopped"
	_add(slot, "status", "stopped the agent: %s" % why)


# A Chatbot slot an agent claimed is free again once it is gone.
func _release(agent: Dictionary) -> void:
	if agent["sid"] != "" and runtime.matches.owners.get(agent["slot"], "") == agent["sid"]:
		runtime.matches.release(agent["slot"], agent["sid"])


# Stops every agent (the game closes, or the player asked).
func stop_all(why: String = "stopped by the player") -> void:
	for slot in agents:
		if agents[slot]["state"] in ["starting", "running"]:
			_stop(slot, why)


# Starts `slot`'s agent now (the window's Start button), when the slot wants one.
func start_now(slot: String) -> Dictionary:
	var want = wanted(slot) if _in_match() else ""
	if want == "":
		return {"ok": false, "error": "%s does not use a CLI agent now (Play tab: set it to Chatbot, or AI with the CLI agent, during a match)" % slot}
	if ready(slot):
		return {"ok": true}
	_start(slot, want, 0, agents.has(slot) and agents[slot]["match"] == _match_id())
	return {"ok": agents[slot]["state"] == "starting", "error": agents[slot]["error"]}


func stop_now(slot: String) -> void:
	if ready(slot):
		_stop(slot, "stopped by the player")
		# Not started again this match until asked.
		agents[slot]["restarts"] = RESTART_WAITS.size()
		agents[slot]["state"] = "failed"
		agents[slot]["error"] = "stopped by the player"


# An external chatbot took the slot over: its agent goes.
func give_up_slot(slot: String) -> void:
	if ready(slot):
		_stop(slot, "a chatbot of yours claimed %s" % slot)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == MainLoop.NOTIFICATION_WM_QUIT_REQUEST:
		if runtime != null:
			stop_all("the game is closing")


# --- sessions ---

# Called by the MCP server for a request with ?agent=<ticket>: ties the
# session to that slot's agent. Returns {"slot", "mode"} or {}.
func bind(ticket: String, sid: String) -> Dictionary:
	for slot in agents:
		var agent = agents[slot]
		if agent["ticket"] == ticket and agent["state"] in ["starting", "running"]:
			if agent["mode"] == "mcp" and not str(runtime.matches.owners.get(slot, "")) in ["", sid]:
				_stop(slot, "a chatbot of yours already plays %s" % slot)
				return {}
			agent["sid"] = sid
			agent["state"] = "running"
			if agent["mode"] == "mcp":
				runtime.matches.claim(slot, sid)
			_add(slot, "status", "connected to budok")
			return {"slot": slot, "mode": agent["mode"]}
	return {}


# {"slot", "mode"} when `sid` is an agent budok started, else {}.
func session_info(sid: String) -> Dictionary:
	for slot in agents:
		var agent = agents[slot]
		if agent["sid"] == sid and sid != "" and agent["state"] in ["starting", "running"]:
			return {"slot": slot, "mode": agent["mode"]}
	return {}


# The feed a session's calls go to: the slot it plays, else "other".
func _feed_of(sid: String) -> String:
	var info = session_info(sid)
	if not info.empty():
		return info["slot"]
	for slot in SLOTS:
		if runtime.matches.owners.get(slot, "") == sid and sid != "":
			return slot
	return "other"


# --- the window's feed ---

func on_call(sid: String, name: String, args: Dictionary) -> Dictionary:
	var shown = Util.json_str(args) if not args.empty() else ""
	return _add(_feed_of(sid), "call", name + (" " + Util.truncate(shown, 160) if shown != "" else ""))


func on_result(entry: Dictionary, raw, ms: int) -> void:
	if entry.empty():
		return
	entry["ms"] = ms
	entry["result"] = _result_text(raw)
	version += 1


static func _result_text(raw) -> String:
	if not (raw is Dictionary):
		return "no result"
	if raw.has("error") and raw.get("ok", false) != true:
		return "error: " + Util.truncate(str(raw.get("message", raw["error"])), 160)
	for key in ["status", "recommended", "applied", "outcome"]:
		if raw.has(key):
			var value = raw[key]
			if value is Dictionary:
				value = value.get("move", value.get("action", Util.json_str(value)))
			return "%s: %s" % [key, Util.truncate(str(value), 120)]
	return "ok"


func _add(feed: String, kind: String, text: String) -> Dictionary:
	if not feeds.has(feed):
		feed = "other"
	var entry = {"t": Util.now_ms(), "kind": kind, "text": text}
	feeds[feed].append(entry)
	if feeds[feed].size() > FEED_MAX:
		feeds[feed].pop_front()
	version += 1
	return entry


# --- talking to whoever plays a slot ---

# A message from the player to the agent (or chatbot) playing `slot`. It is
# delivered with that session's next tool result.
func send(slot: String, text: String) -> void:
	text = text.strip_edges()
	if text == "" or not _inbox.has(slot):
		return
	_inbox[slot].append(text)
	_add(slot, "you", text)
	if not ready(slot) and str(runtime.matches.owners.get(slot, "")) == "":
		_add(slot, "status", "nobody plays %s through budok's tools right now: the message waits for whoever does" % slot)


func has_messages(sid: String) -> bool:
	var feed = _feed_of(sid)
	return _inbox.has(feed) and not _inbox[feed].empty()


func take_messages(sid: String) -> Array:
	var feed = _feed_of(sid)
	if not _inbox.has(feed) or _inbox[feed].empty():
		return []
	var out = _inbox[feed]
	_inbox[feed] = []
	return out


func reply(sid: String, text: String) -> void:
	_add(_feed_of(sid), "reply", Util.truncate(text.strip_edges(), 2000))


# --- the agents' own words, from their logs ---

func _read_logs() -> void:
	for slot in agents:
		var agent = agents[slot]
		if agent["log"] == "":
			continue
		var file = File.new()
		if not file.file_exists(agent["log"]) or file.open(agent["log"], File.READ) != OK:
			continue
		var length = file.get_len()
		if length < int(agent["log_pos"]):
			agent["log_pos"] = 0
		if length > int(agent["log_pos"]):
			file.seek(int(agent["log_pos"]))
			var chunk = file.get_buffer(int(min(length - int(agent["log_pos"]), 65536)))
			agent["log_pos"] = int(agent["log_pos"]) + chunk.size()
			var lines = (agent["partial"] + chunk.get_string_from_utf8()).split("\n")
			agent["partial"] = lines[lines.size() - 1]
			for i in range(lines.size() - 1):
				_add_line(slot, lines[i])
		file.close()


func _add_line(slot: String, line: String) -> void:
	var said = CliAgent.text_of(line)
	if said.empty() or str(said.get("text", "")).strip_edges() == "":
		return
	var feed = feeds[slot]
	# Parts of one streamed message join up.
	if said.get("delta", false) and not feed.empty() and feed.back()["kind"] == "text" and feed.back().get("delta", false):
		feed.back()["text"] += said["text"]
		version += 1
		return
	var entry = _add(slot, said["kind"], Util.truncate(str(said["text"]), 2000))
	if said.get("delta", false):
		entry["delta"] = true


func _log_tail(agent: Dictionary) -> String:
	var text = Util.read_text(agent["log"])
	if not (text is String):
		return ""
	# The last thing it printed that is not a JSON event.
	var lines = text.strip_edges().split("\n")
	for i in range(lines.size() - 1, -1, -1):
		var said = CliAgent.text_of(lines[i])
		if said.get("kind", "") in ["log", "status"]:
			return Util.truncate(str(said["text"]), 200)
	return ""


# --- status ---

func status() -> Dictionary:
	var out = {"for_mcp": bool(setting("for_mcp", true)), "for_bots": bool(setting("for_bots", false)), "cli": str(setting("cli", "claude")),
		"agents": {}}
	for slot in agents:
		var agent = agents[slot]
		out["agents"][slot] = {"mode": agent["mode"], "state": agent["state"], "connected": agent["sid"] != "", "restarts": agent["restarts"],
			"error": agent["error"], "log": agent["log"]}
	return out

extends Reference

# MCP tool catalogue. Handlers are thin wrappers over the runtime API so the
# in-mod autopilot, automation scripts and external MCP clients all exercise
# the same code. A handler returns a Dictionary, or a GDScriptFunctionState
# for long-running calls (the server answers when it completes).

const Util = preload("res://budok/core/Util.gd")
const MatchStarter = preload("res://budok/core/MatchStarter.gd")
const DecisionCore = preload("res://budok/ai/DecisionCore.gd")
const Prompts = preload("res://budok/ai/Prompts.gd")
const SETTING_PREFIXES := ["controllers.", "turns.", "simulation.", "ai.play.", "ai.annotate.", "ai.decide.", "ai.core.", "schemas.auto.", "misc."]
# agent_command names a program budok runs, so only the player may set it.
# Decision-core endpoints carry keys, so they are never changed over MCP.
const SETTING_BLOCKLIST := ["api_key", "base_url", "auth_token", "agent_command", "endpoints"]
const SESSION_TAKEOVER_MS := 120000
# What an agent budok started (ai/AgentDispatch.gd) may not do: its slot and
# controller are set for it.
const AGENT_BLOCKED := ["claim_slot", "release_slot", "set_controller", "start_match", "update_setting"]

var runtime = null
var _defs := []
var _names := {}


func _init(runtime_ref) -> void:
	runtime = runtime_ref
	_define()


func definitions() -> Array:
	return _defs


func has_tool(name: String) -> bool:
	return _names.has(name)


func call_tool(name: String, args: Dictionary, sid: String):
	var agent = runtime.agents.session_info(sid) if runtime.agents != null else {}
	if not agent.empty() and (name in AGENT_BLOCKED or (name == "look_ahead" and agent["mode"] == "ai")):
		return {"ok": false, "error": ("budok started you to play %s in %s mode, so %s is not for you: your slot and controller are set. Play it "
			+ "with wait_for_turn%s and submit_action.") % [agent["slot"], agent["mode"], name, ", simulate" if agent["mode"] == "ai" else ", look_ahead"]}
	return call("_t_" + name, args, sid)


# --- definitions ---

func _define() -> void:
	var slot = {"type": "string", "enum": ["p1", "p2"], "description": "Player slot. Defaults to the slot this session controls."}
	var xy = {"type": "object", "properties": {"x": {"type": "integer"}, "y": {"type": "integer"}}}
	var extra = {"type": "object", "description": "Optional extras: di {x,y} (-100..100, screen space), reverse (bool), feint (bool), and any character extras listed in the turn's extras.character.", "additionalProperties": true}
	var data = {"description": "Move parameters shaped by the action's payload spec (omit to use the game's default)."}
	var character = {"type": "string", "description": "Character name as shown by list_characters (display or internal name)."}
	var detail_help = ("compact: move names with payload types and a slim observation (about a fifth of the size; get notes with describe_character). "
		+ "summary (default): short notes and frame data per move. full: all notes, raw resources and the opponent's options. "
		+ "A turn where Continue is the only move is always minimal.")
	var detail = {"type": "string", "enum": ["compact", "summary", "full"], "description": detail_help}
	_add("get_status", "Status", "Server, match and controller status, open turns, schema coverage and background jobs. Call first.", {}, [], true)
	_add("list_characters", "List characters", "All playable characters (vanilla, newer builds and modded) with schema status.", {}, [], true)
	_add("start_match", "Start match", "Start a local match. Works from the menu or mid-match (the current match is abandoned).",
		{"p1": character, "p2": character,
		"controllers": {"type": "object", "description": "Per-slot controller for this match: human | mcp | ai (chat model with an API key) | decision (decision core) | tandem (chat model leading the decision core).",
			"properties": {"p1": {"type": "string", "enum": ["human", "mcp", "ai", "decision", "tandem"]}, "p2": {"type": "string", "enum": ["human", "mcp", "ai", "decision", "tandem"]}}},
		"claim": {"type": "string", "enum": ["p1", "p2", "both", "none"], "description": "Slot(s) this session will play (default: every mcp slot)."},
		"starting_hp": {"type": "integer", "minimum": 50, "description": "Override both players' HP (shorter matches)."},
		"settings": {"type": "object", "description": "Native match settings: stage_width, game_length, di_enabled, turbo_mode, infinite_resources, one_hit_ko, burst_enabled, always_perfect_parry, char_distance."}},
		["p1", "p2"])
	_add("set_controller", "Set controller", "Change who controls a slot right now: human, mcp or ai (the in-game API-key autopilot).",
		{"slot": slot, "controller": {"type": "string", "enum": ["human", "mcp", "ai", "decision", "tandem"]}}, ["slot", "controller"])
	_add("claim_slot", "Claim slot", "Take control of a slot for this MCP session (sets its controller to mcp). A slot held by a disconnected or idle (2 min) session is taken over automatically; force takes it from a live one.",
		{"slot": slot, "force": {"type": "boolean"}}, ["slot"])
	_add("release_slot", "Release slot", "Give a claimed slot back (the human can play it again).", {"slot": slot}, ["slot"])
	_add("wait_for_turn", "Wait for turn", "Long-poll until your slot must choose a move. Returns the turn token, a plain-language situation, the observation and legal actions. Returns status 'waiting' after timeout_s: just call again.",
		{"slot": slot, "timeout_s": {"type": "number", "minimum": 1, "maximum": 50, "description": "Default 20."},
		"detail": detail}, [])
	_add("get_turn", "Get turn", "The currently open turn for your slot, without waiting.", {"slot": slot, "detail": detail}, [], true)
	_add("simulate", "Simulate", "Preview a move on the real engine from the current turn: your action vs an assumed opponent action (default: they hold). "
		+ "Returns damage, end states, frame advantage, events, objects, where your hitboxes were if they missed, and any later decision you get inside the preview "
		+ "(you_act_again_at). Never reveals the opponent's real choice.",
		{"slot": slot, "action": {"type": "string"}, "data": data, "extra": extra,
		"then": {"type": "array", "items": {"type": "object"}, "description": "Your follow-up moves [{action, data?, extra?}], played in order each time you can act again inside the preview (two-step moves, or a free turn while the opponent is busy)."},
		"opponent_action": {"type": "string", "description": "Assumed opponent move (must be legal for them this turn, even if they already locked in)."},
		"opponent_data": data, "opponent_extra": extra,
		"ticks": {"type": "integer", "minimum": 10, "maximum": 300, "description": "Max ticks to simulate (default from settings)."}},
		["action"], true)
	var look_ahead = DecisionCore.look_ahead_properties()
	look_ahead["slot"] = slot
	_add("look_ahead", "Look ahead (decision core)", DecisionCore.LOOK_AHEAD_HELP
		+ " Without a decision model in budok's settings (Models tab, Decision core) it still sweeps the moves you name, the next exchange only, and runs the combo solver on combo turns."
		+ " Takes a few seconds to tens of seconds (ai.core.think_s caps it).", look_ahead, [])
	_add("submit_action", "Submit action", "Lock in your move for the turn. Validated against the game; on error nothing is applied and you can retry with the same token. "
		+ "Retrying a move that was already locked in returns ok with already_applied (and the outcome), so a lost reply is safe to retry.",
		{"turn_token": {"type": "string"}, "action": {"type": "string"}, "data": data, "extra": extra,
		"wait_for_outcome": {"type": "boolean", "description": "Wait until the turn resolves and report what happened (default true). If it is still pending after timeout_s (the opponent may be a slow human), just call wait_for_turn."},
		"say": {"type": "string", "description": "Optional line (under 80 characters) shown in a speech bubble above your character, when the player turned speech on in budok's settings."},
		"timeout_s": {"type": "number", "minimum": 1, "maximum": 50, "description": "Default 20, capped by the mcp.max_wait_s setting."}}, ["turn_token", "action"])
	_add("say", "Say", "Show a short line (under 80 characters) in a speech bubble above your character, when the player turned speech on in budok's settings (Play tab, Misc). "
		+ "submit_action's say does the same with your move.", {"slot": slot, "text": {"type": "string"}}, ["text"])
	_add("get_match_log", "Match log", "Recent turn history (both players' moves after they resolved), decisions and result.",
		{"last_n": {"type": "integer", "minimum": 1, "maximum": 200}}, [], true)
	_add("describe_character", "Describe character", "Schema for a character: measured frame data + notes (category, beats, loses_to...).",
		{"character": character, "slot": {"type": "string", "enum": ["p1", "p2"], "description": "Describe the character in this slot instead."},
		"moves": {"type": "array", "items": {"type": "string"}, "description": "Only these moves."}}, [], true)
	_add("introspect_character", "Introspect character", "Raw automatic skeleton of a character for writing its schema: states, hitbox frame data, resources, script paths and (optionally) source of code-driven moves. Page with offset/limit.",
		{"character": character, "moves": {"type": "array", "items": {"type": "string"}},
		"include_source": {"type": "boolean", "description": "Attach script source for code-driven (dynamic) moves."},
		"offset": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 100}}, ["character"], true)
	_add("submit_character_schema", "Submit character schema", "Save notes for a character (partial submissions merge). See resource yomi://schema/format for fields. Frame data is measured, never submitted.",
		{"character": character, "schema": {"type": "object"},
		"replace": {"type": "boolean", "description": "Replace the stored notes instead of merging."},
		"override": {"type": "boolean", "description": "Prefer these notes over ones shipped by the mod or bundled with budok."}},
		["character", "schema"])
	_add("generate_character_schema", "Generate schema with in-game AI", "Ask the in-game API-key AI (settings ai.annotate) to write the schema in the background. Progress appears in get_status.",
		{"character": character, "force": {"type": "boolean", "description": "Regenerate even if notes exist."}}, ["character"])
	_add("export_character_schema", "Export schema", "Write a character's schema to a shareable file (mod authors ship it next to the character scene).", {"character": character}, ["character"])
	_add("fetch_registry_schema", "Fetch registry schema", "Opt-in community registry: download notes for a character by fingerprint (requires schemas.registry_enabled).", {"character": character}, ["character"])
	_add("read_source", "Read source", "Read a script/scene from the game or a mod (res:// only).",
		{"path": {"type": "string"}, "start_line": {"type": "integer", "minimum": 1}, "max_lines": {"type": "integer", "minimum": 1, "maximum": 2000}}, ["path"], true)
	_add("search_source", "Search source", "Case-insensitive text search across game and mod scripts (res:// only).",
		{"query": {"type": "string"}, "path_prefix": {"type": "string", "description": "Default res://"}, "max_results": {"type": "integer", "minimum": 1, "maximum": 200}}, ["query"], true)
	_add("list_source_files", "List files", "List a res:// directory.", {"path": {"type": "string"}}, ["path"], true)
	var who = {"type": "string", "description": "Character name, or p1 / p2 for a character in the current match."}
	_add("remember", "Remember", "Save a lesson for future matches: how a character plays, what works in a matchup, or anything general. "
		+ "Memories stay in this game install, are shared by every bot that plays here (each records who wrote it) and come back in later matches "
		+ "(start_match, first turn, describe_character). Give character for notes about one character, character + opponent for a matchup "
		+ "(playing character against opponent), neither for general notes. For lasting changes to a move's notes, use submit_character_schema instead.",
		{"text": {"type": "string", "description": "Up to 600 characters. One concrete lesson per memory."}, "character": who, "opponent": who,
		"tags": {"type": "array", "items": {"type": "string"}}}, ["text"])
	_add("recall", "Recall", "Memories bots saved earlier, newest first. Defaults to the characters in the current match (their own notes, the matchups between them and general notes).",
		{"character": who, "opponent": who, "query": {"type": "string", "description": "Only memories containing this text."},
		"limit": {"type": "integer", "minimum": 1, "maximum": 100}, "only_mine": {"type": "boolean", "description": "Only memories written by this client."}}, [], true)
	_add("forget", "Forget", "Delete one memory by its id (from recall).", {"id": {"type": "string"}}, ["id"])
	_add("get_settings", "Get settings", "Current budok settings (secrets redacted).", {}, [], true)
	_add("get_schema_task", "Get schema task", "Automatic notes: the next character to write notes for, with instructions and progress; null when there is nothing to do. "
		+ "Pass worker: true when this session is a notes writer (the notes_worker prompt): it then gets every queued character, without claiming a slot. "
		+ "Workers can wait for the next character with wait_s.",
		{"worker": {"type": "boolean"}, "wait_s": {"type": "number", "minimum": 0, "maximum": 50,
			"description": "Workers only: wait up to this long for a character to come up (default 0, capped by mcp.max_wait_s)."}}, [], true)
	_add("finish_schema_task", "Finish schema task", "End your schema task early: done, or skipped: true to hand it back. Tasks also finish by themselves once every move and the summary have notes.",
		{"character": {"type": "string"}, "skipped": {"type": "boolean"}}, [])
	_add("operator_reply", "Reply to the player", "Answer a message the player sent you from budok's agent window (operator_messages in a tool result). "
		+ "It appears in that window.", {"text": {"type": "string", "description": "Your answer, short."}}, ["text"])
	_add("update_setting", "Update setting", "Change one setting under controllers.*, turns.*, simulation.*, ai.play.*, ai.annotate.*, ai.decide.*, ai.core.* (not its endpoints), schemas.auto.* or misc.* (no keys or URLs).",
		{"path": {"type": "string"}, "value": {}}, ["path", "value"])


func _add(name: String, title: String, description: String, properties: Dictionary, required: Array, read_only: bool = false) -> void:
	var schema = {"type": "object", "properties": properties}
	if not required.empty():
		schema["required"] = required
	_defs.append({
		"name": name,
		"title": title,
		"description": description,
		"inputSchema": schema,
		"annotations": {"title": title, "readOnlyHint": read_only, "openWorldHint": false},
	})
	_names[name] = true


# --- handlers ---

func _t_get_status(_args: Dictionary, sid: String) -> Dictionary:
	var status = runtime.status()
	status["your_slots"] = runtime.matches.slots_of(sid)
	_add_schema_task(status, sid)
	return status


func _t_get_schema_task(args: Dictionary, sid: String):
	var worker = bool(args.get("worker", false))
	var task = runtime.schema_jobs.task_for(sid, false, worker)
	if task.empty() and (worker or runtime.schema_jobs.is_worker(sid)):
		var max_wait = float(runtime.config.get_value("mcp.max_wait_s", 25))
		var deadline = Util.now_ms() + int(clamp(float(args.get("wait_s", 0)), 0.0, max_wait) * 1000.0)
		while task.empty() and Util.now_ms() < deadline:
			yield(runtime.get_tree().create_timer(0.5), "timeout")
			task = runtime.schema_jobs.task_for(sid)
	var out = {"ok": true, "task": task if not task.empty() else null, "queue": runtime.schema_jobs.summary()}
	if task.empty() and not worker and not runtime.schema_jobs.is_worker(sid):
		out["message"] = "Notes are written by a separate notes agent (or the in-game AI), not by the chatbot that plays. To be a notes writer, call get_schema_task with worker: true."
	return out


func _t_finish_schema_task(args: Dictionary, sid: String) -> Dictionary:
	return runtime.schema_jobs.finish_task(sid, str(args.get("character", "")), bool(args.get("skipped", false)))


func _add_schema_task(result: Dictionary, sid: String) -> void:
	var task = runtime.schema_jobs.task_for(sid)
	if not task.empty():
		result["schema_task"] = task


# Notes for this match's characters come before the first move: this session
# writes them itself when the job is handed to it, or waits while the in-game
# AI writes them.
func _hold_for_notes(sid: String, timeout_s: float):
	yield(runtime.get_tree(), "idle_frame")
	var deadline = Util.now_ms() + int(timeout_s * 1000.0)
	while true:
		var job = runtime.schema_jobs.blocking_job()
		if job.empty():
			return {}
		var task = runtime.schema_jobs.task_for(sid, true)
		if not task.empty():
			return {"ok": true, "status": "schema_task", "task": task,
				"message": "Before playing, write notes for %s (automatic notes are on); your first turn waits for them. Then call wait_for_turn again." % task["character"]}
		if Util.now_ms() >= deadline:
			return {"ok": true, "status": "waiting", "reason": "notes",
				"message": "%s is writing notes for %s%s; your first move comes once they are saved. Call wait_for_turn again." % [
					{"api": "The in-game AI", "agent": "A notes agent", "player": "Another chatbot"}.get(job["worker"], "A notes agent (starting)"),
					job["character"], (" (%s)" % job["progress"]) if str(job.get("progress", "")) != "" else ""]}
		yield(runtime.get_tree().create_timer(0.25), "timeout")
	return {}


func _t_list_characters(_args: Dictionary, _sid: String) -> Dictionary:
	var out = []
	for entry in runtime.roster.list():
		var item = {"name": entry["display_name"], "internal_name": entry["name"], "source": entry["source"], "loaded": entry["loaded"]}
		if entry["loaded"]:
			var info = runtime.schemas.describe(entry)
			item["schema"] = info["status"]
			item["notes_coverage"] = "%d/%d moves" % [info["coverage"]["annotated"], info["coverage"]["total"]]
			if info["stale"]:
				item["schema_stale"] = true
		else:
			item["schema"] = "unknown until loaded (start_match loads it)"
		out.append(item)
	return {"ok": true, "characters": out}


func _t_start_match(args: Dictionary, sid: String):
	var controllers = args.get("controllers", {})
	if not (controllers is Dictionary):
		controllers = {}
	var claim = str(args.get("claim", ""))
	if claim in ["p1", "both"]:
		controllers["p1"] = "mcp"
	if claim in ["p2", "both"]:
		controllers["p2"] = "mcp"
	if not controllers.has("p1") and not controllers.has("p2") and claim == "":
		controllers = {"p1": "human", "p2": "mcp"}
	var result = yield(MatchStarter.start(runtime, {
		"p1": args.get("p1", ""), "p2": args.get("p2", ""), "controllers": controllers,
		"starting_hp": args.get("starting_hp", 0), "settings": args.get("settings", {}),
	}), "completed")
	if result.get("ok", false) and claim != "none":
		for slot in ["p1", "p2"]:
			if runtime.matches.controllers[slot] == "mcp" and (claim == "" or claim == slot or claim == "both"):
				# Starting a match is explicit: take the requested slots even
				# from another session.
				runtime.matches.claim(slot, sid, true)
		result["your_slots"] = runtime.matches.slots_of(sid)
		result["next"] = "call wait_for_turn"
		result["how_to_play"] = Prompts.QUICK_START
		runtime.schema_jobs.on_claimed(sid)
		_add_schema_task(result, sid)
		_add_notes_hint(result)
		_add_memories(result)
	return result


# Points out characters in the match without move notes (typical for modded
# ones), with the ways to write them.
func _add_notes_hint(result: Dictionary) -> void:
	var missing = _characters_without_notes()
	if missing.empty():
		return
	result["notes_missing"] = missing
	var names = PoolStringArray(missing).join(" and ")
	var jobs = runtime.schema_jobs
	if jobs.holding():
		result["notes_hint"] = "Notes for %s are being written in the background; your first turn waits for them." % names
	elif jobs.enabled() and bool(jobs.setting("match_start", true)) and not bool(jobs.setting("use_player", false)):
		if jobs.writer_available():
			result["notes_hint"] = "%s %s no move notes yet (the notes writer did not finish them), so you only get measured frame data. Simulate more." % [
				names, "has" if missing.size() == 1 else "have"]
		else:
			result["notes_hint"] = ("%s %s no move notes yet and no notes writer is available, so you only get measured frame data. Tell the user once: "
				+ "install Claude Code (budok then starts a notes agent by itself), open a second chat with budok's notes_worker prompt, or add an API key "
				+ "(budok settings → Providers). Meanwhile, simulate more.") % [names, "has" if missing.size() == 1 else "have"]
	else:
		result["notes_hint"] = ("%s %s no move notes yet, so you only get measured frame data for %s. For better play, write them first: run the annotate_character prompt "
			+ "(introspect_character, read_source, submit_character_schema), or call generate_character_schema to let the in-game AI do it. Otherwise simulate more.") % [
			names, "has" if missing.size() == 1 else "have", "it" if missing.size() == 1 else "them"]


func _add_memories(result: Dictionary) -> void:
	var memories = runtime.match_memories()
	if not memories.empty():
		result["memories"] = runtime.memory.lines(memories)
		result["memories_hint"] = "Lessons bots saved in earlier matches (recall shows more; remember adds yours)."


func _t_remember(args: Dictionary, sid: String) -> Dictionary:
	if not bool(runtime.config.get_value("memory.enabled", true)):
		return {"ok": false, "error": "memories are turned off in settings (memory.enabled)"}
	var context = {}
	var characters = runtime.matches.status().get("characters", {})
	if runtime.matches.game != null and not characters.empty():
		context = {"match": "%s vs %s" % [characters.get("p1", ""), characters.get("p2", "")], "tick": runtime.matches.status().get("tick", 0)}
	return runtime.memory.remember(_memory_name(args.get("character", "")), _memory_name(args.get("opponent", "")),
		str(args.get("text", "")), args.get("tags", []), _client_name(sid), context)


func _t_recall(args: Dictionary, sid: String) -> Dictionary:
	var names = []
	for key in ["character", "opponent"]:
		var name = _memory_name(args.get(key, ""))
		if name != "" and not (name in names):
			names.append(name)
	if names.empty():
		for slot in ["p1", "p2"]:
			var name = _memory_name(slot)
			if name != "" and not (name in names):
				names.append(name)
	var entries = runtime.memory.recall(names, str(args.get("query", "")), Util.as_int(args.get("limit", 20), 20),
		_client_name(sid) if bool(args.get("only_mine", false)) else "")
	return {"ok": true, "characters": names, "memories": entries}


func _t_forget(args: Dictionary, _sid: String) -> Dictionary:
	return runtime.memory.forget(str(args.get("id", "")))


# "p1"/"p2" mean the character in that slot; other names resolve through the
# roster, and unknown ones are kept as written (the character may not be installed).
func _memory_name(value) -> String:
	var text = str(value if value != null else "").strip_edges()
	if text in ["p1", "p2"]:
		var entry = runtime.matches.match_info.get("characters", {}).get(text)
		return entry["display_name"] if entry is Dictionary else ""
	if text == "":
		return ""
	var entry = runtime.roster.resolve(text)
	return entry["display_name"] if entry is Dictionary else text


func _client_name(sid: String) -> String:
	var name = str(runtime.mcp.sessions.get(sid, {}).get("client", {}).get("name", ""))
	return "mcp:" + (name if name != "" else "unknown")


func _characters_without_notes() -> Array:
	var missing = []
	var infos = runtime.matches.infos()
	for slot in ["p1", "p2"]:
		var info = infos.get(slot, {})
		var name = str(info.get("character", ""))
		if str(info.get("status", "")) == "missing" and name != "" and not (name in missing):
			missing.append(name)
	return missing


func _t_set_controller(args: Dictionary, _sid: String) -> Dictionary:
	return runtime.matches.set_controller(str(args.get("slot", "")), str(args.get("controller", "")))


func _t_claim_slot(args: Dictionary, sid: String) -> Dictionary:
	var slot = str(args.get("slot", ""))
	var owner = str(runtime.matches.owners.get(slot, ""))
	var force = bool(args.get("force", false)) or _owner_gone(owner, sid)
	# A chatbot of the player's takes a slot from an agent budok started for it.
	if owner != "" and runtime.agents.session_info(owner).get("slot", "") == slot:
		runtime.agents.give_up_slot(slot)
		force = true
	var result = runtime.matches.claim(slot, sid, force)
	if result.get("ok", false):
		runtime.schema_jobs.on_claimed(sid)
		_add_schema_task(result, sid)
	return result


func _t_operator_reply(args: Dictionary, sid: String) -> Dictionary:
	var text = str(args.get("text", "")).strip_edges()
	if text == "":
		return {"ok": false, "error": "text is empty"}
	runtime.agents.reply(sid, text)
	return {"ok": true}


func _t_release_slot(args: Dictionary, sid: String) -> Dictionary:
	return runtime.matches.release(str(args.get("slot", "")), sid)


func _t_wait_for_turn(args: Dictionary, sid: String):
	var slot = _slot(args, sid)
	if slot.has("error"):
		yield(runtime.get_tree(), "idle_frame")
		return slot
	var max_wait = float(runtime.config.get_value("mcp.max_wait_s", 25))
	var timeout_s = clamp(float(args.get("timeout_s", 20)), 1.0, max(1.0, max_wait))
	var held = yield(_hold_for_notes(sid, timeout_s), "completed")
	if not held.empty():
		return held
	# Waits in short steps, so a message from the player ends the wait.
	var deadline = Util.now_ms() + int(timeout_s * 1000.0)
	var waited = {}
	while true:
		if runtime.agents.has_messages(sid):
			return {"ok": true, "status": "operator_message", "message": "the player sent you a message (operator_messages); answer with operator_reply, then call wait_for_turn again"}
		waited = yield(runtime.matches.wait_turn(slot["slot"], clamp((deadline - Util.now_ms()) / 1000.0, 0.1, 1.0)), "completed")
		if waited["status"] != "waiting" or Util.now_ms() >= deadline:
			break
	if waited["status"] != "your_turn":
		waited["ok"] = true
		_add_schema_task(waited, sid)
		return waited
	var view = runtime.matches.turn_view(slot["slot"], str(args.get("detail", "summary")))
	view["ok"] = true
	view["status"] = "your_turn"
	var first = not runtime.matches.has_decided(slot["slot"])
	if first:
		view["how_to_play"] = Prompts.QUICK_START
		_add_notes_hint(view)
		_add_memories(view)
	# Trash talk is asked for every turn; plain speech is mentioned once.
	if runtime.speech.trash_talk() or (first and runtime.speech.enabled()):
		view["talk"] = Prompts.talk_rules(runtime, slot["slot"])
	return view


func _t_get_turn(args: Dictionary, sid: String) -> Dictionary:
	var slot = _slot(args, sid, false)
	if slot.has("error"):
		return slot
	var view = runtime.matches.turn_view(slot["slot"], str(args.get("detail", "summary")))
	if view.empty():
		return {"ok": true, "status": "no_open_turn", "match": runtime.matches.status()}
	view["ok"] = true
	var task = runtime.schema_jobs.task_for(sid, true)
	if not task.empty():
		view["schema_task"] = task
	return view


func _t_simulate(args: Dictionary, sid: String):
	var slot = _slot(args, sid, false)
	if slot.has("error"):
		yield(runtime.get_tree(), "idle_frame")
		return slot
	if not bool(runtime.config.get_value("simulation.enabled", true)):
		yield(runtime.get_tree(), "idle_frame")
		return {"ok": false, "error": "simulation is disabled in settings"}
	var theirs = null
	if str(args.get("opponent_action", "")) != "":
		theirs = {"action": args["opponent_action"], "data": args.get("opponent_data"), "extra": args.get("opponent_extra", {})}
	var result = yield(runtime.matches.simulate(slot["slot"],
		{"action": str(args.get("action", "")), "data": args.get("data"), "extra": args.get("extra", {}), "then": args.get("then", [])},
		theirs, Util.as_int(args.get("ticks", 0))), "completed")
	return result


func _t_look_ahead(args: Dictionary, sid: String):
	var slot = _slot(args, sid, false)
	if slot.has("error"):
		yield(runtime.get_tree(), "idle_frame")
		return slot
	if not bool(runtime.config.get_value("simulation.enabled", true)):
		yield(runtime.get_tree(), "idle_frame")
		return {"ok": false, "error": "simulation is disabled in settings"}
	var timeout_s = float(runtime.config.get_value("turns.timeout_s.mcp", 0))
	var turn = runtime.matches.turns.get(slot["slot"])
	var limit = Util.now_ms() + 600000
	if timeout_s > 0 and turn != null:
		limit = turn["opened_ms"] + int(max(5.0, timeout_s - 10.0) * 1000.0)
	return yield(runtime.core.look_ahead(slot["slot"], args, limit), "completed")


func _t_submit_action(args: Dictionary, sid: String):
	var turn = runtime.matches.known_turn(str(args.get("turn_token", "")))
	if turn != null:
		var owner_check = _slot({"slot": turn["slot"]}, sid)
		if owner_check.has("error"):
			yield(runtime.get_tree(), "idle_frame")
			return owner_check
	var agent = runtime.agents.session_info(sid)
	var source = ("agent:%s" % agent["mode"]) if not agent.empty() else ("mcp:%s" % sid.substr(0, 8))
	var result = runtime.matches.submit(str(args.get("turn_token", "")), str(args.get("action", "")),
		args.get("data"), args.get("extra", {}), source)
	if result["ok"] and str(args.get("say", "")).strip_edges() != "":
		var said = runtime.speech.say(turn["slot"], str(args["say"]))
		if not said["ok"]:
			result["say_note"] = said["error"]
	if not result["ok"] or not bool(args.get("wait_for_outcome", true)):
		yield(runtime.get_tree(), "idle_frame")
		return result
	# Same cap as wait_for_turn, so the call stays well inside client timeouts.
	var max_wait = max(1.0, float(runtime.config.get_value("mcp.max_wait_s", 25)))
	var timeout_s = clamp(float(args.get("timeout_s", 20)), 1.0, max_wait)
	result["outcome"] = yield(runtime.matches.wait_outcome(turn["slot"], result["turn_tick"], timeout_s), "completed")
	result["next"] = "call wait_for_turn"
	return result


func _t_say(args: Dictionary, sid: String) -> Dictionary:
	var slot = _slot(args, sid)
	if slot.has("error"):
		return slot
	return runtime.speech.say(slot["slot"], str(args.get("text", "")))


func _t_get_match_log(args: Dictionary, _sid: String) -> Dictionary:
	var log_data = runtime.matches.match_log(Util.as_int(args.get("last_n", 20), 20))
	log_data["ok"] = true
	return log_data


func _t_describe_character(args: Dictionary, _sid: String) -> Dictionary:
	var entry = _entry(args)
	if entry.has("error"):
		return entry
	return runtime.describe_character(entry, args.get("moves", []))


func _t_introspect_character(args: Dictionary, _sid: String) -> Dictionary:
	var entry = _entry(args)
	if entry.has("error"):
		return entry
	return runtime.introspect_character(entry, args.get("moves", []), bool(args.get("include_source", false)),
		Util.as_int(args.get("offset", 0)), Util.as_int(args.get("limit", 40), 40))


func _t_submit_character_schema(args: Dictionary, sid: String) -> Dictionary:
	var entry = _entry(args)
	if entry.has("error"):
		return entry
	var session = runtime.mcp.sessions.get(sid, {})
	var provenance = {"by": "mcp", "client": session.get("client", {}).get("name", "unknown"), "at": Time.get_datetime_string_from_system()}
	var result = runtime.schemas.submit(entry, args.get("schema"), provenance, bool(args.get("replace", false)), bool(args.get("override", false)))
	if result.get("ok", false):
		var progress = runtime.schema_jobs.note_progress(sid, entry["display_name"])
		if not progress.empty():
			result["schema_task"] = progress
	return result


func _t_generate_character_schema(args: Dictionary, _sid: String) -> Dictionary:
	var entry = _entry(args)
	if entry.has("error"):
		return entry
	return runtime.annotator.start(entry, bool(args.get("force", false)))


func _t_export_character_schema(args: Dictionary, _sid: String) -> Dictionary:
	var entry = _entry(args)
	if entry.has("error"):
		return entry
	return runtime.schemas.export_schema(entry)


func _t_fetch_registry_schema(args: Dictionary, _sid: String):
	var entry = _entry(args)
	if entry.has("error"):
		yield(runtime.get_tree(), "idle_frame")
		return entry
	var result = yield(runtime.fetch_registry(entry), "completed")
	return result


func _t_read_source(args: Dictionary, _sid: String) -> Dictionary:
	if not bool(runtime.config.get_value("source_access.enabled", true)):
		return {"ok": false, "error": "source access is disabled in settings"}
	return runtime.sources.read(str(args.get("path", "")), Util.as_int(args.get("start_line", 1), 1), Util.as_int(args.get("max_lines", 400), 400))


func _t_search_source(args: Dictionary, _sid: String) -> Dictionary:
	if not bool(runtime.config.get_value("source_access.enabled", true)):
		return {"ok": false, "error": "source access is disabled in settings"}
	return runtime.sources.search(str(args.get("query", "")), str(args.get("path_prefix", "res://")), Util.as_int(args.get("max_results", 40), 40))


func _t_list_source_files(args: Dictionary, _sid: String) -> Dictionary:
	if not bool(runtime.config.get_value("source_access.enabled", true)):
		return {"ok": false, "error": "source access is disabled in settings"}
	return runtime.sources.list(str(args.get("path", "res://")))


func _t_get_settings(_args: Dictionary, _sid: String) -> Dictionary:
	return {"ok": true, "settings": runtime.config.redacted()}


func _t_update_setting(args: Dictionary, _sid: String) -> Dictionary:
	var path = str(args.get("path", ""))
	var allowed = false
	for prefix in SETTING_PREFIXES:
		if path.begins_with(prefix):
			allowed = true
	for blocked in SETTING_BLOCKLIST:
		if path.find(blocked) != -1:
			allowed = false
	if not allowed:
		return {"ok": false, "error": "setting %s cannot be changed over MCP (allowed: %s; never keys or URLs)" % [path, str(SETTING_PREFIXES)]}
	# Some settings legitimately default to null (e.g. temperature), so probe with a sentinel.
	if str(runtime.config.get_value(path, "__missing__")) == "__missing__":
		return {"ok": false, "error": "unknown setting %s" % path}
	runtime.config.set_value(path, args.get("value"))
	runtime.config.save()
	if path.begins_with("controllers."):
		runtime.matches.set_controller(path.get_extension(), str(args.get("value")))
	return {"ok": true, "path": path, "value": args.get("value")}


# --- helpers ---

# Resolves which slot a session acts for, auto-claiming an unowned mcp slot.
func _slot(args: Dictionary, sid: String, must_control: bool = true) -> Dictionary:
	var matches = runtime.matches
	var slot = str(args.get("slot", ""))
	# An agent budok started plays its own slot, whatever its controller.
	var agent = runtime.agents.session_info(sid) if runtime.agents != null else {}
	if not agent.empty():
		if slot != "" and slot != agent["slot"] and must_control:
			return {"ok": false, "error": "you play %s only" % agent["slot"]}
		return {"slot": agent["slot"] if slot == "" or must_control else slot}
	if slot == "":
		var mine = matches.slots_of(sid)
		if mine.size() == 1:
			return {"slot": mine[0]}
		if mine.size() > 1:
			return {"ok": false, "error": "this session controls both slots; pass slot"}
		var free = []
		for candidate in ["p1", "p2"]:
			if matches.controllers[candidate] == "mcp" and matches.owners[candidate] == "":
				free.append(candidate)
		if free.size() != 1:
			return {"ok": false, "error": "pass slot (p1 or p2), or claim_slot first; controllers are %s" % str(matches.controllers)}
		slot = free[0]
	if not (slot in ["p1", "p2"]):
		return {"ok": false, "error": "slot must be p1 or p2"}
	if not must_control:
		return {"slot": slot}
	if matches.owners[slot] == sid:
		return {"slot": slot}
	if matches.owners[slot] != "" and _owner_gone(matches.owners[slot], sid):
		matches.claim(slot, sid, true)
		return {"slot": slot}
	if matches.owners[slot] != "":
		return {"ok": false, "error": "%s is controlled by another active MCP session; claim_slot with force=true to take it" % slot}
	if matches.controllers[slot] != "mcp":
		return {"ok": false, "error": "%s is controlled by '%s'; call claim_slot to take it over" % [slot, matches.controllers[slot]]}
	matches.claim(slot, sid)
	return {"slot": slot}


# A slot owner that ended its session or has not called anything for a while
# (a chatbot app restarted, so it reconnects with a new session id).
func _owner_gone(owner_sid: String, sid: String) -> bool:
	if owner_sid == "" or owner_sid == sid:
		return false
	var owner = runtime.mcp.sessions.get(owner_sid)
	return owner == null or Util.now_ms() - int(owner.get("last_seen_ms", 0)) > SESSION_TAKEOVER_MS


func _entry(args: Dictionary) -> Dictionary:
	var query = str(args.get("character", ""))
	if query == "" and str(args.get("slot", "")) in ["p1", "p2"]:
		var info = runtime.matches.match_info.get("characters", {}).get(args["slot"])
		if info is Dictionary:
			return info
		return {"ok": false, "error": "no character in %s (no match running)" % args["slot"]}
	var entry = runtime.roster.resolve(query)
	if entry == null:
		return {"ok": false, "error": "unknown character '%s'; call list_characters" % query}
	var loaded = runtime.roster.ensure_loaded(entry)
	if not loaded["ok"]:
		return {"ok": false, "error": loaded["error"]}
	return entry

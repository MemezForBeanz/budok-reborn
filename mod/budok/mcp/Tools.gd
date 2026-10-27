extends Reference

# MCP tool catalogue. Handlers are thin wrappers over the runtime API so the
# in-mod autopilot, automation scripts and external MCP clients all exercise
# the same code. A handler returns a Dictionary, or a GDScriptFunctionState
# for long-running calls (the server answers when it completes).

const Util = preload("res://budok/core/Util.gd")
const MatchStarter = preload("res://budok/core/MatchStarter.gd")
const SETTING_PREFIXES := ["controllers.", "turns.", "simulation.", "ai.play.", "ai.annotate."]
const SETTING_BLOCKLIST := ["api_key", "base_url", "auth_token"]
const SESSION_TAKEOVER_MS := 120000

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
	return call("_t_" + name, args, sid)


# --- definitions ---

func _define() -> void:
	var slot = {"type": "string", "enum": ["p1", "p2"], "description": "Player slot. Defaults to the slot this session controls."}
	var xy = {"type": "object", "properties": {"x": {"type": "integer"}, "y": {"type": "integer"}}}
	var extra = {"type": "object", "description": "Optional extras: di {x,y} (-100..100, screen space), reverse (bool), feint (bool), and any character extras listed in the turn's extras.character.", "additionalProperties": true}
	var data = {"description": "Move parameters shaped by the action's payload spec (omit to use the game's default)."}
	var character = {"type": "string", "description": "Character name as shown by list_characters (display or internal name)."}
	_add("get_status", "Status", "Server, match and controller status, open turns, schema coverage and background jobs. Call first.", {}, [], true)
	_add("list_characters", "List characters", "All playable characters (vanilla, newer builds and modded) with schema status.", {}, [], true)
	_add("start_match", "Start match", "Start a local match. Works from the menu or mid-match (the current match is abandoned).",
		{"p1": character, "p2": character,
		"controllers": {"type": "object", "description": "Per-slot controller for this match: human | mcp | ai.",
			"properties": {"p1": {"type": "string", "enum": ["human", "mcp", "ai"]}, "p2": {"type": "string", "enum": ["human", "mcp", "ai"]}}},
		"claim": {"type": "string", "enum": ["p1", "p2", "both", "none"], "description": "Slot(s) this session will play (default: every mcp slot)."},
		"starting_hp": {"type": "integer", "minimum": 50, "description": "Override both players' HP (shorter matches)."},
		"settings": {"type": "object", "description": "Native match settings: stage_width, game_length, di_enabled, turbo_mode, infinite_resources, one_hit_ko, burst_enabled, always_perfect_parry, char_distance."}},
		["p1", "p2"])
	_add("set_controller", "Set controller", "Change who controls a slot right now: human, mcp or ai (the in-game API-key autopilot).",
		{"slot": slot, "controller": {"type": "string", "enum": ["human", "mcp", "ai"]}}, ["slot", "controller"])
	_add("claim_slot", "Claim slot", "Take control of a slot for this MCP session (sets its controller to mcp). A slot held by a disconnected or idle (2 min) session is taken over automatically; force takes it from a live one.",
		{"slot": slot, "force": {"type": "boolean"}}, ["slot"])
	_add("release_slot", "Release slot", "Give a claimed slot back (the human can play it again).", {"slot": slot}, ["slot"])
	_add("wait_for_turn", "Wait for turn", "Long-poll until your slot must choose a move. Returns the turn token, a plain-language situation, the observation and legal actions. Returns status 'waiting' after timeout_s: just call again.",
		{"slot": slot, "timeout_s": {"type": "number", "minimum": 1, "maximum": 50, "description": "Default 20."},
		"detail": {"type": "string", "enum": ["summary", "full"], "description": "full adds raw resources, move notes and the opponent's options."}}, [])
	_add("get_turn", "Get turn", "The currently open turn for your slot, without waiting.", {"slot": slot, "detail": {"type": "string", "enum": ["summary", "full"]}}, [], true)
	_add("simulate", "Simulate", "Preview a move on the real engine from the current turn: your action vs an assumed opponent action (default: they hold). Returns damage, end states, frame advantage and events. Never reveals the opponent's real choice.",
		{"slot": slot, "action": {"type": "string"}, "data": data, "extra": extra,
		"opponent_action": {"type": "string", "description": "Assumed opponent move (must be legal for them this turn)."},
		"opponent_data": data, "opponent_extra": extra,
		"ticks": {"type": "integer", "minimum": 10, "maximum": 300, "description": "Max ticks to simulate (default from settings)."}},
		["action"], true)
	_add("submit_action", "Submit action", "Lock in your move for the turn. Validated against the game; on error nothing is applied and you can retry with the same token.",
		{"turn_token": {"type": "string"}, "action": {"type": "string"}, "data": data, "extra": extra,
		"wait_for_outcome": {"type": "boolean", "description": "Wait until the turn resolves and report what happened (default true)."},
		"timeout_s": {"type": "number", "minimum": 1, "maximum": 50}}, ["turn_token", "action"])
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
	_add("get_settings", "Get settings", "Current budok settings (secrets redacted).", {}, [], true)
	_add("update_setting", "Update setting", "Change one setting under controllers.*, turns.*, simulation.*, ai.play.* or ai.annotate.* (no keys or URLs).",
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
	return status


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
	return result


func _t_set_controller(args: Dictionary, _sid: String) -> Dictionary:
	return runtime.matches.set_controller(str(args.get("slot", "")), str(args.get("controller", "")))


func _t_claim_slot(args: Dictionary, sid: String) -> Dictionary:
	var slot = str(args.get("slot", ""))
	var force = bool(args.get("force", false)) or _owner_gone(runtime.matches.owners.get(slot, ""), sid)
	return runtime.matches.claim(slot, sid, force)


func _t_release_slot(args: Dictionary, sid: String) -> Dictionary:
	return runtime.matches.release(str(args.get("slot", "")), sid)


func _t_wait_for_turn(args: Dictionary, sid: String):
	var slot = _slot(args, sid)
	if slot.has("error"):
		yield(runtime.get_tree(), "idle_frame")
		return slot
	var max_wait = float(runtime.config.get_value("mcp.max_wait_s", 25))
	var timeout_s = clamp(float(args.get("timeout_s", 20)), 1.0, max(1.0, max_wait))
	var waited = yield(runtime.matches.wait_turn(slot["slot"], timeout_s), "completed")
	if waited["status"] != "your_turn":
		waited["ok"] = true
		return waited
	var view = runtime.matches.turn_view(slot["slot"], str(args.get("detail", "summary")))
	view["ok"] = true
	view["status"] = "your_turn"
	return view


func _t_get_turn(args: Dictionary, sid: String) -> Dictionary:
	var slot = _slot(args, sid, false)
	if slot.has("error"):
		return slot
	var view = runtime.matches.turn_view(slot["slot"], str(args.get("detail", "summary")))
	if view.empty():
		return {"ok": true, "status": "no_open_turn", "match": runtime.matches.status()}
	view["ok"] = true
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
		{"action": str(args.get("action", "")), "data": args.get("data"), "extra": args.get("extra", {})},
		theirs, Util.as_int(args.get("ticks", 0))), "completed")
	return result


func _t_submit_action(args: Dictionary, sid: String):
	var turn = runtime.matches.turn_for_token(str(args.get("turn_token", "")))
	if turn != null:
		var owner_check = _slot({"slot": turn["slot"]}, sid)
		if owner_check.has("error"):
			yield(runtime.get_tree(), "idle_frame")
			return owner_check
	var result = runtime.matches.submit(str(args.get("turn_token", "")), str(args.get("action", "")),
		args.get("data"), args.get("extra", {}), "mcp:%s" % sid.substr(0, 8))
	if not result["ok"] or not bool(args.get("wait_for_outcome", true)):
		yield(runtime.get_tree(), "idle_frame")
		return result
	var outcome = yield(runtime.matches.wait_outcome(turn["slot"], clamp(float(args.get("timeout_s", 20)), 1.0, 50.0)), "completed")
	result["outcome"] = outcome
	result["next"] = "call wait_for_turn"
	return result


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
	return runtime.schemas.submit(entry, args.get("schema"), provenance, bool(args.get("replace", false)), bool(args.get("override", false)))


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

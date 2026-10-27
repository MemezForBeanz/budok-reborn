extends Node

# Token mode: plays every slot whose controller is "ai" with the model set in
# ai.play. Each turn is a fresh short conversation (stable cached system
# prompt + this turn's situation) in which the model may simulate candidate
# moves and look up move notes before it must call submit_action. Memory across
# turns is the match history plus the model's own one-line notes.

const Util = preload("res://budok/core/Util.gd")
const Prompts = preload("res://budok/ai/Prompts.gd")
const REMEMBER_HELP := ("Save one lesson for future matches (kept in this game install and shown to every bot later). "
	+ "about: opponent (their character), matchup (your character against theirs), self (your character) or general.")
const SIMULATE_HELP := ("Preview one of your legal moves on the real engine against an assumed opponent move (omit opponent_action to assume they hold). "
	+ "Returns damage, end states, frame advantage and why an attack missed. then: your follow-ups for later decisions inside the preview.")
const REMEMBER_TOOL := {
	"name": "remember",
	"description": REMEMBER_HELP,
	"parameters": {"type": "object", "properties": {
		"about": {"type": "string", "enum": ["opponent", "matchup", "self", "general"]},
		"text": {"type": "string", "description": "One concrete lesson, under 600 characters."}},
		"required": ["about", "text"]},
}

var runtime = null
var llm = null
var stats := {"turns": 0, "fallbacks": 0, "input_tokens": 0, "output_tokens": 0, "last_error": "", "last_decision": ""}
var _busy := {"p1": "", "p2": ""}
var _notes := {"p1": [], "p2": []}
var _system_cache := {"p1": "", "p2": ""}


func setup(runtime_ref, llm_ref) -> void:
	runtime = runtime_ref
	llm = llm_ref
	runtime.matches.connect("turn_opened", self, "_on_turn_opened")
	runtime.matches.connect("match_started", self, "_on_match_started")
	runtime.matches.connect("match_ended", self, "_on_match_ended")


func _on_match_started(_info) -> void:
	_notes = {"p1": [], "p2": []}
	_system_cache = {"p1": "", "p2": ""}


func _on_turn_opened(slot: String, token: String) -> void:
	if runtime.matches.controllers.get(slot) != "ai" or _busy[slot] == token:
		return
	_busy[slot] = token
	_take_turn(slot, token)


func _tools() -> Array:
	var tools = []
	if bool(runtime.config.get_value("ai.play.allow_simulation", true)) and bool(runtime.config.get_value("simulation.enabled", true)):
		tools.append({
			"name": "simulate",
			"description": SIMULATE_HELP,
			"parameters": {"type": "object", "properties": {
				"action": {"type": "string"}, "data": {}, "extra": {"type": "object"}, "then": {"type": "array", "items": {"type": "object"}},
				"opponent_action": {"type": "string"}, "opponent_data": {}}, "required": ["action"]},
		})
	tools.append(REMEMBER_TOOL)
	tools.append({
		"name": "describe_moves",
		"description": "Notes and measured data for specific moves of you or the opponent.",
		"parameters": {"type": "object", "properties": {
			"who": {"type": "string", "enum": ["me", "opponent"]},
			"moves": {"type": "array", "items": {"type": "string"}}}, "required": ["who", "moves"]},
	})
	tools.append({
		"name": "submit_action",
		"description": "Lock in your move for this turn. Required exactly once.",
		"parameters": {"type": "object", "properties": {
			"action": {"type": "string"}, "data": {}, "extra": {"type": "object"},
			"note": {"type": "string", "description": "One short line on why (kept as memory for later turns)."}},
			"required": ["action"]},
	})
	return tools


func _take_turn(slot: String, token: String) -> void:
	yield(get_tree(), "idle_frame")
	# Match-start notes for these characters come first (schemas.auto).
	while runtime.schema_jobs.holding() and runtime.matches.turn_for_token(token) != null:
		yield(get_tree().create_timer(0.5), "timeout")
	var view = runtime.matches.turn_view(slot, "summary")
	if view.empty() or view["turn_token"] != token:
		_busy[slot] = ""
		return
	if _system_cache[slot] == "":
		_system_cache[slot] = Prompts.play_system(runtime, slot)
	var cfg = runtime.config.get_value("ai.play", {})
	var max_steps = int(cfg.get("max_steps", 6))
	var max_sims = int(cfg.get("max_simulations", 3))
	var messages = [llm.user_message(_turn_prompt(slot, view, max_sims))]
	var tools = _tools()
	var simulations = 0
	var submitted = false
	for _step in range(max_steps):
		if runtime.matches.turn_for_token(token) == null:
			break
		var reply = yield(llm.chat("play", _system_cache[slot], messages, tools), "completed")
		if not reply.get("ok", false):
			stats["last_error"] = str(reply.get("error", "unknown error"))
			push_warning("budok autopilot %s: %s" % [slot, stats["last_error"]])
			break
		_count_usage(reply.get("usage", {}))
		messages.append(reply["assistant"])
		if reply["tool_calls"].empty():
			messages.append(llm.user_message("Call submit_action now with one of the legal actions."))
			continue
		var results = []
		for tool_call in reply["tool_calls"]:
			var input = tool_call["input"] if tool_call["input"] is Dictionary else {}
			var output = {}
			match str(tool_call["name"]):
				"simulate":
					if simulations >= max_sims:
						output = {"ok": false, "error": "simulation budget for this turn is used up; decide and submit"}
					else:
						simulations += 1
						var theirs = null
						if str(input.get("opponent_action", "")) != "":
							theirs = {"action": input["opponent_action"], "data": input.get("opponent_data")}
						output = yield(runtime.matches.simulate(slot, {"action": str(input.get("action", "")), "data": input.get("data"), "then": input.get("then", []),
							"extra": input.get("extra", {})}, theirs, 0), "completed")
				"describe_moves":
					output = _describe(slot, str(input.get("who", "me")), input.get("moves", []))
				"remember":
					output = _save_memory(slot, input)
				"submit_action":
					output = runtime.matches.submit(token, str(input.get("action", "")), input.get("data"), input.get("extra", {}),
						"ai:%s" % str(cfg.get("model", "")))
					if output.get("ok", false):
						submitted = true
						_remember(slot, view["tick"], str(input.get("action", "")), str(input.get("note", reply.get("text", ""))))
				_:
					output = {"ok": false, "error": "unknown tool"}
			results.append({"id": tool_call["id"], "content": Util.json_str(output), "is_error": not output.get("ok", true)})
		if submitted:
			break
		messages += llm.tool_results("play", results)
	if not submitted and runtime.matches.turn_for_token(token) != null:
		stats["fallbacks"] += 1
		var fallback = str(runtime.config.get_value("turns.fallback_action", "Continue"))
		var result = runtime.matches.submit(token, fallback, null, {}, "ai_fallback")
		if not result.get("ok", false):
			runtime.matches.submit(token, "Continue", null, {}, "ai_fallback")
	stats["turns"] += 1
	if _busy[slot] == token:
		_busy[slot] = ""


# After a match the model gets one short chance to write down what it learned.
func _on_match_ended(result) -> void:
	if not bool(runtime.config.get_value("ai.play.reflect_after_match", true)) or not bool(runtime.config.get_value("memory.enabled", true)):
		return
	for slot in ["p1", "p2"]:
		if runtime.matches.controllers.get(slot) == "ai":
			_reflect(slot, result, _notes[slot].duplicate())


func _reflect(slot: String, result: Dictionary, notes: Array) -> void:
	yield(get_tree(), "idle_frame")
	var characters = result.get("characters", {})
	var other = "p2" if slot == "p1" else "p1"
	var log_data = runtime.matches.match_log(16)
	var prompt = PoolStringArray([
		"The match is over. You played %s (%s) against %s. Result: %s." % [characters.get(slot, "?"), slot, characters.get(other, "?"), Util.json_str(result)],
		"Last turns (both moves, revealed): " + Util.json_str(log_data.get("history", [])),
		"Your notes during the match: " + (PoolStringArray(notes).join(" | ") if not notes.empty() else "(none)"),
		"Save the 1-3 lessons most worth remembering for future matches with remember (about the opponent's character, this matchup, or your own character). Skip anything generic or already obvious. Reply with nothing else.",
	]).join("\n")
	var messages = [llm.user_message(prompt)]
	var saved = 0
	for _step in range(2):
		var reply = yield(llm.chat("play", "You review YOMI Hustle matches you just played and keep short, concrete notes.", messages, [REMEMBER_TOOL]), "completed")
		if not reply.get("ok", false):
			stats["last_error"] = "reflection: %s" % str(reply.get("error", ""))
			return
		_count_usage(reply.get("usage", {}))
		if reply["tool_calls"].empty():
			return
		messages.append(reply["assistant"])
		var results = []
		for tool_call in reply["tool_calls"]:
			var output = _save_memory(slot, tool_call["input"] if tool_call["input"] is Dictionary else {}) if saved < 3 else {"ok": false, "error": "three lessons are enough"}
			if output.get("ok", false):
				saved += 1
			results.append({"id": tool_call["id"], "content": Util.json_str(output), "is_error": not output.get("ok", false)})
		messages += llm.tool_results("play", results)
		if saved >= 3:
			return


func _save_memory(slot: String, input: Dictionary) -> Dictionary:
	var names = {}
	for s in ["p1", "p2"]:
		var entry = runtime.matches.match_info.get("characters", {}).get(s, {})
		names[s] = entry.get("display_name", "") if entry is Dictionary else ""
	var mine = names[slot]
	var theirs = names["p2" if slot == "p1" else "p1"]
	var character = ""
	var opponent = ""
	match str(input.get("about", "general")):
		"opponent":
			character = theirs
		"self":
			character = mine
		"matchup":
			character = mine
			opponent = theirs
	return runtime.memory.remember(character, opponent, str(input.get("text", "")), [], "ai:%s" % str(runtime.config.get_value("ai.play.model", "")))


func _turn_prompt(slot: String, view: Dictionary, max_sims: int) -> String:
	var parts = [
		"Tick %d. %s" % [view["tick"], view["situation"]],
		"Observation: " + Util.json_str(view["observation"]),
		"Legal actions: " + Util.json_str(view["legal_actions"]),
		"Extras: " + Util.json_str(view["extras"]),
	]
	if not _notes[slot].empty():
		parts.append("Your recent notes: " + PoolStringArray(_notes[slot]).join(" | "))
	parts.append("You may simulate up to %d candidates, then call submit_action exactly once. Be brief." % max_sims)
	return PoolStringArray(parts).join("\n")


func _describe(slot: String, who: String, moves) -> Dictionary:
	var target = slot if who == "me" else ("p2" if slot == "p1" else "p1")
	var entry = runtime.matches.match_info.get("characters", {}).get(target)
	if not (entry is Dictionary):
		return {"ok": false, "error": "no character"}
	return runtime.describe_character(entry, moves if moves is Array else [])


func _remember(slot: String, tick: int, action: String, note: String) -> void:
	var line = "t%d %s: %s" % [tick, action, Util.truncate(note.strip_edges().replace("\n", " "), 120)]
	stats["last_decision"] = "%s %s" % [slot, line]
	_notes[slot].append(line)
	var keep = int(runtime.config.get_value("ai.play.memory_turns", 6))
	while _notes[slot].size() > keep:
		_notes[slot].pop_front()


func _count_usage(usage) -> void:
	if not (usage is Dictionary):
		return
	stats["input_tokens"] += Util.as_int(usage.get("input_tokens", usage.get("prompt_tokens", 0)))
	stats["output_tokens"] += Util.as_int(usage.get("output_tokens", usage.get("completion_tokens", 0)))

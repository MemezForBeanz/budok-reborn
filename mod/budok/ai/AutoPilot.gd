extends Node

# Token mode: plays every slot whose controller is "ai" or "tandem" with the
# model set in ai.play. Each turn is a fresh short conversation (stable cached
# system prompt + this turn's situation) in which the model may simulate
# candidate moves and look up move notes before it must call submit_action.
# In Tandem mode it also leads the decision core (look_ahead), which plays its
# candidates many turns ahead without using the model's context. Memory across
# turns is the match history plus the model's own one-line notes.

const Util = preload("res://budok/core/Util.gd")
const Lookahead = preload("res://budok/core/Lookahead.gd")
const Prompts = preload("res://budok/ai/Prompts.gd")
const DecisionCore = preload("res://budok/ai/DecisionCore.gd")
const CONTROLLERS := ["ai", "tandem"]
# Waits before sending a request again that failed for a reason that may pass
# (no connection, a timeout, the provider busy); the bot keeps the turn.
const RETRY_WAITS := [3.0, 6.0, 12.0, 20.0, 30.0]
# How long before the turn limit (turns.timeout_s) the decision core takes
# over when the model has not locked in a move: its engine pick is played.
const ENGINE_PICK_MS := 12000
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
var stats := {"turns": 0, "fallbacks": 0, "engine_picks": 0, "input_tokens": 0, "output_tokens": 0, "last_error": "", "last_decision": ""}
var _busy := {"p1": "", "p2": ""}
# The turn whose move the engine is picking because the model gave none.
var _ending := {"p1": "", "p2": ""}
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
	if not (runtime.matches.controllers.get(slot) in CONTROLLERS) or _busy[slot] == token:
		return
	_busy[slot] = token
	_take_turn(slot, token)


func _tools(slot: String) -> Array:
	var tools = []
	if runtime.matches.controllers.get(slot) == "tandem":
		tools.append({"name": "look_ahead", "description": DecisionCore.LOOK_AHEAD_HELP,
			"parameters": {"type": "object", "properties": DecisionCore.look_ahead_properties()}})
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
	tools.append(_submit_tool())
	return tools


# When the turn limit for this turn runs out (turns.timeout_s; 0 when none).
func _deadline(token: String) -> int:
	var turn = runtime.matches.turn_for_token(token)
	if turn == null:
		return 0
	var timeout_s = float(runtime.config.get_value("turns.timeout_s." + str(runtime.matches.controllers.get(turn["slot"])), 0))
	return turn["opened_ms"] + int(timeout_s * 1000.0) if timeout_s > 0 else 0


# Coroutine: ENGINE_PICK_MS before the turn limit, the engine takes over a turn
# the model has not locked in yet.
func _watch(slot: String, token: String, deadline: int) -> void:
	var wait_ms = deadline - ENGINE_PICK_MS - Util.now_ms()
	yield(get_tree().create_timer(max(0.05, wait_ms / 1000.0)), "timeout")
	if runtime.matches.turn_for_token(token) != null and _ending[slot] != token:
		_play_engine_pick(slot, token, "out of time")


# Coroutine: when the model gives no move (out of time, out of steps, or it
# could not be reached), the decision core's engine pick is played, as a CPU
# opponent would play it; the fallback move only when that finds nothing.
func _play_engine_pick(slot: String, token: String, reason: String) -> void:
	yield(get_tree(), "idle_frame")
	var turn = runtime.matches.turn_for_token(token)
	if turn == null or _ending[slot] == token:
		return
	_ending[slot] = token
	stats["fallbacks"] += 1
	var deadline = _deadline(token)
	var limit = deadline - 2000 if deadline > 0 else Util.now_ms() + ENGINE_PICK_MS
	var pick = yield(runtime.core.engine_pick(slot, turn, limit), "completed")
	if runtime.matches.turn_for_token(token) == null:
		return
	if pick != null:
		var result = runtime.matches.submit(token, pick["action"], pick["input"], Lookahead.extra_of(pick), "engine_pick")
		if result.get("ok", false):
			stats["engine_picks"] += 1
			stats["last_decision"] = "%s t%d: %s (engine pick: %s)" % [slot, turn["tick"], pick["label"], reason]
			push_warning("budok autopilot %s: no move from the model (%s), played the engine's pick %s" % [slot, reason, pick["label"]])
			return
	var fallback = str(runtime.config.get_value("turns.fallback_action", "Continue"))
	push_warning("budok autopilot %s: no move from the model (%s) and no engine pick, playing %s" % [slot, reason, fallback])
	if not runtime.matches.submit(token, fallback, null, {}, "ai_fallback").get("ok", false):
		runtime.matches.submit(token, "Continue", null, {}, "ai_fallback")


func _submit_tool() -> Dictionary:
	var submit = {
		"action": {"type": "string"}, "data": {}, "extra": {"type": "object"},
		"note": {"type": "string", "description": "One short line on why (kept as memory for later turns)."}}
	if runtime.speech.enabled():
		submit["say"] = {"type": "string", "description": "A line shown in a speech bubble above your character (under 80 characters)."}
	return {
		"name": "submit_action",
		"description": "Lock in your move for this turn. Required exactly once.",
		"parameters": {"type": "object", "properties": submit, "required": ["action"]},
	}


# Whether a failed request may work when sent again: no connection or a
# timeout, the provider busy or rate-limiting. A bad key or request, or a
# missing setting, will not.
static func _transient(reply: Dictionary) -> bool:
	if not reply.has("status"):
		return false
	var status = int(reply["status"])
	return status == 0 or status in [408, 409, 425, 429] or status >= 500


func _take_turn(slot: String, token: String) -> void:
	yield(get_tree(), "idle_frame")
	# Match-start notes for these characters come first (schemas.auto).
	while runtime.schema_jobs.holding() and runtime.matches.turn_for_token(token) != null:
		yield(get_tree().create_timer(0.5), "timeout")
	var view = runtime.matches.turn_view(slot, "summary")
	if view.empty() or view["turn_token"] != token:
		_busy[slot] = ""
		return
	# A CLI agent (agents.for_bots) plays this turn over MCP: only the turn limit
	# is kept here, and the engine picks when no agent could be started.
	if runtime.agents.thinks_for(slot):
		runtime.agents.ensure(slot)
		if runtime.agents.ready(slot):
			var limit = _deadline(token)
			if limit > 0:
				_watch(slot, token, limit)
		else:
			yield(_play_engine_pick(slot, token, "no CLI agent: %s" % runtime.agents.agents.get(slot, {}).get("error", "not started")), "completed")
		stats["turns"] += 1
		if _busy[slot] == token:
			_busy[slot] = ""
		return
	if _system_cache[slot] == "":
		_system_cache[slot] = Prompts.play_system(runtime, slot)
	var cfg = runtime.config.get_value("ai.play", {})
	var max_steps = int(cfg.get("max_steps", 6))
	var max_sims = int(cfg.get("max_simulations", 3))
	var messages = [llm.user_message(_turn_prompt(slot, view, max_sims))]
	var tools = _tools(slot)
	var simulations = 0
	var submitted = false
	var steps = 0
	var retries = 0
	var last_call = false
	var gave_up = ""
	var deadline = _deadline(token)
	if deadline > 0:
		_watch(slot, token, deadline)
	# The model decides the move: the turn waits for it, and a failed request is
	# sent again. Out of steps, it gets one more request that can only lock in.
	while runtime.matches.turn_for_token(token) != null and _ending[slot] != token:
		if steps >= max_steps:
			if last_call:
				gave_up = "no move after %d steps" % steps
				break
			last_call = true
			messages.append(llm.user_message("You have used every step for this turn. Call submit_action now with your best move."))
			tools = [_submit_tool()]
		var reply = yield(llm.chat("play", _system_cache[slot], messages, tools), "completed")
		if not reply.get("ok", false):
			stats["last_error"] = str(reply.get("error", "unknown error"))
			push_warning("budok autopilot %s: %s" % [slot, stats["last_error"]])
			if _transient(reply) and retries < RETRY_WAITS.size():
				yield(get_tree().create_timer(RETRY_WAITS[retries]), "timeout")
				retries += 1
				continue
			gave_up = stats["last_error"]
			break
		steps += 1
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
				"look_ahead":
					output = yield(runtime.core.look_ahead(slot, input, _look_ahead_limit(token)), "completed")
				"remember":
					output = _save_memory(slot, input)
				"submit_action":
					output = runtime.matches.submit(token, str(input.get("action", "")), input.get("data"), input.get("extra", {}),
						"ai:%s" % str(cfg.get("model", "")))
					if output.get("ok", false):
						submitted = true
						_remember(slot, view["tick"], str(input.get("action", "")), str(input.get("note", reply.get("text", ""))))
						if str(input.get("say", "")).strip_edges() != "":
							runtime.speech.say(slot, str(input["say"]))
				_:
					output = {"ok": false, "error": "unknown tool"}
			results.append({"id": tool_call["id"], "content": Util.json_str(output), "is_error": not output.get("ok", true)})
		if submitted:
			break
		messages += llm.tool_results("play", results)
	if not submitted and runtime.matches.turn_for_token(token) != null and _ending[slot] != token:
		yield(_play_engine_pick(slot, token, gave_up), "completed")
	stats["turns"] += 1
	if _busy[slot] == token:
		_busy[slot] = ""


# After a match the model gets one short chance to write down what it learned.
func _on_match_ended(result) -> void:
	if not bool(runtime.config.get_value("ai.play.reflect_after_match", true)) or not bool(runtime.config.get_value("memory.enabled", true)):
		return
	for slot in ["p1", "p2"]:
		if runtime.matches.controllers.get(slot) in CONTROLLERS and not runtime.agents.thinks_for(slot):
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
	if runtime.speech.trash_talk():
		parts.append("Trash talk is on: include a short taunt in submit_action's say.")
	if runtime.matches.controllers.get(slot) == "tandem":
		parts.append("You may use look_ahead (the decision core) and simulate up to %d candidates, then call submit_action exactly once. Be brief." % max_sims)
	else:
		parts.append("You may simulate up to %d candidates, then call submit_action exactly once. Be brief." % max_sims)
	return PoolStringArray(parts).join("\n")


# A look_ahead must end in time for the model to read it and submit: 20 s
# before the turn timeout (turns.timeout_s.<controller>).
func _look_ahead_limit(token: String) -> int:
	var turn = runtime.matches.turn_for_token(token)
	var timeout_s = float(runtime.config.get_value("turns.timeout_s." + str(runtime.matches.controllers.get(turn["slot"] if turn != null else "p1")), 0))
	if turn == null or timeout_s <= 0:
		return Util.now_ms() + 600000
	return turn["opened_ms"] + int(max(5.0, timeout_s - 20.0) * 1000.0)


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

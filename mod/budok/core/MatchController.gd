extends Node

# Owns the live match: notices when each player must choose, opens a "turn"
# (token + legal-action catalog snapshot), routes it to that slot's controller
# and applies decisions through the native UI path.
#
# Controllers per slot:
#   human - nothing happens; the player uses the game UI.
#   mcp   - an MCP client (chatbot) answers via wait_for_turn / submit_action.
#           Until a session claims the slot the human can still play it.
#   ai    - the in-mod token-mode autopilot answers (ai/AutoPilot.gd).
#
# Online/lobby matches are never controlled: a bot playing for you there is
# cheating, and remote peers would desync on our UI changes.

signal turn_opened(slot, token)
signal turn_closed(slot, token, how)
signal match_started(info)
signal match_ended(result)

const Util = preload("res://budok/core/Util.gd")
const ActionCatalog = preload("res://budok/core/ActionCatalog.gd")
const Observation = preload("res://budok/core/Observation.gd")
const Introspector = preload("res://budok/core/Introspector.gd")
const PayloadSpec = preload("res://budok/core/PayloadSpec.gd")
const CONTROLLERS := ["human", "mcp", "ai", "decision"]
# Controllers played inside the game (token mode): ai (chat model), decision (decision model).
const IN_GAME_BOTS := ["ai", "decision"]
const SLOTS := ["p1", "p2"]
const MATCH_LOG_DIR := "user://budok/matches"
const CLOSED_TURNS_KEPT := 16
const DETAILS := ["compact", "summary", "full"]
const SUMMARY_NOTE_CHARS := 160

var runtime = null

var game = null
var blocked_reason := ""
var match_info := {}
var history := []
var decisions := []
var controllers := {"p1": "human", "p2": "human"}
var owners := {"p1": "", "p2": ""}
var turns := {"p1": null, "p2": null}
var last_result = null

var _next_controllers = null
var _awaiting_frames := {"p1": 0, "p2": 0}
var _last_decision_tick := -1
# Each fighter's state at the last decision point, for the history entry.
var _decision_point := {}
# Recently closed turns by token, so a retried submit learns what happened.
var _closed := {}
var _closed_order := []
# Turns played as Continue for a slot (forced) since its last own decision.
var _auto_turns := {"p1": [], "p2": []}
var _auto_at := {"p1": -1, "p2": -1}
# Objects' movement over the last tick, by instance id (see _track_motion).
var _motion := {}
var _motion_positions := {}
var _motion_tick := -1
var _starting := false
var _buttons_cache := {}
var _move_specs := {"p1": {}, "p2": {}}


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	for slot in SLOTS:
		controllers[slot] = _valid_controller(runtime.config.get_value("controllers." + slot, "human"))


func _process(_delta: float) -> void:
	var global = Util.autoload("Global")
	var current = Util.prop(global, "current_game", null)
	if not Util.valid(current):
		current = null
	if current != game:
		_attach(current)
	if game == null or not match_info.has("started_ms") or last_result != null or blocked_reason != "":
		return
	_track_motion()
	for slot in SLOTS:
		_poll_slot(slot)


# --- public API (MCP tools, autopilot and automation scripts all use this) ---

func status() -> Dictionary:
	var out = {
		"in_match": game != null and match_info.has("started_ms") and last_result == null,
		"starting": _starting,
		"blocked_reason": blocked_reason,
		"controllers": controllers.duplicate(),
		"claimed_by": {"p1": owners["p1"] != "", "p2": owners["p2"] != ""},
		"open_turns": {},
		"last_result": last_result,
	}
	if game != null:
		out["tick"] = Util.as_int(Util.prop(game, "current_tick", 0))
		out["characters"] = {
			"p1": match_info.get("characters", {}).get("p1", {}).get("display_name", ""),
			"p2": match_info.get("characters", {}).get("p2", {}).get("display_name", ""),
		}
	for slot in SLOTS:
		if turns[slot] != null:
			out["open_turns"][slot] = turns[slot]["token"]
	if _next_controllers != null:
		out["next_match_controllers"] = _next_controllers
	return out


func set_controller(slot: String, controller: String) -> Dictionary:
	if not (slot in SLOTS):
		return {"ok": false, "error": "slot must be p1 or p2"}
	if not (controller in CONTROLLERS):
		return {"ok": false, "error": "controller must be one of %s" % str(CONTROLLERS)}
	controllers[slot] = controller
	if controller != "mcp":
		owners[slot] = ""
	_update_panel(slot)
	if turns[slot] != null and controller in IN_GAME_BOTS:
		emit_signal("turn_opened", slot, turns[slot]["token"])
	return {"ok": true, "controllers": controllers.duplicate()}


func set_next_match_controllers(value: Dictionary) -> void:
	_next_controllers = value.duplicate()


# Called right before a scripted match start so waiters do not see the
# previous match's result while the new game is still being set up.
func prepare_new_match() -> void:
	last_result = null
	_starting = true


func claim(slot: String, session_id: String, force: bool = false) -> Dictionary:
	if not (slot in SLOTS):
		return {"ok": false, "error": "slot must be p1 or p2"}
	if owners[slot] != "" and owners[slot] != session_id and not force:
		return {"ok": false, "error": "%s is already claimed by another MCP session; ask its owner to release it" % slot}
	owners[slot] = session_id
	controllers[slot] = "mcp"
	_update_panel(slot)
	return {"ok": true, "slot": slot, "controllers": controllers.duplicate()}


func release(slot: String, session_id: String) -> Dictionary:
	if owners.get(slot, "") != session_id:
		return {"ok": false, "error": "%s is not claimed by this session" % slot}
	owners[slot] = ""
	_update_panel(slot)
	return {"ok": true}


func release_session(session_id: String) -> void:
	for slot in SLOTS:
		if owners[slot] == session_id:
			owners[slot] = ""
			_update_panel(slot)


func slots_of(session_id: String) -> Array:
	var result = []
	for slot in SLOTS:
		if owners[slot] == session_id:
			result.append(slot)
	return result


func turn_for_token(token: String):
	for slot in SLOTS:
		if turns[slot] != null and turns[slot]["token"] == token:
			return turns[slot]
	return null


# Whether `slot` has made any decision yet this match.
func has_decided(slot: String) -> bool:
	for decision in decisions:
		if decision["slot"] == slot:
			return true
	return false


# Open or recently closed turn (retries of a submit can arrive after it closed).
func known_turn(token: String):
	var turn = turn_for_token(token)
	return turn if turn != null else _closed.get(token)


# `slot`'s turn at the decision point `tick`, open or already answered.
func turn_at(slot: String, tick: int):
	var turn = turns.get(slot)
	if turn != null and turn["tick"] == tick:
		return turn
	for i in range(_closed_order.size() - 1, -1, -1):
		var closed = _closed.get(_closed_order[i])
		if closed != null and closed["slot"] == slot and closed["tick"] == tick:
			return closed
	return null


# Everything a decision-maker needs for one open turn. detail: compact (move
# names and payload types only; notes via describe_character), summary (short
# notes and frame data) or full (all notes, raw resources, opponent's options).
func turn_view(slot: String, detail: String = "summary") -> Dictionary:
	var turn = turns.get(slot)
	if turn == null or turn.has("applied"):
		return {}
	if not (detail in DETAILS):
		detail = "summary"
	var obs = Observation.build(game, slot, _infos(), history, detail, _motion)
	var actions = turn["catalog"]["actions"]
	var extras = turn["catalog"]["extras"]
	var view = {
		"turn_token": turn["token"],
		"slot": slot,
		"tick": turn["tick"],
		"situation": Observation.situation(obs),
	}
	if not _auto_turns[slot].empty():
		var states = []
		for state_name in _auto_turns[slot]:
			if not (state_name in states):
				states.append(state_name)
		view["auto_continued"] = {"turns": _auto_turns[slot].size(), "your_states": states,
			"note": "Since your last move, these turns were played as Continue for you because it was your only option (mid-move, stunned, or frozen by something like a time stop). Set turns.forced_turns to never to be asked anyway."}
	if actions.size() == 1 and actions[0]["action"] == "Continue":
		# Mid-move or in hitstun: there is nothing to weigh but DI.
		view["only_option"] = "Continue"
		view["hint"] = "Continue is your only legal move (you are mid-move or being hit); submit it%s." % (
			", with extra.di {x, y} to steer your knockback" if extras.get("di") != null else "")
		if extras.get("di") != null:
			view["extras"] = {"di": extras["di"]}
		return view
	if detail == "compact":
		view["observation"] = Observation.compact(obs)
		view["legal_actions"] = _compact_actions(actions)
		view["extras"] = extras
		view["payload_help"] = PayloadSpec.help_for(actions)
		return view
	view["observation"] = obs
	view["legal_actions"] = _annotated_actions(slot, actions, detail)
	view["extras"] = extras
	view["payload_help"] = PayloadSpec.help_for(actions)
	var opponent_turn = turns.get(Observation.other(slot))
	if detail == "full" and opponent_turn != null:
		view["opponent_options"] = _annotated_actions(Observation.other(slot), opponent_turn["catalog"]["actions"], "summary")
	return view


# "QuickSlash (xy)", "Grab", "ChargeBlast (object: Spend)": enough to pick from
# and fill in; describe_character has the notes.
static func _compact_actions(actions: Array) -> Array:
	var out = []
	for action in actions:
		var text = action["action"]
		var payload = action.get("payload")
		if payload is Dictionary:
			var kind = payload["type"]
			if kind == "object":
				kind += ": " + PoolStringArray(payload.get("fields", {}).keys()).join(", ")
			elif kind == "direction8":
				kind += " " + PoolStringArray(payload.get("allowed", [])).join("/")
			elif kind == "int":
				kind += " %d..%d" % [payload["min"], payload["max"]]
			elif kind == "option":
				kind += " " + PoolStringArray(payload.get("choices", [])).join("/")
			text += " (%s)" % kind
		out.append(text)
	return out


func observation(slot: String, detail: String) -> Dictionary:
	if game == null:
		return {}
	return Observation.build(game, slot, _infos(), history, detail, _motion)


func submit(token: String, action: String, data, extra, source: String) -> Dictionary:
	var turn = known_turn(token)
	if turn == null:
		return {"ok": false, "error": "stale_turn", "message": "unknown turn token (from an earlier match or too old); call wait_for_turn"}
	if turn.has("closed") and not turn.has("applied"):
		return {"ok": false, "error": "stale_turn", "turn_tick": turn["tick"], "message": "this turn ended without your move (%s); call wait_for_turn" % turn["closed"]}
	if turn.has("applied"):
		return _already_applied(turn, action)
	var slot = turn["slot"]
	var buttons = _buttons(slot)
	var fighter = Observation.fighter_of(game, slot)
	if not ActionCatalog.is_awaiting(buttons, fighter):
		return {"ok": false, "error": "stale_turn", "message": "the game is no longer waiting on %s" % slot}
	var resolved = ActionCatalog.resolve(buttons, fighter, turn["catalog"], action, data, extra if extra is Dictionary else {})
	if not resolved["ok"]:
		return {"ok": false, "error": "invalid_action", "message": resolved["error"]}
	turn["applied"] = {"action": action, "data": resolved["data"], "extra": resolved["extra"], "source": source}
	if source != "auto_forced":
		_auto_turns[slot] = []
	decisions.append({"tick": turn["tick"], "slot": slot, "action": action, "data": Util.json_safe(resolved["data"]),
		"source": source, "think_ms": Util.now_ms() - turn["opened_ms"]})
	ActionCatalog.submit(buttons, action, resolved["data"], resolved["extra"])
	var out = {"ok": true, "turn_tick": turn["tick"], "applied": _applied_view(turn)}
	if resolved.has("notes"):
		out["notes"] = resolved["notes"]
	return out


# A retry of a turn that was already locked in (say the reply to the first
# submit got lost). Same move: report success again, so the caller can go on.
func _already_applied(turn: Dictionary, action: String) -> Dictionary:
	var applied = turn["applied"]
	if applied["action"] == action:
		return {"ok": true, "turn_tick": turn["tick"], "applied": _applied_view(turn), "already_applied": true,
			"message": "this move was already locked in for this turn"}
	return {"ok": false, "error": "already_submitted", "turn_tick": turn["tick"], "applied": _applied_view(turn),
		"message": "this turn was already decided (%s by %s); call wait_for_turn" % [applied["action"], applied["source"]]}


static func _applied_view(turn: Dictionary) -> Dictionary:
	var applied = turn["applied"]
	return {"action": applied["action"], "data": Util.json_safe(applied["data"]), "extra": Util.json_safe(applied["extra"])}


# Coroutine: waits until `slot` has an open turn (or the match ends).
func wait_turn(slot: String, timeout_s: float) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var deadline = Util.now_ms() + int(timeout_s * 1000.0)
	while true:
		if last_result != null:
			return {"status": "match_over", "result": last_result}
		if turns.get(slot) != null and not turns[slot].has("applied"):
			return {"status": "your_turn"}
		if Util.now_ms() >= deadline:
			return {"status": "waiting", "message": "no decision needed yet; call wait_for_turn again"}
		yield(get_tree().create_timer(0.1), "timeout")
	return {}


# Coroutine: after a submit, waits until the turn that opened at `turn_tick`
# has played out (the next decision point or the end of the match) and reports
# what happened: both moves, revealed only now, and the damage.
func wait_outcome(slot: String, turn_tick: int, timeout_s: float) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var deadline = Util.now_ms() + int(timeout_s * 1000.0)
	while true:
		var entry = history_entry(turn_tick)
		if last_result != null:
			var over = {"status": "match_over", "result": last_result}
			if entry != null:
				over["turn"] = entry
			return over
		if entry != null:
			return {"status": "resolved", "turn": entry, "your_turn": turns[slot] != null and not turns[slot].has("applied")}
		if Util.now_ms() >= deadline:
			break
		yield(get_tree().create_timer(0.1), "timeout")
	var other = turns[Observation.other(slot)]
	var opponent_choosing = other != null and not other.has("applied")
	return {"status": "pending", "waiting_on": "opponent" if opponent_choosing else "game",
		"message": "your move is locked in; %s. Call wait_for_turn: it returns when you must choose again, and get_match_log shows this turn once it resolves." % (
			"the opponent has not chosen yet" if opponent_choosing else "the turn is still playing out")}


# The history entry for the decision point at `tick`, once that turn resolved.
func history_entry(tick: int):
	for i in range(history.size() - 1, -1, -1):
		var entry = history[i]
		if entry["tick"] == tick:
			return entry
		if entry["tick"] < tick:
			break
	return null


# Coroutine: what-if preview from `slot`'s perspective.
func simulate(slot: String, mine: Dictionary, theirs, ticks: int) -> Dictionary:
	if game == null or last_result != null:
		yield(get_tree(), "idle_frame")
		return {"ok": false, "error": "no match in progress"}
	var turn = turns.get(slot)
	if turn == null:
		yield(get_tree(), "idle_frame")
		return {"ok": false, "error": "it is not %s's turn; simulations run from a decision point" % slot}
	var actions = {}
	var buttons = _buttons(slot)
	var fighter = Observation.fighter_of(game, slot)
	var mine_resolved = ActionCatalog.resolve(buttons, fighter, turn["catalog"], str(mine.get("action", "")), mine.get("data"), mine.get("extra", {}))
	if not mine_resolved["ok"]:
		yield(get_tree(), "idle_frame")
		return {"ok": false, "error": "your action: %s" % mine_resolved["error"]}
	actions[slot] = {"action": mine["action"], "data": mine_resolved["data"], "extra": mine_resolved["extra"]}
	var notes = mine_resolved.get("notes", []).duplicate()
	# Follow-ups for the decision points where only you act again (two-step
	# moves): played in order whenever you become actionable in the preview.
	var followups = []
	var states_map = Util.prop(Util.prop(fighter, "state_machine", null), "states_map", {})
	for step in mine.get("then", []) if mine.get("then") is Array else []:
		if not (step is Dictionary) or str(step.get("action", "")) == "":
			yield(get_tree(), "idle_frame")
			return {"ok": false, "error": "then: each step needs an action"}
		if not (states_map is Dictionary and states_map.has(str(step["action"]))):
			yield(get_tree(), "idle_frame")
			return {"ok": false, "error": "then: %s is not a move of this character" % step["action"]}
		var step_extra = mine_resolved["extra"].duplicate(true)
		step_extra["reverse"] = bool(step.get("extra", {}).get("reverse", false)) if step.get("extra") is Dictionary else false
		step_extra["feint"] = false
		followups.append({"action": str(step["action"]), "data": PayloadSpec._ints(PayloadSpec._unwrap(step.get("data"))), "extra": step_extra})
	actions[slot]["then"] = followups
	var other = Observation.other(slot)
	# The opponent chooses at this decision point if they got a turn at this
	# tick, even when they already locked in (their panel is inactive then).
	var other_turn = turn_at(other, turn["tick"])
	var choosing = [slot]
	if other_turn != null or _was_choosing(other):
		choosing.append(other)
	if other_turn != null and not (theirs is Dictionary and theirs.has("action")):
		# Assume they hold, with their own extras at neutral values.
		var hold = ActionCatalog.resolve(_buttons(other), Observation.fighter_of(game, other), other_turn["catalog"], "Continue", null, {}, false)
		if hold["ok"]:
			actions[other] = {"action": "Continue", "data": null, "extra": hold["extra"]}
	if theirs is Dictionary and theirs.has("action"):
		if not (other in choosing):
			yield(get_tree(), "idle_frame")
			return {"ok": false, "error": "the opponent has no turn at this decision point; omit opponent_action"}
		var other_catalog = other_turn["catalog"] if other_turn != null else {}
		if other_catalog.empty():
			yield(get_tree(), "idle_frame")
			return {"ok": false, "error": "opponent options are not known for this turn"}
		var theirs_resolved = ActionCatalog.resolve(_buttons(other), Observation.fighter_of(game, other),
			other_catalog, str(theirs["action"]), theirs.get("data"), theirs.get("extra", {}), false)
		if not theirs_resolved["ok"]:
			yield(get_tree(), "idle_frame")
			return {"ok": false, "error": "opponent action: %s" % theirs_resolved["error"]}
		actions[other] = {"action": theirs["action"], "data": theirs_resolved["data"], "extra": theirs_resolved["extra"]}
		for note in theirs_resolved.get("notes", []):
			notes.append("opponent " + note)
	var max_ticks = int(clamp(ticks if ticks > 0 else int(runtime.config.get_value("simulation.max_ticks", 120)), 10, 300))
	var result = yield(runtime.simulator.run(game, actions, choosing, max_ticks, slot), "completed")
	if not notes.empty() and result.get("ok", false):
		result["notes"] = notes
	return result


func infos() -> Dictionary:
	return _infos()


# Every move's payload spec (not only the legal ones), the facing its defaults
# were read with and the character extras' neutral values, for previews that
# play several turns ahead. Read at the slot's first turn of the match, right
# after its panel opened and before anyone could change the controls.
func move_specs(slot: String) -> Dictionary:
	return _move_specs.get(slot, {})


func match_log(last_n: int = 20) -> Dictionary:
	return {
		"characters": {
			"p1": match_info.get("characters", {}).get("p1", {}).get("display_name", ""),
			"p2": match_info.get("characters", {}).get("p2", {}).get("display_name", ""),
		},
		"history": history.slice(max(0, history.size() - last_n), history.size() - 1) if not history.empty() else [],
		"decisions": decisions.slice(max(0, decisions.size() - last_n), decisions.size() - 1) if not decisions.empty() else [],
		"result": last_result,
	}


# --- internals ---

func _attach(current) -> void:
	_detach()
	game = current
	if game == null:
		return
	if bool(Util.prop(game, "is_ghost", false)):
		game = null
		return
	var replay_manager = Util.autoload("ReplayManager")
	if bool(Util.prop(replay_manager, "playback", false)) or Util.prop(game, "match_data", {}).has("replay"):
		_apply_match_options(game)
		blocked_reason = "replay"
		return
	if not bool(Util.prop(game, "singleplayer", true)) or _online():
		blocked_reason = "online match: budok never controls online or lobby matches"
		return
	blocked_reason = ""
	last_result = null
	_starting = false
	history = []
	decisions = []
	_last_decision_tick = -1
	_decision_point = {}
	_closed = {}
	_closed_order = []
	_auto_turns = {"p1": [], "p2": []}
	_auto_at = {"p1": -1, "p2": -1}
	_motion = {}
	_motion_positions = {}
	_motion_tick = -1
	_move_specs = {"p1": {}, "p2": {}}
	if _next_controllers != null:
		for slot in SLOTS:
			if _next_controllers.has(slot):
				controllers[slot] = _valid_controller(_next_controllers[slot])
				if controllers[slot] != "mcp":
					owners[slot] = ""
		_next_controllers = null
	_apply_match_options(game)
	var characters = {}
	for slot in SLOTS:
		characters[slot] = runtime.roster.entry_for_fighter(Observation.fighter_of(game, slot))
	match_info = {"started_ms": Util.now_ms(), "characters": characters}
	# Introspect both characters now (cached) instead of during the first turn.
	_infos()
	if game.has_signal("game_won"):
		game.connect("game_won", self, "_on_game_won")
	emit_signal("match_started", match_info)


# The move panels live as long as the match UI; cache them instead of
# searching the whole scene tree every frame.
func _buttons(slot: String):
	var cached = _buttons_cache.get(slot)
	if not Util.valid(cached):
		cached = ActionCatalog.find_buttons(slot)
		_buttons_cache[slot] = cached
	return cached


func _detach() -> void:
	_buttons_cache.clear()
	for slot in SLOTS:
		if turns[slot] != null:
			_close_turn(slot, "match_closed")
	if Util.valid(game) and game.is_connected("game_won", self, "_on_game_won"):
		game.disconnect("game_won", self, "_on_game_won")
	game = null
	match_info = {}
	blocked_reason = ""


func _poll_slot(slot: String) -> void:
	var buttons = _buttons(slot)
	var fighter = Observation.fighter_of(game, slot)
	var awaiting = ActionCatalog.is_awaiting(buttons, fighter) and bool(Util.prop(game, "game_paused", true))
	var turn = turns[slot]
	if turn != null:
		# The tick only moves once the turn is over. A one-tick turn can end and
		# the next decision point start within a single frame, with the panel
		# never seen inactive, so a new tick also closes the turn.
		if awaiting and Util.as_int(Util.prop(game, "current_tick", 0)) == turn["tick"]:
			_check_timeout(slot, turn)
			return
		_close_turn(slot, "applied" if turn.has("applied") else "resolved_elsewhere")
	if not awaiting:
		_awaiting_frames[slot] = 0
		return
	# ActionButtons.activate() finishes over a couple of idle frames; wait
	# until the panel has settled before reading it.
	_awaiting_frames[slot] += 1
	if _awaiting_frames[slot] < 3:
		return
	_open_turn(slot, buttons, fighter)


func _open_turn(slot: String, buttons, fighter) -> void:
	var tick = Util.as_int(Util.prop(game, "current_tick", 0))
	_record_history(tick)
	var catalog = ActionCatalog.enumerate(buttons, fighter)
	var turn = {
		"token": "t%d-%s" % [tick, Util.random_hex(4)],
		"slot": slot,
		"tick": tick,
		"opened_ms": Util.now_ms(),
		"catalog": catalog,
	}
	turns[slot] = turn
	if _move_specs[slot].empty():
		_move_specs[slot] = _read_move_specs(buttons, fighter, catalog)
	_update_panel(slot)
	var bot_controlled = controllers[slot] in IN_GAME_BOTS or (controllers[slot] == "mcp" and owners[slot] != "")
	if bot_controlled and _is_forced(catalog, fighter):
		submit(turn["token"], "Continue", null, {}, "auto_forced")
		_auto_at[slot] = tick
		if _auto_turns[slot].size() < 50:
			_auto_turns[slot].append(str(Util.prop(Util.call_or(fighter, "current_state"), "state_name", "?")))
		return
	emit_signal("turn_opened", slot, turn["token"])


func _read_move_specs(buttons, fighter, catalog: Dictionary) -> Dictionary:
	var specs = {}
	for button in Util.prop(buttons, "buttons", []):
		var action = str(Util.prop(button, "action_name", "")) if Util.valid(button) else ""
		if action != "" and not specs.has(action):
			specs[action] = catalog["specs"][action] if catalog["specs"].has(action) else PayloadSpec.describe_data_node(Util.prop(button, "data_node", null))
	var extras = {}
	var character = catalog["extras"].get("character", {})
	for key in character:
		extras[key] = false if character[key]["default"] is bool else character[key]["default"]
	return {"specs": specs, "facing": Util.as_int(Util.call_or(fighter, "get_facing_int", [], 1), 1), "extras": extras}


func _close_turn(slot: String, how: String) -> void:
	var turn = turns[slot]
	turns[slot] = null
	_awaiting_frames[slot] = 0
	if turn == null:
		return
	turn["closed"] = how
	_closed[turn["token"]] = turn
	_closed_order.append(turn["token"])
	if _closed_order.size() > CLOSED_TURNS_KEPT:
		_closed.erase(_closed_order.pop_front())
	emit_signal("turn_closed", slot, turn["token"], how)


func _check_timeout(slot: String, turn: Dictionary) -> void:
	if turn.has("applied"):
		return
	# Bots wait for match-start notes (schemas.auto); the clock starts after.
	if runtime.schema_jobs != null and runtime.schema_jobs.holding():
		turn["opened_ms"] = Util.now_ms()
		return
	var controller = controllers[slot]
	if controller == "human" or (controller == "mcp" and owners[slot] == ""):
		return
	var timeout_s = float(runtime.config.get_value("turns.timeout_s." + controller, 0))
	if timeout_s <= 0 or Util.now_ms() - turn["opened_ms"] < int(timeout_s * 1000.0):
		return
	var fallback = str(runtime.config.get_value("turns.fallback_action", "Continue"))
	if not turn["catalog"]["specs"].has(fallback):
		fallback = "Continue"
	push_warning("budok: %s timed out after %ss, playing %s" % [slot, timeout_s, fallback])
	submit(turn["token"], fallback, null, {}, "timeout_fallback")


func _is_forced(catalog: Dictionary, fighter) -> bool:
	var rule = str(runtime.config.get_value("turns.forced_turns", "skip_unless_hurt"))
	if rule == "never" or catalog["actions"].size() != 1 or catalog["actions"][0]["action"] != "Continue":
		return false
	if rule == "skip_unless_hurt":
		var state = Util.call_or(fighter, "current_state")
		var hurt = bool(Util.prop(state, "is_hurt_state", false))
		return not (hurt and catalog["extras"].get("di") != null)
	return true


# The game records each player's committed input in ReplayManager.frames; we
# read the latest ones when the next decision point arrives, so the opponent's
# move is only revealed after it has resolved. A player who was mid-move at the
# decision point (busy) could only let it continue, so their "Continue" comes
# with the state that kept running.
func _record_history(tick: int) -> void:
	if tick == _last_decision_tick:
		return
	if tick < _last_decision_tick:
		# Undo in singleplayer rewinds the match; drop entries from the future.
		var kept = []
		for entry in history:
			if entry["tick"] < tick:
				kept.append(entry)
		history = kept
		_last_decision_tick = tick
		_decision_point = _snapshot_decision_point()
		return
	if _last_decision_tick >= 0:
		var entry = {"tick": _last_decision_tick}
		var replay_manager = Util.autoload("ReplayManager")
		for slot in SLOTS:
			var fighter = Observation.fighter_of(game, slot)
			var frames = Util.prop(replay_manager, "frames", {})
			var player_frames = frames.get(1 if slot == "p1" else 2, {}) if frames is Dictionary else {}
			var action = "(busy)"
			var latest = -1
			for frame_tick in player_frames:
				if int(frame_tick) > _last_decision_tick and int(frame_tick) <= tick and int(frame_tick) > latest:
					latest = int(frame_tick)
			if latest != -1 and player_frames[latest] is Dictionary:
				action = str(player_frames[latest].get("action", "?"))
			entry[slot] = {"action": action, "hp": Util.as_int(Util.prop(fighter, "hp", 0))}
			var before = _decision_point.get(slot, {})
			if before.get("busy", false):
				entry[slot]["busy"] = true
			if _auto_at[slot] == _last_decision_tick:
				entry[slot]["auto"] = true
			if before.get("busy", false) or action in ["Continue", "(busy)"]:
				entry[slot]["state"] = before.get("state", "?")
		if history.size() > 0:
			var prev = history[history.size() - 1]
			for slot in SLOTS:
				entry[slot]["damage_taken"] = int(max(0, prev[slot]["hp"] - entry[slot]["hp"]))
		history.append(entry)
		var limit = int(runtime.config.get_value("turns.history_length", 12)) * 4
		if history.size() > limit:
			history = history.slice(history.size() - limit, history.size() - 1)
	_last_decision_tick = tick
	_decision_point = _snapshot_decision_point()


# Samples object positions once per game tick. Many projectiles move by
# setting their position each tick and report a physics velocity of 0, so the
# real speed is the distance covered over the last tick.
func _track_motion() -> void:
	var tick = Util.as_int(Util.prop(game, "current_tick", 0))
	if tick == _motion_tick:
		return
	var positions = {}
	var list = Util.prop(game, "objects", [])
	for obj in list if list is Array else []:
		if Util.valid(obj):
			positions[obj.get_instance_id()] = Util.xy(Util.call_or(obj, "get_pos", [], Vector2.ZERO))
	var elapsed = tick - _motion_tick
	_motion = {}
	if _motion_tick >= 0 and elapsed > 0:
		for id in positions:
			var before = _motion_positions.get(id)
			if before != null:
				_motion[id] = {"x": int(round(float(positions[id]["x"] - before["x"]) / elapsed)),
					"y": int(round(float(positions[id]["y"] - before["y"]) / elapsed))}
	_motion_positions = positions
	_motion_tick = tick


func _snapshot_decision_point() -> Dictionary:
	var point = {}
	for slot in SLOTS:
		var fighter = Observation.fighter_of(game, slot)
		var state = Util.call_or(fighter, "current_state")
		point[slot] = {
			"state": str(Util.prop(state, "state_name", Util.prop(state, "name", "?"))),
			"busy": bool(Util.prop(fighter, "busy_interrupt", false)),
		}
	return point


func _on_game_won(winner) -> void:
	var p1 = Observation.fighter_of(game, "p1")
	var p2 = Observation.fighter_of(game, "p2")
	var winner_id = Util.as_int(winner, 0)
	last_result = {
		"winner": "p1" if winner_id == 1 else ("p2" if winner_id == 2 else "draw"),
		"end_tick": Util.as_int(Util.prop(game, "current_tick", 0)),
		"hp": {"p1": Util.as_int(Util.prop(p1, "hp", 0)), "p2": Util.as_int(Util.prop(p2, "hp", 0))},
		"characters": {
			"p1": match_info.get("characters", {}).get("p1", {}).get("display_name", ""),
			"p2": match_info.get("characters", {}).get("p2", {}).get("display_name", ""),
		},
		"controllers": controllers.duplicate(),
		"turns": decisions.size(),
	}
	_record_history(Util.as_int(Util.prop(game, "current_tick", 0)) + 1)
	for slot in SLOTS:
		if turns[slot] != null:
			_close_turn(slot, "match_over")
		_set_panel_hidden(slot, false)
	if bool(runtime.config.get_value("logging.match_logs", true)):
		var stamp = str(OS.get_unix_time())
		Util.write_json("%s/%s_%s_vs_%s.json" % [MATCH_LOG_DIR, stamp, Util.safe_file_name(last_result["characters"]["p1"]),
			Util.safe_file_name(last_result["characters"]["p2"])], {"result": last_result, "history": history, "decisions": decisions})
	emit_signal("match_ended", last_result)


func _was_choosing(slot: String) -> bool:
	var fighter = Observation.fighter_of(game, slot)
	return ActionCatalog.is_awaiting(_buttons(slot), fighter)


func _infos() -> Dictionary:
	var out = {}
	for slot in SLOTS:
		var entry = match_info.get("characters", {}).get(slot)
		out[slot] = runtime.schemas.describe(entry) if entry is Dictionary else {}
	return out


func _annotated_actions(slot: String, actions: Array, detail: String) -> Array:
	var info = _infos().get(slot, {})
	var moves = info.get("skeleton", {}).get("moves", {})
	var result = []
	for action in actions:
		var entry = action.duplicate(true)
		var notes = runtime.schemas.move_notes(info, entry["action"])
		if notes.has("category"):
			entry["category"] = notes["category"]
		if notes.has("summary"):
			entry["notes"] = notes["summary"] if detail == "full" else Util.truncate(notes["summary"], SUMMARY_NOTE_CHARS)
		var measured = moves.get(entry["action"], {})
		if measured.has("frames") or measured.has("damage"):
			entry["frames"] = Introspector.frames_text(measured)
		if measured.get("meter_bars", 0) > 0:
			entry["meter_bars"] = measured["meter_bars"]
		if detail == "full":
			for key in ["beats", "loses_to", "use_when", "range", "risk", "payload_hint"]:
				if notes.has(key):
					entry[key] = notes[key]
		result.append(entry)
	return result


func _update_panel(slot: String) -> void:
	var should_hide = bool(runtime.config.get_value("turns.hide_bot_panel", true)) and (
		controllers[slot] in IN_GAME_BOTS or (controllers[slot] == "mcp" and owners[slot] != ""))
	_set_panel_hidden(slot, should_hide)


func _set_panel_hidden(slot: String, hidden: bool) -> void:
	var buttons = _buttons(slot)
	if not Util.valid(buttons):
		return
	if hidden and buttons.visible:
		buttons.hide()
	elif not hidden and not buttons.visible and bool(Util.prop(buttons, "active", false)):
		buttons.show()


func _apply_match_options(target) -> void:
	var hp = Util.as_int(Util.prop(target, "match_data", {}).get("budok_starting_hp", 0))
	if hp <= 0:
		return
	for slot in SLOTS:
		var fighter = Observation.fighter_of(target, slot)
		if Util.valid(fighter):
			fighter.MAX_HEALTH = hp
			fighter.hp = hp
			if Util.has_prop(fighter, "trail_hp"):
				fighter.trail_hp = hp
	var tree = get_tree()
	var hud = tree.root.find_node("HudLayer", true, false) if tree != null else null
	if hud != null:
		for bar_name in ["P1HealthBar", "P2HealthBar", "P1HealthBarTrail", "P2HealthBarTrail",
				"P1GhostHealthBar", "P2GhostHealthBar", "P1GhostHealthBarTrail", "P2GhostHealthBarTrail"]:
			var bar = hud.find_node(bar_name, true, false)
			if bar != null and Util.has_prop(bar, "max_value"):
				bar.max_value = hp
				bar.value = hp


func _online() -> bool:
	var network = Util.autoload("Network")
	if bool(Util.prop(network, "multiplayer_active", false)):
		return true
	var lobby = Util.autoload("SteamLobby")
	return Util.as_int(Util.prop(lobby, "LOBBY_ID", 0)) != 0 or bool(Util.prop(lobby, "SPECTATING", false))


func _valid_controller(value) -> String:
	var name = str(value)
	return name if name in CONTROLLERS else "human"

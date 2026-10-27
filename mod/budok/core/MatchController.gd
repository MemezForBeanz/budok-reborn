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
const CONTROLLERS := ["human", "mcp", "ai"]
const SLOTS := ["p1", "p2"]
const MATCH_LOG_DIR := "user://budok/matches"

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
var _starting := false
var _buttons_cache := {}


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
	if turns[slot] != null and controller == "ai":
		emit_signal("turn_opened", slot, turns[slot]["token"])
	return {"ok": true, "controllers": controllers.duplicate()}


func set_next_match_controllers(value: Dictionary) -> void:
	_next_controllers = value.duplicate()


# Called right before a scripted match start so waiters do not see the
# previous match's result while the new game is still being set up.
func prepare_new_match() -> void:
	last_result = null
	_starting = true


func claim(slot: String, session_id: String) -> Dictionary:
	if not (slot in SLOTS):
		return {"ok": false, "error": "slot must be p1 or p2"}
	if owners[slot] != "" and owners[slot] != session_id:
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


# Everything a decision-maker needs for one open turn.
func turn_view(slot: String, detail: String = "summary") -> Dictionary:
	var turn = turns.get(slot)
	if turn == null:
		return {}
	var obs = Observation.build(game, slot, _infos(), history, detail)
	var view = {
		"turn_token": turn["token"],
		"slot": slot,
		"tick": turn["tick"],
		"situation": Observation.situation(obs),
		"observation": obs,
		"legal_actions": _annotated_actions(slot, turn["catalog"]["actions"], detail),
		"extras": turn["catalog"]["extras"],
	}
	var opponent_turn = turns.get(Observation.other(slot))
	if detail == "full" and opponent_turn != null:
		view["opponent_options"] = _annotated_actions(Observation.other(slot), opponent_turn["catalog"]["actions"], "summary")
	return view


func observation(slot: String, detail: String) -> Dictionary:
	if game == null:
		return {}
	return Observation.build(game, slot, _infos(), history, detail)


func submit(token: String, action: String, data, extra, source: String) -> Dictionary:
	var turn = turn_for_token(token)
	if turn == null:
		return {"ok": false, "error": "stale_turn", "message": "turn token is not open (already decided, timed out or the match moved on); call wait_for_turn"}
	var slot = turn["slot"]
	var buttons = _buttons(slot)
	var fighter = Observation.fighter_of(game, slot)
	if not ActionCatalog.is_awaiting(buttons, fighter):
		return {"ok": false, "error": "stale_turn", "message": "the game is no longer waiting on %s" % slot}
	var resolved = ActionCatalog.resolve(buttons, fighter, turn["catalog"], action, data, extra if extra is Dictionary else {})
	if not resolved["ok"]:
		return {"ok": false, "error": "invalid_action", "message": resolved["error"]}
	turn["applied"] = {"action": action, "data": resolved["data"], "extra": resolved["extra"], "source": source}
	decisions.append({"tick": turn["tick"], "slot": slot, "action": action, "data": Util.json_safe(resolved["data"]),
		"source": source, "think_ms": Util.now_ms() - turn["opened_ms"]})
	ActionCatalog.submit(buttons, action, resolved["data"], resolved["extra"])
	return {"ok": true, "applied": {"action": action, "data": Util.json_safe(resolved["data"]), "extra": Util.json_safe(resolved["extra"])}}


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


# Coroutine: after a submit, waits for the turn to resolve and reports what
# happened (opponent's revealed move, damage).
func wait_outcome(_slot: String, timeout_s: float) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var start_entries = history.size()
	var deadline = Util.now_ms() + int(timeout_s * 1000.0)
	while Util.now_ms() < deadline:
		if last_result != null:
			return {"status": "match_over", "result": last_result}
		if history.size() > start_entries:
			return {"status": "resolved", "turn": history[history.size() - 1]}
		yield(get_tree().create_timer(0.1), "timeout")
	return {"status": "pending", "message": "turn not resolved yet (opponent still choosing)"}


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
	var other = Observation.other(slot)
	var other_turn = turns.get(other)
	var choosing = [slot]
	if other_turn != null or _was_choosing(other):
		choosing.append(other)
	if theirs is Dictionary and theirs.has("action"):
		if not (other in choosing):
			yield(get_tree(), "idle_frame")
			return {"ok": false, "error": "the opponent is mid-move and is not choosing this turn; omit opponent_action"}
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
	var max_ticks = int(clamp(ticks if ticks > 0 else int(runtime.config.get_value("simulation.max_ticks", 120)), 10, 300))
	var result = yield(runtime.simulator.run(game, actions, choosing, max_ticks, slot), "completed")
	return result


func infos() -> Dictionary:
	return _infos()


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
		if not awaiting:
			_close_turn(slot, "applied" if turn.has("applied") else "resolved_elsewhere")
		else:
			_check_timeout(slot, turn)
		return
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
	_update_panel(slot)
	var bot_controlled = controllers[slot] == "ai" or (controllers[slot] == "mcp" and owners[slot] != "")
	if bot_controlled and _is_forced(catalog, fighter):
		submit(turn["token"], "Continue", null, {}, "auto_forced")
		return
	emit_signal("turn_opened", slot, turn["token"])


func _close_turn(slot: String, how: String) -> void:
	var turn = turns[slot]
	turns[slot] = null
	_awaiting_frames[slot] = 0
	if turn != null:
		emit_signal("turn_closed", slot, turn["token"], how)


func _check_timeout(slot: String, turn: Dictionary) -> void:
	if turn.has("applied"):
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
# move is only revealed after it has resolved.
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
		if history.size() > 0:
			var prev = history[history.size() - 1]
			for slot in SLOTS:
				entry[slot]["damage_taken"] = int(max(0, prev[slot]["hp"] - entry[slot]["hp"]))
		history.append(entry)
		var limit = int(runtime.config.get_value("turns.history_length", 12)) * 4
		if history.size() > limit:
			history = history.slice(history.size() - limit, history.size() - 1)
	_last_decision_tick = tick


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
			entry["notes"] = notes["summary"]
		var measured = moves.get(entry["action"], {})
		if measured.has("frames"):
			var frames = measured["frames"]
			entry["frames"] = "startup %d, active %d, recovery %d, %d dmg%s" % [frames["startup"], frames["active"], frames["recovery"],
				frames["total_damage"], (", reach %d" % frames["reach"]) if frames.has("reach") else ""]
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
		controllers[slot] == "ai" or (controllers[slot] == "mcp" and owners[slot] != ""))
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

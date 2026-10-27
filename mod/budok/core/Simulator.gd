extends Node

# Runs "what if" previews on the real engine, the same way the game's own
# ghost preview does: instance a fresh Game, copy the live state into it,
# queue one action per player and step it tick by tick. Nothing from the live
# match is mutated and the opponent's real (hidden) choice is never read; the
# caller supplies an assumed opponent action, or none (they keep doing their
# current thing).

const Util = preload("res://budok/core/Util.gd")
const Observation = preload("res://budok/core/Observation.gd")
const GAME_SCENE := "res://Game.tscn"
const MAX_EVENTS := 40
const NEUTRAL_EXTRA := {"DI": {"x": 0, "y": 0}, "reverse": false, "feint": false, "prediction": -1}

var _busy := false
var _sandbox: Viewport = null


# actions: {"p1": {"action", "data", "extra"} or null, "p2": ...}
# choosing: slots that are picking a move this turn (from the live turn
# snapshot; copy_to does not carry the interruptable flags over reliably).
# Returns a result dictionary; always yields at least once (safe to yield on).
func run(game, actions: Dictionary, choosing: Array, max_ticks: int, viewer_slot: String) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var waited = 0
	while _busy and waited < 300:
		yield(get_tree(), "idle_frame")
		waited += 1
	if _busy:
		return {"ok": false, "error": "another simulation is still running"}
	if not Util.valid(game) or not bool(Util.prop(game, "game_started", false)):
		return {"ok": false, "error": "no match in progress"}
	var packed = load(GAME_SCENE)
	if packed == null:
		return {"ok": false, "error": "cannot load %s in this game build" % GAME_SCENE}
	_busy = true
	var sim = packed.instance()
	sim.is_ghost = true
	_viewport().add_child(sim)
	sim.set_physics_process(false)
	sim.set_process(false)
	if Util.has_prop(sim, "ghost_hidden"):
		sim.ghost_hidden = true
	sim.hide()
	sim.start_game(true, Util.prop(game, "match_data", {}))
	# Ghost games refuse to tick when the match disabled the preview.
	if Util.has_prop(sim, "prediction_enabled"):
		sim.prediction_enabled = true
	yield(get_tree(), "idle_frame")
	if not Util.valid(game) or not Util.valid(sim):
		_finish(sim)
		return {"ok": false, "error": "match ended during simulation setup"}
	game.copy_to(sim)
	var objs_map = Util.prop(sim, "objs_map", {})
	for key in objs_map:
		if Util.valid(objs_map[key]):
			objs_map[key].is_ghost = true
	for slot in ["p1", "p2"]:
		var fighter = sim.get_player(1 if slot == "p1" else 2)
		fighter.is_ghost = true
		# Only players who are choosing this turn get an action, exactly like
		# the live game; a busy player keeps executing their current move.
		if not (slot in choosing):
			continue
		var queued = actions.get(slot)
		if not (queued is Dictionary):
			queued = {"action": "Continue", "data": null, "extra": NEUTRAL_EXTRA.duplicate(true)}
		# on_action_selected clears the interruptable flags the same way a
		# real lock-in does; usability was validated by the caller.
		fighter.on_action_selected(queued["action"], queued.get("data"), queued.get("extra", NEUTRAL_EXTRA.duplicate(true)))
	var result = _step(sim, max_ticks, viewer_slot)
	_finish(sim)
	return result


func _step(sim, max_ticks: int, viewer: String) -> Dictionary:
	var me_id = 1 if viewer == "p1" else 2
	var fighters = {"me": sim.get_player(me_id), "opponent": sim.get_player(3 - me_id)}
	var start = {}
	var last_state = {}
	var ready_at = {"me": -1, "opponent": -1}
	for who in fighters:
		start[who] = _snapshot(fighters[who])
		last_state[who] = start[who]["state"]
	var events = []
	var hp_prev = {"me": start["me"]["hp"], "opponent": start["opponent"]["hp"]}
	var ticks = 0
	var turn_end = -1
	# Objects already on screen (by id) and their positions one tick ago, for
	# spawn events and measured speed.
	var positions = _object_positions(sim)
	var motion = {}
	while ticks < max_ticks:
		sim.simulate_one_tick()
		ticks += 1
		var now = _object_positions(sim)
		motion = {}
		for id in now:
			if positions.has(id):
				motion[id] = {"x": now[id]["x"] - positions[id]["x"], "y": now[id]["y"] - positions[id]["y"]}
			elif events.size() < MAX_EVENTS:
				var obj = instance_from_id(id)
				events.append({"tick": ticks, "event": "spawn", "object": Util.strip_trailing_digits(str(obj.name)),
					"owner": _owner_of(obj, fighters["me"]), "position": now[id]})
		positions = now
		for who in fighters:
			var f = fighters[who]
			var hp = Util.as_int(Util.prop(f, "hp", 0))
			if hp < hp_prev[who] and events.size() < MAX_EVENTS:
				events.append({"tick": ticks, "event": "damage", "target": who, "amount": hp_prev[who] - hp})
			hp_prev[who] = hp
			var state_name = str(Util.prop(Util.call_or(f, "current_state"), "state_name", "?"))
			if state_name != last_state[who] and events.size() < MAX_EVENTS:
				events.append({"tick": ticks, "event": "state", "who": who, "state": state_name})
				last_state[who] = state_name
			if ready_at[who] == -1 and (
				bool(Util.prop(f, "state_interruptable", false)) or bool(Util.prop(f, "state_hit_cancellable", false))
			):
				ready_at[who] = ticks
		if turn_end == -1 and (ready_at["me"] != -1 or ready_at["opponent"] != -1):
			turn_end = ticks
		if bool(Util.prop(sim, "game_finished", false)):
			events.append({"tick": ticks, "event": "game_over"})
			break
		# Keep stepping past the next decision point until both sides are
		# actionable so frame advantage can be measured.
		if ready_at["me"] != -1 and ready_at["opponent"] != -1:
			break
	var end = {"me": _snapshot(fighters["me"]), "opponent": _snapshot(fighters["opponent"])}
	var result = {
		"ok": true,
		"ticks_simulated": ticks,
		"damage_dealt": start["opponent"]["hp"] - end["opponent"]["hp"],
		"damage_taken": start["me"]["hp"] - end["me"]["hp"],
		"me": end["me"],
		"opponent": end["opponent"],
		"events": events,
		"actionable_tick": ready_at,
		"next_decision_tick": turn_end,
	}
	var objects = Observation.objects(sim, fighters["me"], motion)
	if not objects.empty():
		result["objects"] = objects
	# Hitlag freezes a fighter, so its move only starts once it runs out.
	var hitlag = {}
	for who in start:
		if start[who]["hitlag"] > 0:
			hitlag[who] = start[who]["hitlag"]
	if not hitlag.empty():
		result["in_hitlag"] = hitlag
	if ready_at["me"] != -1 and ready_at["opponent"] != -1:
		result["frame_advantage"] = ready_at["opponent"] - ready_at["me"]
	result["summary"] = _summary(result)
	return result


func _snapshot(f) -> Dictionary:
	return {
		"hp": Util.as_int(Util.prop(f, "hp", 0)),
		"position": Util.xy(Util.call_or(f, "get_pos", [], Vector2.ZERO)),
		"state": str(Util.prop(Util.call_or(f, "current_state"), "state_name", "?")),
		"combo_count": Util.as_int(Util.prop(f, "combo_count", 0)),
		"meter_bars": Util.as_int(Util.prop(f, "supers_available", 0)),
		"hitlag": Util.as_int(Util.prop(f, "hitlag_ticks", 0)),
	}


static func _object_positions(sim) -> Dictionary:
	var positions = {}
	var list = Util.prop(sim, "objects", [])
	for obj in list if list is Array else []:
		if Util.valid(obj) and not bool(Util.prop(obj, "disabled", false)):
			positions[obj.get_instance_id()] = Util.xy(Util.call_or(obj, "get_pos", [], Vector2.ZERO))
	return positions


static func _owner_of(obj, me) -> String:
	var creator = Util.prop(obj, "creator", null)
	if not Util.valid(creator):
		return ""
	return "mine" if creator == me else "opponent"


func _summary(r: Dictionary) -> String:
	var text = ""
	var hitlag = r.get("in_hitlag", {})
	if hitlag.has("me"):
		text += "You start in hitlag (%d ticks frozen), so your move begins after that. " % hitlag["me"]
	if hitlag.has("opponent"):
		text += "The opponent starts in hitlag (%d ticks). " % hitlag["opponent"]
	text += "After %d ticks: you dealt %d and took %d damage. You end in %s, opponent in %s." % [
		r["ticks_simulated"], r["damage_dealt"], r["damage_taken"], r["me"]["state"], r["opponent"]["state"]]
	if r.has("frame_advantage"):
		var adv = r["frame_advantage"]
		text += " Frame advantage: %s%d (%s)." % ["+" if adv >= 0 else "", adv, "you act first" if adv > 0 else ("even" if adv == 0 else "opponent acts first")]
	return text


# The preview game is a Node2D; keep it inside a never-rendered viewport so it
# can never draw over the real match.
func _viewport() -> Viewport:
	if not Util.valid(_sandbox):
		_sandbox = Viewport.new()
		_sandbox.size = Vector2(2, 2)
		_sandbox.render_target_update_mode = Viewport.UPDATE_DISABLED
		_sandbox.audio_listener_enable_2d = false
		add_child(_sandbox)
	return _sandbox


func _finish(sim) -> void:
	if Util.valid(sim):
		sim.queue_free()
	_busy = false

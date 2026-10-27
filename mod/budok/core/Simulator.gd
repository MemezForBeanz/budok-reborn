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
const DETECT_TYPE := 6
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
	var mine = actions.get(viewer_slot)
	var followups = mine.get("then", []).duplicate() if mine is Dictionary else []
	var result = _step(sim, max_ticks, viewer_slot, followups)
	_finish(sim)
	return result


func _step(sim, max_ticks: int, viewer: String, followups: Array) -> Dictionary:
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
	# Your later decision points inside the preview (two-step moves, or a free
	# turn while the opponent is still busy).
	var acted_again = []
	var reach = {"active_ticks": 0, "first_active": -1, "gap_x": 999999, "gap_y": 999999, "overlapped": false}
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
				events.append({"tick": ticks, "event": "spawn", "object": Observation.object_type(obj),
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
		_track_reach(fighters["me"], fighters["opponent"], ticks, reach)
		if turn_end == -1 and (ready_at["me"] != -1 or ready_at["opponent"] != -1):
			turn_end = ticks
		if ready_at["me"] == ticks:
			if followups.empty() and ready_at["opponent"] == -1:
				acted_again.append(ticks)
			if not followups.empty():
				var step = followups.pop_front()
				var state = Util.prop(Util.prop(fighters["me"], "state_machine", null), "states_map", {}).get(step["action"])
				if state != null and state.has_method("is_usable") and not state.is_usable():
					events.append({"tick": ticks, "event": "followup_not_usable", "action": step["action"]})
					followups.clear()
				else:
					fighters["me"].on_action_selected(step["action"], step.get("data"), step.get("extra"))
					events.append({"tick": ticks, "event": "followup", "action": step["action"]})
					ready_at["me"] = -1
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
	if not acted_again.empty():
		result["you_act_again_at"] = acted_again
	if reach["active_ticks"] > 0:
		result["your_hitboxes"] = {"active_ticks": reach["active_ticks"], "first_active": reach["first_active"],
			"overlapped_opponent": reach["overlapped"], "closest_gap": {"x": reach["gap_x"], "y": reach["gap_y"]}}
	result["summary"] = _summary(result)
	return result


# Where your active hitboxes were relative to the opponent's body, so a miss can
# be explained (out of reach, too high, or touching but not hitting).
static func _track_reach(me, opponent, tick: int, reach: Dictionary) -> void:
	var state = Util.call_or(me, "current_state")
	var hurtbox = Util.prop(opponent, "hurtbox", null)
	if not Util.valid(state) or not state.has_method("get_active_hitboxes") or not Util.valid(hurtbox) or not hurtbox.has_method("get_aabb"):
		return
	var body = hurtbox.get_aabb()
	var any = false
	for hitbox in state.get_active_hitboxes():
		if not hitbox.has_method("get_aabb") or Util.as_int(Util.prop(hitbox, "hitbox_type", 0)) == DETECT_TYPE:
			continue
		any = true
		var box = hitbox.get_aabb()
		var gap_x = int(max(0, max(box["x1"] - body["x2"], body["x1"] - box["x2"])))
		var gap_y = int(max(0, max(box["y1"] - body["y2"], body["y1"] - box["y2"])))
		if gap_x == 0 and gap_y == 0:
			reach["overlapped"] = true
		if gap_x + gap_y < reach["gap_x"] + reach["gap_y"]:
			reach["gap_x"] = gap_x
			reach["gap_y"] = gap_y
	if any:
		reach["active_ticks"] += 1
		if reach["first_active"] == -1:
			reach["first_active"] = tick


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
	if r.has("you_act_again_at"):
		text += " You get another decision at tick %d while the opponent is still busy (a follow-up or a free turn); after that this preview assumes you Continue. Pass then: [{action, data}] to preview a follow-up." % r["you_act_again_at"][0]
	var hitboxes = r.get("your_hitboxes", {})
	if not hitboxes.empty() and r["damage_dealt"] == 0:
		if hitboxes["overlapped_opponent"]:
			text += " Your hitboxes touched the opponent but did not damage them (blocked, parried, invulnerable or armored)."
		else:
			text += " Your hitboxes were active for %d ticks but missed by %d horizontally and %d vertically." % [
				hitboxes["active_ticks"], hitboxes["closest_gap"]["x"], hitboxes["closest_gap"]["y"]]
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

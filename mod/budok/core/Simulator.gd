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
# Restored by hand on reuse: the objects are copied again and objs_map is the
# dictionary every object shares (its size seeds each new object's RNG).
const KEEP_GAME_VARS := ["objects", "effects", "objs_map"]
const MAX_POOL := 8
# Objects and effects a reused preview keeps out of play (see reset) before it
# is replaced by a fresh one.
const MAX_PARKED := 256
# Characters whose previews may be reset and reused: the game's own. A mod's
# copy code, objects or native parts may not survive a second copy into the
# same preview, so theirs are always fresh copies, as the game's own ghost.
const VANILLA_PREFIX := "res://characters/"

var config = null
var _busy := false
var _sandbox: Viewport = null
# Previews ready for reuse while the live match waits on one decision point
# (it does not change until the turn resolves), and per preview what a reset
# puts back.
var _pool := []
var _pool_key := ""
var _bases := {}
# The frame budget's debt (see charge) and the previews waiting to be freed,
# one per frame ([game, parked nodes]).
var _debt_usec := 0
var _debt_frame := 0
var _doomed := []


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
	_busy = true
	var spawned = yield(spawn(game), "completed")
	if not spawned["ok"]:
		_busy = false
		return spawned
	var sim = spawned["game"]
	for slot in ["p1", "p2"]:
		var fighter = sim.get_player(1 if slot == "p1" else 2)
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
	discard(sim)
	_busy = false
	return result


# Coroutine: a hidden preview game holding a copy of the live match, ready to
# tick. Returns {"ok", "game"} or {"ok": false, "error"}; free it with discard().
# Several can exist at once (lookahead runs one per line). for_reuse: remember
# what reset() needs, so take() can hand it out again after give_back() (only
# for characters that may be reused). The work is spread over frames within
# the frame budget; `game` must not tick meanwhile (a decision point).
func spawn(game, for_reuse: bool = false) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var paced = _pace()
	if paced is GDScriptFunctionState:
		yield(paced, "completed")
	if not Util.valid(game) or not bool(Util.prop(game, "game_started", false)):
		return {"ok": false, "error": "no match in progress"}
	var packed = load(GAME_SCENE)
	if packed == null:
		return {"ok": false, "error": "cannot load %s in this game build" % GAME_SCENE}
	var key = _key(game)
	var started = OS.get_ticks_usec()
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
	charge(started)
	yield(get_tree(), "idle_frame")
	paced = _pace()
	if paced is GDScriptFunctionState:
		yield(paced, "completed")
	if not Util.valid(game) or not Util.valid(sim) or _key(game) != key:
		discard(sim)
		return {"ok": false, "error": "the match moved on during simulation setup"}
	var split = reusable(game)
	for_reuse = for_reuse and split
	var base = _before_copy(sim) if for_reuse else {}
	started = OS.get_ticks_usec()
	var rest = _copy_current(sim, game) if split else {}
	if not split:
		game.copy_to(sim)
	charge(started)
	# The other states, a frame's budget at a time.
	for id in rest:
		for name in rest[id]:
			if over_budget():
				paced = _pace()
				if paced is GDScriptFunctionState:
					yield(paced, "completed")
				if not Util.valid(game) or not Util.valid(sim) or _key(game) != key:
					discard(sim)
					return {"ok": false, "error": "the match moved on during simulation setup"}
			started = OS.get_ticks_usec()
			game.get_player(id).state_machine.states_map[name].copy_to(sim.get_player(id).state_machine.states_map[name])
			charge(started)
	_settle(sim, game)
	if for_reuse:
		_after_copy(sim, base)
	return {"ok": true, "game": sim}


# game.copy_to(sim) with only each fighter's states that the copy enters (the
# live current state and its stack, and the preview's own): copy_to copies
# every state in the target's map, which is most of its cost. Returns {id:
# [the other states' names]}, to copy one by one (ObjectState.copy_to, as
# copy_to does). Only for the game's own characters.
static func _copy_current(sim, game) -> Dictionary:
	var full = {}
	for id in [1, 2]:
		var machine = sim.get_player(id).state_machine
		var live = game.get_player(id).state_machine
		var keep = {str(live.state.name): true, str(machine.state.name): true}
		for state in live.states_stack + machine.states_stack:
			keep[str(state.name)] = true
		var some = {}
		for name in keep:
			if machine.states_map.has(name):
				some[name] = machine.states_map[name]
		full[id] = machine.states_map
		machine.states_map = some
	game.copy_to(sim)
	var rest = {}
	for id in [1, 2]:
		var machine = sim.get_player(id).state_machine
		var some = machine.states_map
		machine.states_map = full[id]
		rest[id] = []
		for name in full[id]:
			if not some.has(name) and game.get_player(id).state_machine.states_map.has(name):
				rest[id].append(name)
	return rest


# Whether previews of `game` (the live match or a preview) may be reset and
# reused, and copied in parts: both fighters are the game's own characters,
# and simulation.reuse_previews is on.
func reusable(game) -> bool:
	return vanilla(game) and (config == null or bool(config.get_value("simulation.reuse_previews", true)))


# Whether both fighters of `game` are the game's own characters.
static func vanilla(game) -> bool:
	for id in [1, 2]:
		if not str(Util.prop(Util.call_or(game, "get_player", [id]), "filename", "")).begins_with(VANILLA_PREFIX):
			return false
	return true


# A preview no one uses any more: it is freed, with what it kept aside, a
# part per frame from the next frame on (see _on_idle_frame).
func discard(sim) -> void:
	if not Util.valid(sim):
		return
	var base = _bases.get(sim.get_instance_id(), {})
	_bases.erase(sim.get_instance_id())
	_pool.erase(sim)
	for entry in _doomed:
		if entry[0] == sim:
			return
	_doomed.append([sim] + base.get("parked", []))


func _ready() -> void:
	# Connected before any run waits for a frame, so frees come first in it.
	get_tree().connect("idle_frame", self, "_on_idle_frame")


# Frees discarded previews a part per frame, at the start of a frame that has
# room: first the preview leaves the tree (nothing in it runs again) with what
# it kept aside, then each fighter, then the rest (each part 10-30 ms).
func _on_idle_frame() -> void:
	if _doomed.empty() or _debt() > _budget_usec() / 4:
		return
	var started = OS.get_ticks_usec()
	var entry = _doomed[0]
	var sim = entry[0]
	if Util.valid(sim) and sim.is_inside_tree():
		sim.get_parent().remove_child(sim)
		for node in entry.slice(1, entry.size() - 1) if entry.size() > 1 else []:
			if Util.valid(node):
				node.free()
	else:
		var part = null
		for id in [1, 2]:
			var fighter = Util.call_or(sim, "get_player", [id])
			if part == null and Util.valid(fighter):
				part = fighter
		if part != null:
			part.free()
		else:
			if Util.valid(sim):
				sim.free()
			_doomed.pop_front()
	charge(started)


# --- the frame budget ---
#
# All work on previews (making, resetting, ticking, freeing them) shares one
# budget per frame (ai.core.frame_budget_ms), so the game stays smooth while
# the bots think: what it costs is charged as a debt, and a budget's worth is
# paid back each frame. Runs wait while this frame's budget is spent; a heavy
# step (making a preview, tens of ms) waits until the debt is nearly paid, and
# then pauses the other runs for the frames it used.

# Charges the work done since started_usec (OS.get_ticks_usec()).
func charge(started_usec: int) -> void:
	_debt()
	_debt_usec += OS.get_ticks_usec() - started_usec


# Whether this frame's budget is spent: runs wait for the next frame.
func over_budget() -> bool:
	return _debt() >= _budget_usec()


# Coroutine-like: before a heavy step, waits frame by frame until the debt is
# nearly paid and no discarded preview is left to free. Yields only when it
# waits.
func _pace():
	while _debt() > _budget_usec() / 4 or not _doomed.empty():
		yield(get_tree(), "idle_frame")


# What is still to pay back, after a budget per frame passed.
func _debt() -> int:
	var frame = Engine.get_idle_frames()
	if frame != _debt_frame:
		_debt_usec = int(max(0, _debt_usec - (frame - _debt_frame) * _budget_usec()))
		_debt_frame = frame
	return _debt_usec


func _budget_usec() -> int:
	var ms = config.get_value("ai.core.frame_budget_ms", 12) if config != null else 12
	return int(clamp(float(ms), 1.0, 100.0) * 1000.0)


# --- reusable previews ---
#
# A fresh copy (spawn) costs tens of ms, most of it copying all ~120 states of
# each fighter, and as much again to free. A preview that played a line is put
# back by restoring only what a line changes: the game's and the fighters'
# variables as they were right after the first copy, the objects, and the
# states the line entered (copied from the live match again). Checked against
# fresh copies over many lines: same results tick for tick. Only for the
# game's own characters (reusable()).

# Coroutine: a preview of the live match at its current decision point, used
# before when one is free. Returns {"ok", "game"} or {"ok": false, "error"};
# hand it back with give_back().
func take(game) -> Dictionary:
	yield(get_tree(), "idle_frame")
	if not Util.valid(game):
		return {"ok": false, "error": "no match in progress"}
	var key = _key(game)
	if key != _pool_key:
		release_pool()
		_pool_key = key
	while not _pool.empty():
		var sim = _pool.pop_back()
		if reset(sim, game):
			return {"ok": true, "game": sim}
		discard(sim)
	var spawned = yield(spawn(game, true), "completed")
	if spawned["ok"] and _bases.has(spawned["game"].get_instance_id()):
		_bases[spawned["game"].get_instance_id()]["key"] = key
	return spawned


# Coroutine: a reusable copy of `source`, a preview standing at a decision
# point; reset(copy, source) puts it back to that point, as long as source
# does not tick meanwhile. Free it with discard(). Returns {"ok", "game"} or
# {"ok": false, "error"}; refused for characters whose previews are not
# reused (a copy used once does not pay off).
func fork(source) -> Dictionary:
	if not Util.valid(source) or not reusable(source):
		yield(get_tree(), "idle_frame")
		return {"ok": false, "error": "previews of these characters are not reused"}
	var spawned = yield(spawn(source, true), "completed")
	if spawned["ok"]:
		_bases[spawned["game"].get_instance_id()]["key"] = _key(source)
	return spawned


# What a reusable preview was copied from: the game and its tick.
static func _key(game) -> String:
	return "%d:%d" % [game.get_instance_id(), Util.as_int(Util.prop(game, "current_tick", 0))]


# A preview from take(), for the next take() at the same decision point.
func give_back(sim) -> void:
	if not Util.valid(sim):
		return
	if _bases.get(sim.get_instance_id(), {}).get("key", "") == _pool_key and _pool.size() < MAX_POOL and not (sim in _pool):
		_pool.append(sim)
	else:
		discard(sim)


func release_pool() -> void:
	for sim in _pool.duplicate():
		discard(sim)
	_pool.clear()
	_pool_key = ""


func _before_copy(sim) -> Dictionary:
	var base = {"objs_map": Util.prop(sim, "objs_map", {}).duplicate(), "stacks": {}, "states": {}}
	for id in [1, 2]:
		var machine = sim.get_player(id).state_machine
		var names = []
		for state in machine.states_stack:
			names.append(str(state.name))
		base["stacks"][id] = names
		base["states"][id] = str(machine.state.name)
	return base


func _after_copy(sim, base: Dictionary) -> void:
	base["game"] = _variables(sim)
	base["fighters"] = {}
	base["touched"] = {}
	base["parked"] = []
	for id in [1, 2]:
		var fighter = sim.get_player(id)
		base["fighters"][id] = _variables(fighter)
		var touched = {str(fighter.state_machine.state.name): true}
		base["touched"][id] = touched
		fighter.state_machine.connect("state_changed", self, "_on_state_changed", [touched])
	_bases[sim.get_instance_id()] = base


# Every state a preview fighter enters, by name (the stack holds the states
# passed through on the way, too).
func _on_state_changed(stack, touched: Dictionary) -> void:
	for state in stack:
		if Util.valid(state):
			touched[str(state.name)] = true


# Puts a preview from take() (or fork()) back to a copy of the game it came
# from, right away (no frame passes). False when that cannot be done or did
# not work out: the caller then discards it and takes another.
func reset(sim, game) -> bool:
	if not Util.valid(sim) or not Util.valid(game) or not reusable(game):
		return false
	var base = _bases.get(sim.get_instance_id())
	if base == null or base.get("key", "") != _key(game):
		return false
	# Game.copy_to frees the target's objects (the game only ever copies into a
	# fresh one). Here they may still be pointed at from inside the preview (a
	# fighter, its native physics body, a state's effect), so they leave play
	# instead and are freed with the preview itself (discard).
	var parked = base["parked"]
	if parked.size() + sim.objects.size() + sim.effects.size() > MAX_PARKED:
		return false
	for list in [sim.effects, sim.objects]:
		for node in list.duplicate():
			if Util.valid(node):
				if node.get_parent() != null:
					node.get_parent().remove_child(node)
				parked.append(node)
		list.clear()
	_restore(sim, base["game"], KEEP_GAME_VARS)
	sim.objs_map.clear()
	for key in base["objs_map"]:
		sim.objs_map[key] = base["objs_map"][key]
	var full_maps = {}
	for id in [1, 2]:
		var fighter = sim.get_player(id)
		var live = game.get_player(id)
		_restore(fighter, base["fighters"][id], ["objs_map"])
		for hitbox in fighter.hitboxes:
			if hitbox.active:
				hitbox.deactivate()
		var machine = fighter.state_machine
		machine.queued_states = []
		machine.queued_data = []
		var stack = []
		for name in base["stacks"][id]:
			stack.append(machine.states_map[name])
		machine.states_stack = stack
		machine.state = machine.states_map[base["states"][id]]
		# copy_to copies every state in the target's map: hand it just the ones
		# that can differ from the live match, then put the full map back.
		var keep = base["touched"][id]
		keep[base["states"][id]] = true
		keep[str(live.state_machine.state.name)] = true
		for state in live.state_machine.states_stack:
			keep[str(state.name)] = true
		var some = {}
		for name in keep:
			if machine.states_map.has(name):
				some[name] = machine.states_map[name]
		full_maps[id] = machine.states_map
		machine.states_map = some
	game.copy_to(sim)
	var same = true
	for id in [1, 2]:
		var machine = sim.get_player(id).state_machine
		machine.states_map = full_maps[id]
		same = same and str(machine.state.name) == str(game.get_player(id).state_machine.state.name)
		base["touched"][id].clear()
		base["touched"][id][str(machine.state.name)] = true
	_settle(sim, game)
	return same


# Script variables, with their own copies of arrays and dictionaries.
static func _variables(obj) -> Dictionary:
	var out = {}
	for property in obj.get_property_list():
		if property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var value = obj.get(property["name"])
			out[property["name"]] = value.duplicate(true) if value is Array or value is Dictionary else value
	return out


static func _restore(obj, values: Dictionary, skip: Array) -> void:
	for name in values:
		if not (name in skip):
			var value = values[name]
			obj.set(name, value.duplicate(true) if value is Array or value is Dictionary else value)


# After a copy from the live match: everything in the preview is a ghost, and
# the fighters' own variables are put back as the live match has them.
# copy_to re-enters each fighter's current state, and entering some states
# spends an air option or meter that the live match already spent. A copy of
# another preview (fork) also takes its tick count, which the fighters'
# clocks follow, and the turn flags its decision point set.
static func _settle(sim, game) -> void:
	_align_names(sim, game)
	_rename_hitboxes(sim, game)
	var objs_map = Util.prop(sim, "objs_map", {})
	for key in objs_map:
		if Util.valid(objs_map[key]):
			objs_map[key].is_ghost = true
	var from_preview = bool(Util.prop(game, "is_ghost", false))
	if from_preview:
		sim.current_tick = game.current_tick
	for id in [1, 2]:
		var fighter = sim.get_player(id)
		fighter.is_ghost = true
		var live = game.get_player(id)
		for name in Util.prop(live, "state_variables", []):
			var value = live.get(name)
			fighter.set(name, value.duplicate(true) if value is Array or value is Dictionary else value)
		if from_preview:
			fighter.busy_interrupt = live.busy_interrupt


# Objects are found by name (objs_map: "P1", "P2", then "3", "4", ... by
# spawn count), and copy_to names the objects it makes by the copy's own
# count, while each copy keeps its source's name. Once the source has freed
# an object the two disagree, and a fighter that tracks its projectile by
# name (Ninja's grappling hook) finds another object. Rebuild the copy's map
# with the source's names, the same size (each new object's RNG seed comes
# from it), in place: every object shares it.
static func _align_names(sim, game) -> void:
	var source = Util.prop(game, "objs_map", null)
	var map = Util.prop(sim, "objs_map", null)
	if not (source is Dictionary and map is Dictionary):
		return
	var by_name = {"P1": sim.get_player(1), "P2": sim.get_player(2)}
	for obj in sim.objects:
		if Util.valid(obj):
			by_name[str(obj.obj_name)] = obj
	map.clear()
	for key in source:
		map[key] = by_name.get(str(key))


# An object copy is named by the copy's count when it is made (its hitboxes
# too: "3_HB_0"), then takes its source's name ("4"), so its states looked for
# hitboxes named for the source and did not copy their state ("Node not
# found"). Name the hitboxes for the object's name and copy that state again.
static func _rename_hitboxes(sim, game) -> void:
	var sources = {}
	for obj in Util.prop(game, "objects", []):
		if Util.valid(obj):
			sources[str(obj.obj_name)] = obj
	for obj in sim.objects:
		if not Util.valid(obj) or not obj.has_method("setup_hitbox_names") or obj.hitboxes.empty() or str(obj.obj_name) == "":
			continue
		if str(obj.hitboxes[0].name).begins_with(str(obj.obj_name) + "_HB_"):
			continue
		obj.setup_hitbox_names()
		var source = sources.get(str(obj.obj_name))
		if source == null:
			continue
		var pos = obj.get_pos()
		for name in source.state_machine.states_map:
			var mine = obj.state_machine.states_map.get(name)
			if mine == null:
				continue
			for hitbox in source.state_machine.states_map[name].get_children():
				if hitbox in source.hitboxes and mine.has_node(str(hitbox.name)):
					var copy = mine.get_node(str(hitbox.name))
					hitbox.copy_to(copy)
					copy.update_position(pos.x, pos.y)


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

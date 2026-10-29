extends Node

# Plays the match ahead on the real engine, in hidden preview games copied
# from the live match (Simulator.take; a used preview is reset instead of
# copied again). Three kinds of run:
#   - sweep(): the next exchange (up to the next decision point) for every
#     pair of your candidates and the opponent's replies, all on one preview;
#   - run_line(): one root pair, then both fighters' moves at each decision
#     point from a policy (the decision core asks its models), until `depth`
#     decision points with a real choice have passed (a combo in progress
#     gets a few more), someone is KO'd or time runs out;
#   - play_path(): a given sequence of both fighters' moves (the combo
#     solver, core/ComboSolver.gd, searches with it).
# All runs share a per-frame tick budget, so the game stays responsive, and
# only wait for the next frame when it is spent.
#
# An option is one concrete move: {"label", "action", "input", "di",
# "reverse", "description"}; input is what submit_action takes as data (null
# = default), reverse flips the fighter to face away from the opponent for
# the move (the panel's Reverse button), which also turns its aims around.

const Util = preload("res://budok/core/Util.gd")
const PayloadSpec = preload("res://budok/core/PayloadSpec.gd")
const SimTurns = preload("res://budok/core/SimTurns.gd")
const Observation = preload("res://budok/core/Observation.gd")
const NEUTRAL_EXTRA := {"DI": {"x": 0, "y": 0}, "reverse": false, "feint": false, "prediction": -1}
# DI tried when being hit: the four main directions, then the diagonals, in
# screen degrees with toward the opponent = 0 and up = -90.
const DI_VARIANTS := [["away", 180], ["toward", 0], ["up", -90], ["down", 90], ["up-away", -135], ["up-toward", -45], ["down-away", 135],
	["down-toward", 45]]
const MAX_DEPTH := 30
# Extra turns a line may play past its depth while a combo is in progress.
const COMBO_GRACE := 4

var runtime = null
var ticks_total := 0
# Exchanges already played, per turn token (a second look at the same
# decision point only plays the pairs it has not seen): {token: {"pairs":
# {pair key: outcome}, "check"}}.
var _played := {}
var _spawning := false
var _frame := -1
var _spent_usec := 0


func setup(runtime_ref) -> void:
	runtime = runtime_ref


# What every run of one turn shares.
func context(slot: String, turn: Dictionary, max_options: int) -> Dictionary:
	var matches = runtime.matches
	var other = "p2" if slot == "p1" else "p1"
	var other_turn = matches.turn_at(other, turn["tick"])
	var choosing = [slot]
	if other_turn != null or matches._was_choosing(other):
		choosing.append(other)
	var sides = {}
	for side in [slot, other]:
		var known = matches.move_specs(side)
		sides[side] = {"specs": known.get("specs", {}), "facing": known.get("facing", 1), "extras": known.get("extras", {}),
			"live_facing": Util.as_int(Util.call_or(_fighter(matches.game, side), "get_facing_int", [], 1), 1)}
	return {
		"slot": slot,
		"other": other,
		"tick": turn["tick"],
		"token": turn["token"],
		"choosing": choosing,
		"sides": sides,
		"catalogs": {slot: turn["catalog"], other: other_turn["catalog"] if other_turn != null else {}},
		"infos": matches.infos(),
		"max_options": max_options,
		"max_ticks": int(max(120, int(runtime.config.get_value("simulation.max_ticks", 120)))),
	}


# Options for `side` in the live match, from its turn's move list: each move
# as it stands first, then its variants. max_options <= 0: all of them.
# reversed: which reversed variants a move that can flip gets ("default":
# the move as it stands, reversed; "all": every variant; "": none).
func live_options(ctx: Dictionary, side: String, max_options: int = 0, reversed: String = "default") -> Array:
	if not (side in ctx["choosing"]):
		return [_option("Continue", "", null, null, "Hold: keep doing what you are doing")]
	var catalog = ctx["catalogs"].get(side, {})
	var fighter = _fighter(runtime.matches.game, side)
	if catalog.empty():
		return [_option("Continue", "", null, null, "Hold: keep doing what you are doing")]
	var legal = []
	for entry in catalog["actions"]:
		legal.append(entry["action"])
	var specs = ctx["sides"][side]["specs"].duplicate()
	for action in catalog["specs"]:
		specs[action] = catalog["specs"][action]
	return _options(fighter, legal, specs, ctx["sides"][side]["live_facing"], catalog["extras"].get("di") != null and SimTurns.is_hurt(fighter), max_options,
		reversed)


# Options for `side` at a decision point inside a preview game, at most
# max_options of them (-1: ctx's max_options; 0: all); reversed as
# live_options.
func sim_options(ctx: Dictionary, sim, side: String, busy: bool, max_options: int = -1, reversed: String = "default") -> Array:
	var fighter = _fighter(sim, side)
	var specs = ctx["sides"][side]["specs"]
	var legal = []
	for action in SimTurns.legal(fighter):
		# A move whose input spec is unknown could crash its script with null data.
		if action == "Continue" or specs.has(action):
			legal.append(action)
	var di = busy and SimTurns.is_hurt(fighter) and bool(Util.prop(fighter, "di_enabled", true))
	return _options(fighter, legal, specs, ctx["sides"][side]["facing"], di, ctx["max_options"] if max_options < 0 else max_options, reversed)


# Order: each move as it stands, then those that can flip reversed, then the
# other variants, then the other reversed variants (a reversed move's aims
# and directions are read from the side it faces after flipping).
func _options(fighter, legal: Array, specs: Dictionary, spec_facing: int, with_di: bool, max_options: int, reversed: String = "default") -> Array:
	var forward = _forward(fighter)
	var first = []
	var flipped = []
	var rest = []
	var flipped_rest = []
	for action in legal:
		var description = SimTurns.describe_state(fighter, action)
		if action == "Continue" and with_di:
			first.append(_option("Continue", "", null, null, description))
			for di in DI_VARIANTS:
				rest.append(_option("Continue", "DI " + di[0], null, SimTurns.aim_input(di[1], 1.0, forward), "Hold and steer your knockback " + di[0]))
			continue
		var spec = specs.get(action, {"kind": "none"})
		var variants = SimTurns.variants(spec, forward, spec_facing)
		for i in range(variants.size()):
			var option = _option(action, variants[i]["label"], variants[i]["input"], null, description)
			if i == 0:
				first.append(option)
			else:
				rest.append(option)
		if reversed != "" and action != "Continue" and can_flip(fighter, action):
			var turned = SimTurns.variants(spec, -forward, spec_facing)
			for i in range(turned.size() if reversed == "all" else 1):
				var label = "reversed" if turned[i]["label"] == "" else turned[i]["label"] + " reversed"
				(flipped if i == 0 else flipped_rest).append(_option(action, label, turned[i]["input"], null, description, true))
	var out = first + flipped + rest + flipped_rest
	return out.slice(0, max_options - 1) if max_options > 0 and out.size() > max_options else out


# Whether `action` can be played reversed (the panel's Reverse button is
# enabled for it): its state is reversible and allows flipping now.
static func can_flip(fighter, action: String) -> bool:
	var state = Util.prop(Util.prop(fighter, "state_machine", null), "states_map", {}).get(action)
	if not Util.valid(state) or not bool(Util.prop(state, "reversible", false)):
		return false
	return not state.has_method("flip_allowed") or bool(state.flip_allowed())


static func _option(action: String, variant: String, input, di, description: String, reverse: bool = false) -> Dictionary:
	return {"label": action if variant == "" else "%s %s" % [action, variant], "action": action, "input": input, "di": di, "reverse": reverse,
		"description": description}


static func _move_key(option: Dictionary) -> Array:
	var key = [option["action"], option.get("input"), option.get("di")]
	if option.get("reverse", false):
		key.append(true)
	return key


# What submit_action takes for an option: {"action", "data"?, "extra"?}.
static func action_of(option: Dictionary) -> Dictionary:
	var out = {"action": option["action"]}
	if option.get("input") != null:
		out["data"] = option["input"]
	var extra = extra_of(option)
	if not extra.empty():
		out["extra"] = extra
	return out


# The extras submit_action takes for an option: {"di"?, "reverse"?}.
static func extra_of(option: Dictionary) -> Dictionary:
	var extra = {}
	if option.get("di") is Dictionary:
		extra["di"] = option["di"]
	if option.get("reverse", false):
		extra["reverse"] = true
	return extra


# Coroutine: the next exchange for pairs of candidates and replies, one
# after the other on one preview. order: [[candidate index, reply index], ...],
# the most important first (the sweep stops at the deadline). Returns
# {"results": [candidate][reply] -> outcome (see _exchange) or null when not
# played, "played", "check" (how the first preview differed from the live
# match; empty when it matched)} and "error" when no preview could be made.
func sweep(ctx: Dictionary, candidates: Array, replies: Array, order: Array, deadline_ms: int) -> Dictionary:
	yield(get_tree(), "idle_frame")
	for token in _played.keys():
		if runtime.matches.turn_for_token(token) == null:
			_played.erase(token)
	if not _played.has(ctx["token"]):
		_played[ctx["token"]] = {"pairs": {}, "check": {}}
	var seen = _played[ctx["token"]]
	var results = []
	for _c in candidates:
		var row = []
		row.resize(replies.size())
		results.append(row)
	var out = {"results": results, "played": 0, "check": seen["check"]}
	var sim = null
	for pair in order:
		if Util.now_ms() >= deadline_ms or runtime.matches.turn_for_token(ctx["token"]) == null:
			break
		var key = Util.json_str([_move_key(candidates[pair[0]]), _move_key(replies[pair[1]])])
		if seen["pairs"].has(key):
			results[pair[0]][pair[1]] = seen["pairs"][key]
			out["played"] += 1
			continue
		if sim != null:
			sim = reuse(sim)
			if sim is GDScriptFunctionState:
				sim = yield(sim, "completed")
		if sim == null:
			var taken = yield(preview(), "completed")
			if not taken["ok"]:
				out["error"] = taken["error"]
				break
			sim = taken["game"]
			if seen["pairs"].empty():
				seen["check"] = _check(ctx, sim)
				out["check"] = seen["check"]
		var outcome = _exchange(ctx, sim, {ctx["slot"]: candidates[pair[0]], ctx["other"]: replies[pair[1]]})
		if outcome is GDScriptFunctionState:
			outcome = yield(outcome, "completed")
		if outcome["stop"] == "gone":
			sim = null
			continue
		results[pair[0]][pair[1]] = outcome
		seen["pairs"][key] = outcome
		out["played"] += 1
	if sim != null:
		runtime.simulator.give_back(sim)
	return out


# Coroutine: plays one line. root: {slot: option} for the slots choosing now.
# policy.choose(info) is a coroutine returning {slot: option} for the slots in
# info["options"] that have more than one option, or {"error"} to stop the
# line. Only decision points where someone has a real choice count toward
# depth, and a line that reaches its depth while one fighter can only DI,
# burst or wait (a combo or a punish in progress) plays up to COMBO_GRACE
# more turns. Returns, from ctx's slot's point of view, {"ok", "turns"
# (decision points with a choice, the root included), "dealt", "taken", "ko",
# "first" (the next exchange, as sweep), "steps": [{"you", "opponent"}] (each
# as _apply), "stop", "stop_detail"?, "unresolved" (it stopped before the
# position settled: cut short, or still mid-combo)} or {"ok": false,
# "error"}. stop: depth, ko, stuck, out_of_time, turn_over or model.
func run_line(ctx: Dictionary, root: Dictionary, depth: int, policy, deadline_ms: int) -> Dictionary:
	var taken = yield(preview(), "completed")
	if not taken["ok"]:
		return {"ok": false, "error": taken["error"]}
	var sim = taken["game"]
	var me = ctx["slot"]
	var them = ctx["other"]
	var start = {me: SimTurns.snapshot(_fighter(sim, me)), them: SimTurns.snapshot(_fighter(sim, them))}
	var first = _exchange(ctx, sim, root)
	if first is GDScriptFunctionState:
		first = yield(first, "completed")
	if first["stop"] == "gone":
		return {"ok": false, "error": "the preview game was freed"}
	var result = {"ok": true, "turns": 1, "first": first, "steps": [first["step"]]}
	var stop = first["stop"]
	var mid_combo = false
	depth = int(clamp(depth, 1, MAX_DEPTH))
	while stop == "decision":
		var busy = SimTurns.open_decision(sim)
		mid_combo = busy[me] != busy[them]
		if result["turns"] >= depth + (COMBO_GRACE if mid_combo else 0) or result["steps"].size() >= 2 * depth + COMBO_GRACE:
			stop = "depth"
		elif Util.now_ms() >= deadline_ms:
			stop = "out_of_time"
		elif runtime.matches.turn_for_token(ctx["token"]) == null:
			stop = "turn_over"
		if stop != "decision":
			break
		var options = {}
		var picks = {}
		for side in [me, them]:
			var list = sim_options(ctx, sim, side, busy[side])
			if list.size() == 1:
				picks[side] = list[0]
			else:
				options[side] = list
		if not options.empty():
			var chosen = yield(policy.choose({"ctx": ctx, "sim": sim, "options": options, "turn": result["turns"] + 1, "depth": depth,
				"deadline": deadline_ms}), "completed")
			if not Util.valid(sim):
				return {"ok": false, "error": "the preview game was freed"}
			if not (chosen is Dictionary) or chosen.empty() or chosen.has("error"):
				stop = "model"
				result["stop_detail"] = str(chosen.get("error", "no answer")) if chosen is Dictionary else "no answer"
				break
			for side in options:
				picks[side] = chosen[side] if chosen.get(side) is Dictionary else options[side][0]
			result["turns"] += 1
		result["steps"].append(_step(ctx, sim, picks))
		var reached = _tick_to_decision(sim, ctx["max_ticks"])
		if reached is GDScriptFunctionState:
			reached = yield(reached, "completed")
		stop = reached["reached"]
		if stop == "gone":
			return {"ok": false, "error": "the preview game was freed"}
	var outcome = _outcome(ctx, sim, start)
	for key in outcome:
		result[key] = outcome[key]
	result["stop"] = stop
	result["unresolved"] = not (stop in ["depth", "ko"]) or (stop == "depth" and mid_combo)
	runtime.simulator.give_back(sim)
	return result


# Plays `path` on a preview that holds the live match (fresh from preview()
# or reuse()): path[0] has the moves of the slots choosing now, each later
# entry the moves at the decision point after the one before ({side: option};
# a side without one holds). Yields (and must be awaited) only when the
# frame's tick budget runs out. Returns {"steps": [outcome as play_step],
# "node" (as node_at)}, or {"gone": true} when the preview was freed.
func play_path(ctx: Dictionary, sim, path: Array, with_options: bool = true):
	var start = start_of(ctx, sim)
	var steps = []
	for i in range(path.size()):
		if i > 0:
			SimTurns.open_decision(sim)
		var outcome = play_step(ctx, sim, path[i], start, i == 0)
		if outcome is GDScriptFunctionState:
			outcome = yield(outcome, "completed")
		if outcome == null:
			return {"gone": true}
		steps.append(outcome)
		if outcome["stop"] != "decision":
			break
	return {"steps": steps, "node": node_at(ctx, sim, steps.back()["stop"] if not steps.empty() else "decision", with_options)}


# Both fighters' hp and state in a preview, where play_step counts from.
func start_of(ctx: Dictionary, sim) -> Dictionary:
	return {ctx["slot"]: SimTurns.snapshot(_fighter(sim, ctx["slot"])), ctx["other"]: SimTurns.snapshot(_fighter(sim, ctx["other"]))}


# Plays picks ({side: option}) from the decision point a preview stands at, up
# to the next one: at_root, the live decision point (only the slots choosing
# there move); else a point inside the preview, where node_at (or
# SimTurns.open_decision) already ran. Yields (and must be awaited) only when
# the frame's tick budget runs out. Returns null when the preview was freed,
# else the outcome as _exchange with dealt and taken counted from `start` and
# "fighters": {side: fighter_view}.
func play_step(ctx: Dictionary, sim, picks: Dictionary, start: Dictionary, at_root: bool = false):
	var me = ctx["slot"]
	var them = ctx["other"]
	var step = {}
	if at_root:
		for side in ctx["choosing"]:
			step["you" if side == me else "opponent"] = _apply(ctx, sim, side, picks.get(side, _hold()), true)
	else:
		step = _step(ctx, sim, picks)
	var ticked = _tick_to_decision(sim, ctx["max_ticks"])
	if ticked is GDScriptFunctionState:
		ticked = yield(ticked, "completed")
	if ticked["reached"] == "gone":
		return null
	var outcome = _outcome(ctx, sim, start)
	outcome["ticks"] = ticked["ticks"]
	outcome["stop"] = ticked["reached"]
	outcome["step"] = step
	outcome["fighters"] = {me: fighter_view(sim, me), them: fighter_view(sim, them)}
	if ticked["reached"] == "decision":
		outcome["next_turn"] = _next_turn(ctx, sim)
	return outcome


# The position a preview stopped at: {"reached": decision, ko or stuck, and at
# a decision point "busy": {side: bool} and, with_options, "options": {side:
# [option]} (all of them)}. At a decision point it opens the turn there
# (SimTurns.open_decision), so call it once per point.
func node_at(ctx: Dictionary, sim, reached: String, with_options: bool = true) -> Dictionary:
	var node = {"reached": reached}
	if reached == "decision":
		node["busy"] = SimTurns.open_decision(sim)
		if with_options:
			node["options"] = {}
			for side in [ctx["slot"], ctx["other"]]:
				node["options"][side] = sim_options(ctx, sim, side, node["busy"][side], 0, "all")
	return node


# Locks in both fighters' picks at a decision point inside a preview (after
# SimTurns.open_decision). Returns {"you", "opponent"} as _apply.
func _step(ctx: Dictionary, sim, picks: Dictionary) -> Dictionary:
	var step = {}
	for side in [ctx["slot"], ctx["other"]]:
		step["you" if side == ctx["slot"] else "opponent"] = _apply(ctx, sim, side, picks.get(side, _hold()), false)
	return step


static func _hold() -> Dictionary:
	return _option("Continue", "", null, null, "")


# Who acts first at the decision point a preview has reached, for ctx's slot.
static func _next_turn(ctx: Dictionary, sim) -> String:
	var mine = bool(Util.prop(_fighter(sim, ctx["slot"]), "state_interruptable", false))
	var theirs = bool(Util.prop(_fighter(sim, ctx["other"]), "state_interruptable", false))
	return "even" if mine == theirs else ("you act first" if mine else "they act first")


# A fighter in a preview, as SimTurns.describe plus whether it is being hit,
# its combo count (hits it has landed in a row) and its distance to each wall.
static func fighter_view(game, side: String) -> Dictionary:
	var fighter = _fighter(game, side)
	var out = SimTurns.describe(fighter)
	out["hurt"] = SimTurns.is_hurt(fighter)
	out["combo"] = Util.as_int(Util.prop(fighter, "combo_count", 0))
	var walls = Observation.wall_distance(fighter, out["position"])
	if not walls.empty():
		out["walls"] = walls
	return out


# Who has the initiative at the live decision point: {"kind": "combo",
# "attacker", "defender"} when one fighter can act and the other can only DI,
# burst or wait out a move (being hit, or stuck in a move's recovery; right
# after a hit both are busy, and the one being hit defends), else {"kind":
# "open"}.
func situation(ctx: Dictionary) -> Dictionary:
	var busy = {}
	var hurt = {}
	for side in [ctx["slot"], ctx["other"]]:
		var fighter = _fighter(runtime.matches.game, side)
		busy[side] = bool(Util.prop(fighter, "busy_interrupt", false)) or not (side in ctx["choosing"])
		hurt[side] = SimTurns.is_hurt(fighter)
	var defender = ""
	for side in busy:
		var other = ctx["other"] if side == ctx["slot"] else ctx["slot"]
		if busy[side] and (not busy[other] or (hurt[side] and not hurt[other])):
			defender = side
	if defender == "":
		return {"kind": "open"}
	return {"kind": "combo", "attacker": ctx["other"] if defender == ctx["slot"] else ctx["slot"], "defender": defender}


# Plays root (the moves of the slots choosing now) up to the next decision
# point. Yields (and must be awaited) only when the frame's tick budget runs
# out. Returns {"dealt", "taken", "ko", "states", "next_turn"?, "ticks",
# "stop": decision, ko, stuck or gone, "step": {"you"?, "opponent"?},
# "fighters"} (see play_step).
func _exchange(ctx: Dictionary, sim, root: Dictionary):
	var outcome = play_step(ctx, sim, root, start_of(ctx, sim), true)
	if outcome is GDScriptFunctionState:
		outcome = yield(outcome, "completed")
	return outcome if outcome != null else {"stop": "gone"}


# Locks in `option` for `side` in a preview. at_root: the live decision point,
# whose move list (and its specs) is exact. Returns what was played: {"move",
# "action" (as submit_action takes it), "engine_data" (the data the move got,
# after the same checks and clamps as a submit), "note"?}.
func _apply(ctx: Dictionary, sim, side: String, option: Dictionary, at_root: bool) -> Dictionary:
	var fighter = _fighter(sim, side)
	var spec = ctx["sides"][side]["specs"].get(option["action"], {"kind": "none"})
	var facing = ctx["sides"][side]["facing"]
	var live = ctx["catalogs"].get(side, {}).get("specs", {})
	if at_root and live.has(option["action"]):
		spec = live[option["action"]]
		facing = ctx["sides"][side]["live_facing"]
	var data = null
	# A reversed move faces away from the opponent, and its aim limits turn with it.
	var reverse = bool(option.get("reverse", false))
	var coerced = PayloadSpec.coerce(SimTurns.facing_spec(spec, _forward(fighter) * (-1 if reverse else 1), facing), option["input"], null)
	if coerced["ok"]:
		data = coerced["value"]
	var extra = NEUTRAL_EXTRA.duplicate(true)
	for key in ctx["sides"][side]["extras"]:
		extra[key] = ctx["sides"][side]["extras"][key]
	if option.get("di") is Dictionary:
		extra["DI"] = option["di"]
	extra["reverse"] = reverse
	fighter.on_action_selected(option["action"], data, extra)
	var played = {"move": option["label"], "action": action_of(option), "engine_data": data}
	if not coerced["ok"]:
		played["note"] = "data rejected (%s), the move got none" % coerced["error"]
	elif coerced.has("note"):
		played["note"] = coerced["note"]
	return played


# Coroutine: a preview of the live match, taking turns with other runs (setting
# one up can take a few frames of work). Returns Simulator.take's result; hand
# the preview back with runtime.simulator.give_back().
func preview() -> Dictionary:
	yield(get_tree(), "idle_frame")
	while _spawning:
		yield(get_tree(), "idle_frame")
	_spawning = true
	var taken = yield(runtime.simulator.take(runtime.matches.game), "completed")
	_spawning = false
	return taken


# A preview that played something, put back to the game it was copied from
# (source: the live match by default, or the preview it was forked from); its
# cost counts toward the frame's budget. Yields (and must be awaited) only
# when the budget is spent. Returns the preview, or null when it could not be
# reset (it is freed then: take another).
func reuse(sim, source = null):
	var waited = _await_budget()
	if waited is GDScriptFunctionState:
		yield(waited, "completed")
	var started = OS.get_ticks_usec()
	var reset = runtime.simulator.reset(sim, source if source != null else runtime.matches.game)
	_spent_usec += OS.get_ticks_usec() - started
	if not reset:
		runtime.simulator.discard(sim)
		return null
	return sim


# Ticks until a decision point; returns {"reached": decision, ko, stuck (the
# tick limit) or gone (the preview was freed), "ticks"}. Yields (and must be
# awaited) only when the frame's tick budget runs out.
func _tick_to_decision(sim, max_ticks: int):
	var budget = _budget_usec()
	# The game's replay resimulation flag skips particles, afterimages and
	# sounds (deferred work no one sees in a preview) and nothing that plays out.
	var replays = Util.autoload("ReplayManager")
	var flag = Util.has_prop(replays, "resimulating")
	for ticks in range(max_ticks):
		while _spent_this_frame() >= budget:
			yield(get_tree(), "idle_frame")
		if not Util.valid(sim):
			return {"reached": "gone", "ticks": ticks}
		var started = OS.get_ticks_usec()
		var resimulating = replays.resimulating if flag else false
		if flag:
			replays.resimulating = true
		# tick() without show_state(): previews are never drawn.
		sim.tick()
		if flag:
			replays.resimulating = resimulating
		_spent_usec += OS.get_ticks_usec() - started
		ticks_total += 1
		# Read directly: this runs every tick.
		var p1 = sim.p1
		var p2 = sim.p2
		if p1.hp <= 0 or p2.hp <= 0:
			return {"reached": "ko", "ticks": ticks + 1}
		if p1.state_interruptable or p2.state_interruptable:
			return {"reached": "decision", "ticks": ticks + 1}
	return {"reached": "stuck", "ticks": max_ticks}


# Waits for the next frame when this one's tick budget is spent.
func _await_budget():
	while _spent_this_frame() >= _budget_usec():
		yield(get_tree(), "idle_frame")


func _budget_usec() -> int:
	return int(clamp(float(runtime.config.get_value("ai.core.frame_budget_ms", 12)), 1.0, 100.0) * 1000.0)


# Engine time all runs spent during this frame.
func _spent_this_frame() -> int:
	var frame = Engine.get_idle_frames()
	if frame != _frame:
		_frame = frame
		_spent_usec = 0
	return _spent_usec


func _outcome(ctx: Dictionary, sim, start: Dictionary) -> Dictionary:
	var me = SimTurns.snapshot(_fighter(sim, ctx["slot"]))
	var them = SimTurns.snapshot(_fighter(sim, ctx["other"]))
	var ko = ""
	if them["hp"] <= 0:
		ko = "opponent"
	elif me["hp"] <= 0:
		ko = "you"
	return {"dealt": start[ctx["other"]]["hp"] - them["hp"], "taken": start[ctx["slot"]]["hp"] - me["hp"], "ko": ko,
		"states": {"you": me["state"], "opponent": them["state"]}}


# The live match where every run starts, from ctx's slot's point of view.
func root_state(ctx: Dictionary) -> Dictionary:
	var game = runtime.matches.game
	var me = SimTurns.describe(_fighter(game, ctx["slot"]))
	var them = SimTurns.describe(_fighter(game, ctx["other"]))
	return {"tick": ctx["tick"], "you": me, "opponent": them,
		"distance": {"x": abs(them["position"]["x"] - me["position"]["x"]), "y": them["position"]["y"] - me["position"]["y"]}}


# How a fresh preview differs from the live match ({} when it matches): a
# difference here means the engine's copy itself is off, not the prediction.
func _check(ctx: Dictionary, sim) -> Dictionary:
	var out = {}
	for side in [ctx["slot"], ctx["other"]]:
		var live = SimTurns.describe(_fighter(runtime.matches.game, side))
		var copy = SimTurns.describe(_fighter(sim, side))
		for key in live:
			if Util.json_str(live[key]) != Util.json_str(copy[key]):
				out["%s %s" % ["you" if side == ctx["slot"] else "opponent", key]] = {"live": live[key], "preview": copy[key]}
	return out


static func _fighter(game, side: String):
	return Util.prop(game, "p1" if side == "p1" else "p2", null)


static func _forward(fighter) -> int:
	var dir = Util.as_int(Util.call_or(fighter, "get_opponent_dir", [], 0))
	return dir if dir != 0 else Util.as_int(Util.call_or(fighter, "get_facing_int", [], 1), 1)

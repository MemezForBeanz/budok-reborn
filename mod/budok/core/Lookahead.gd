extends Node

# Plays lines of a match ahead on the real engine. Each line is a hidden
# preview game copied from the live match: both fighters' moves at every
# decision point come from a policy (the decision player asks its model), until
# `depth` decision points have passed or someone is KO'd. Several lines run at
# once. They take turns creating their previews (one costs about two frames of
# work) and share a per-frame tick budget, so the game stays responsive.
#
# An option is one concrete move: {"label", "action", "input", "di",
# "description"}; input is what submit_action takes as data (null = default).

const Util = preload("res://budok/core/Util.gd")
const PayloadSpec = preload("res://budok/core/PayloadSpec.gd")
const SimTurns = preload("res://budok/core/SimTurns.gd")
const NEUTRAL_EXTRA := {"DI": {"x": 0, "y": 0}, "reverse": false, "feint": false, "prediction": -1}
const DI_VARIANTS := [["DI away", -1, 0], ["DI toward", 1, 0], ["DI up", 0, -1], ["DI down", 0, 1]]
const MAX_DEPTH := 30
const STEPS_SHOWN := 4

var runtime = null
var ticks_total := 0
var _spawning := false
var _frame := -1
var _spent_usec := 0


func setup(runtime_ref) -> void:
	runtime = runtime_ref


# What every line of one turn shares.
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


# Options for `side` in the live match, from its turn's move list.
func live_options(ctx: Dictionary, side: String) -> Array:
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
	return _options(fighter, legal, specs, ctx["sides"][side]["live_facing"], catalog["extras"].get("di") != null and SimTurns.is_hurt(fighter), ctx["max_options"])


# Options for `side` at a decision point inside a preview game.
func sim_options(ctx: Dictionary, sim, side: String, busy: bool) -> Array:
	var fighter = _fighter(sim, side)
	var specs = ctx["sides"][side]["specs"]
	var legal = []
	for action in SimTurns.legal(fighter):
		# A move whose input spec is unknown could crash its script with null data.
		if action == "Continue" or specs.has(action):
			legal.append(action)
	var di = busy and SimTurns.is_hurt(fighter) and bool(Util.prop(fighter, "di_enabled", true))
	return _options(fighter, legal, specs, ctx["sides"][side]["facing"], di, ctx["max_options"])


func _options(fighter, legal: Array, specs: Dictionary, spec_facing: int, with_di: bool, max_options: int) -> Array:
	var forward = _forward(fighter)
	var first = []
	var rest = []
	for action in legal:
		var description = SimTurns.describe_state(fighter, action)
		if action == "Continue" and with_di:
			first.append(_option("Continue", "", null, null, description))
			for di in DI_VARIANTS:
				rest.append(_option("Continue", di[0], null, {"x": di[1] * forward * PayloadSpec.XY_RANGE, "y": di[2] * PayloadSpec.XY_RANGE},
					"Hold and steer your knockback " + di[0].substr(3)))
			continue
		var variants = SimTurns.variants(specs.get(action, {"kind": "none"}), forward, spec_facing)
		for i in range(variants.size()):
			var option = _option(action, variants[i]["label"], variants[i]["input"], null, description)
			if i == 0:
				first.append(option)
			else:
				rest.append(option)
	var out = first.slice(0, max_options - 1) if first.size() > max_options else first
	for option in rest:
		if out.size() >= max_options:
			break
		out.append(option)
	return out


static func _option(action: String, variant: String, input, di, description: String) -> Dictionary:
	return {"label": action if variant == "" else "%s %s" % [action, variant], "action": action, "input": input, "di": di, "description": description}


# Coroutine: plays one line. root: {slot: option} for the slots choosing now.
# policy.choose(info) is a coroutine returning {slot: option} for the slots in
# info["options"] that have more than one option, or {} to stop the line.
# Returns {"ok", "turns", "dealt", "taken", "ko", "first", "moves"} from ctx's
# slot's point of view, or {"ok": false, "error"}.
func run_line(ctx: Dictionary, root: Dictionary, depth: int, policy, deadline_ms: int) -> Dictionary:
	yield(get_tree(), "idle_frame")
	while _spawning:
		yield(get_tree(), "idle_frame")
	_spawning = true
	var spawned = yield(runtime.simulator.spawn(runtime.matches.game), "completed")
	_spawning = false
	if not spawned["ok"]:
		return spawned
	var sim = spawned["game"]
	var me = ctx["slot"]
	var them = ctx["other"]
	var start = {me: SimTurns.snapshot(_fighter(sim, me)), them: SimTurns.snapshot(_fighter(sim, them))}
	var moves = {me: [], them: []}
	for side in ctx["choosing"]:
		_apply(ctx, sim, side, root.get(side, _option("Continue", "", null, null, "")), moves, true)
	var result = {"ok": true, "turns": 1}
	depth = int(clamp(depth, 1, MAX_DEPTH))
	while true:
		var reached = yield(_tick_to_decision(sim, ctx["max_ticks"]), "completed")
		if reached == "gone":
			return {"ok": false, "error": "the preview game was freed"}
		if not result.has("first"):
			result["first"] = _outcome(ctx, sim, start)
			if reached == "decision":
				var mine = bool(Util.prop(_fighter(sim, me), "state_interruptable", false))
				var theirs = bool(Util.prop(_fighter(sim, them), "state_interruptable", false))
				result["first"]["next_turn"] = "even" if mine == theirs else ("you act first" if mine else "they act first")
		if reached != "decision" or result["turns"] >= depth or Util.now_ms() >= deadline_ms or runtime.matches.turn_for_token(ctx["token"]) == null:
			break
		var busy = SimTurns.open_decision(sim)
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
			if not (chosen is Dictionary) or chosen.empty() or not Util.valid(sim):
				break
			for side in options:
				picks[side] = chosen[side] if chosen.get(side) is Dictionary else options[side][0]
		for side in [me, them]:
			_apply(ctx, sim, side, picks[side], moves, false)
		result["turns"] += 1
	if not Util.valid(sim):
		return {"ok": false, "error": "the preview game was freed"}
	var outcome = _outcome(ctx, sim, start)
	for key in outcome:
		result[key] = outcome[key]
	result["moves"] = {"you": moves[me].slice(0, STEPS_SHOWN - 1) if not moves[me].empty() else [],
		"opponent": moves[them].slice(0, STEPS_SHOWN - 1) if not moves[them].empty() else []}
	runtime.simulator.discard(sim)
	return result


# at_root: the live decision point, whose move list (and its specs) is exact.
func _apply(ctx: Dictionary, sim, side: String, option: Dictionary, moves: Dictionary, at_root: bool) -> void:
	var fighter = _fighter(sim, side)
	var spec = ctx["sides"][side]["specs"].get(option["action"], {"kind": "none"})
	var facing = ctx["sides"][side]["facing"]
	var live = ctx["catalogs"].get(side, {}).get("specs", {})
	if at_root and live.has(option["action"]):
		spec = live[option["action"]]
		facing = ctx["sides"][side]["live_facing"]
	var data = null
	var coerced = PayloadSpec.coerce(SimTurns.facing_spec(spec, _forward(fighter), facing), option["input"], null)
	if coerced["ok"]:
		data = coerced["value"]
	var extra = NEUTRAL_EXTRA.duplicate(true)
	for key in ctx["sides"][side]["extras"]:
		extra[key] = ctx["sides"][side]["extras"][key]
	if option.get("di") is Dictionary:
		extra["DI"] = option["di"]
	fighter.on_action_selected(option["action"], data, extra)
	moves[side].append(option["label"])


# Coroutine: ticks until a decision point ("decision"), a KO ("ko"), the tick
# limit ("stuck") or the preview being freed ("gone").
func _tick_to_decision(sim, max_ticks: int) -> String:
	yield(get_tree(), "idle_frame")
	var budget_usec = int(clamp(float(runtime.config.get_value("ai.core.frame_budget_ms", 8)), 1.0, 100.0) * 1000.0)
	for ticks in range(max_ticks):
		while _spent_this_frame() >= budget_usec:
			yield(get_tree(), "idle_frame")
		if not Util.valid(sim):
			return "gone"
		var started = OS.get_ticks_usec()
		# tick() without show_state(): previews are never drawn.
		sim.tick()
		_spent_usec += OS.get_ticks_usec() - started
		ticks_total += 1
		if Util.as_int(Util.prop(sim.p1, "hp", 1)) <= 0 or Util.as_int(Util.prop(sim.p2, "hp", 1)) <= 0:
			return "ko"
		if SimTurns.at_decision(sim):
			return "decision"
	return "stuck"


# Engine time all lines spent ticking during this frame.
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


static func _fighter(game, side: String):
	return Util.prop(game, "p1" if side == "p1" else "p2", null)


static func _forward(fighter) -> int:
	var dir = Util.as_int(Util.call_or(fighter, "get_opponent_dir", [], 0))
	return dir if dir != 0 else Util.as_int(Util.call_or(fighter, "get_facing_int", [], 1), 1)

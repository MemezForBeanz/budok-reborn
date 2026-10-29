extends Reference

# The combo solver: when one fighter can act and the other can only DI, burst
# or wait out a move (being hit, or stuck in a move's recovery), it searches
# the attacker's best continuation on the real engine. No decision model is
# asked: every candidate is played.
#
# The attacker commits before seeing the defender's DI, and a route is judged
# by what it keeps against every DI policy (no DI, and each of the eight
# directions, held for the whole combo):
#   1. every first move (each aim and variant; defensive moves are left out
#      while anything else is legal) is played against no DI; the best
#      FIRST_KEEP, plus the seeds (moves the caller named, a remembered
#      route's next move), start a route each;
#   2. with SEARCH_SHARE of the time, a beam search grows those routes
#      against no DI, WIDTH at a time, one step per round, until the combo
#      ends (the defender can act again), someone is KO'd or a route has
#      MAX_STEPS steps. Each step plays one variant of every move first, then
#      every variant of the best FAMILIES moves and finer aims around the best
#      REFINE aimed ones. Routes still going rank by damage so far plus
#      CONTINUE_BONUS, so a setup move (a dash into a launcher) is not dropped
#      for a hit that ends the combo; once grown, a route is worth its best
#      continuation instead;
#   3. the best VALIDATE routes are played again, the same moves, against
#      every other DI policy, until the combo ends or the route breaks (a move
#      that is not possible there). A route is worth its worst policy: robust
#      damage is what it keeps whatever the defender DIs. The attacker sees
#      the position before each move, so a live bot plays only the first move
#      and searches again from what really happened (DecisionCore keeps the
#      route to check how it went);
#   4. the defender's escapes (burst, counters) are played at each step of
#      the best route.
# Positions deep in a route are copied (Simulator.fork) to play many moves
# from them, instead of replaying the route from the live match for each.

const Util = preload("res://budok/core/Util.gd")
const SimTurns = preload("res://budok/core/SimTurns.gd")
const PayloadSpec = preload("res://budok/core/PayloadSpec.gd")
const Lookahead = preload("res://budok/core/Lookahead.gd")
const KO_VALUE := 1000.0
const MAX_STEPS := 24
const FIRST_KEEP := 6
const WIDTH := 3
const VALIDATE := 3
const FAMILIES := 2
const REFINE := 1
const AIM_STEP := 22.5
const SEARCH_SHARE := 0.7
# Moves to play from one position before copying it pays off over replaying
# the route to it for each.
const FORK_MIN := 6
const CONTINUE_BONUS := 50.0
# What the goals add to a route's value: ending where the defender acts first
# ("safe"), each unit the defender was carried toward the wall behind them
# ("corner"); and what spending costs, per goal: [meter bar, burst] (a burst
# spent to extend a combo always costs something).
const GOALS := ["damage", "safe", "corner", "save_resources"]
const SAFE_PENALTY := 150.0
const CORNER_WEIGHT := 0.25
const SPEND := {"damage": [0.0, 120.0], "safe": [0.0, 120.0], "corner": [0.0, 120.0], "save_resources": [60.0, 300.0]}

var runtime = null
var ctx := {}
var attacker := ""
var defender := ""
var goal := "damage"
var stats := {"exchanges": 0, "rounds": 0, "options": 0, "forks": 0}
var _deadline := 0
# The main preview, which replays routes from the live match, and the key of
# the route it stands at the end of ("" right after a reset).
var _sim = null
var _at := ""
var _dirty := false
var _memo := {}
var _start := {}
var _hp := {}
# [{"label", "option"}]: the defender's move at the live decision point for
# each DI policy, no DI first.
var _policies := []
var _root_options := {}
var _error := ""


func _init(runtime_ref) -> void:
	runtime = runtime_ref


# Coroutine. options: {"goal"?: one of GOALS, "seeds"?: [option] (attacker
# options at the live decision point to search whatever the first screen
# says)}. Returns {"ok", "attacker", "defender", "goal", "policies": [label],
# "policy_options": [the defender's option for each policy at the live
# decision point], "plans": [plan] (best first), "searched": {"exchanges", "rounds" (beam
# steps), "options" (first moves played), "forks", "stop": done or
# out_of_time, "ms"}} or {"ok": false, "error"}. plan: {"first": option,
# "route": {"path", "result"} (the best route found against no DI),
# "validated" (its moves were played against every policy; else branches
# only hold the first step), "value" (how the search ranks it: its worst
# branch), "mean", "damage": {"robust", "expected", "max"} (damage dealt over
# the branches), "taken" (the most the attacker took), "branches": [branch],
# "escapes": [{"step", "option", "result"}]}. branch: {"policy", "path":
# [{side: option}], "result" (play_path's), "status": open (still going: see
# "cut"), ended, ko or stuck, "end"? ("defender acts first" or "even"),
# "cut"?, "broke"? (a move of the route was not possible there), "dealt",
# "taken", "ko"}.
func solve(ctx_ref: Dictionary, attacker_side: String, deadline_ms: int, options: Dictionary = {}) -> Dictionary:
	var lookahead = runtime.lookahead
	yield(lookahead.get_tree(), "idle_frame")
	var started = Util.now_ms()
	ctx = ctx_ref
	attacker = attacker_side
	defender = ctx["other"] if attacker == ctx["slot"] else ctx["slot"]
	goal = str(options.get("goal", "damage")) if str(options.get("goal", "damage")) in GOALS else "damage"
	_deadline = deadline_ms
	var game = runtime.matches.game
	for side in [attacker, defender]:
		_start[side] = Lookahead.fighter_view(game, side)
	_hp = lookahead.start_of(ctx, game)
	_root_options = {attacker: lookahead.live_options(ctx, attacker), defender: lookahead.live_options(ctx, defender)}
	for option in _root_options[defender]:
		if option["action"] == "Continue":
			_policies.append({"label": "no DI" if option.get("di") == null else option["label"].trim_prefix("Continue "), "option": option})
	if _policies.empty():
		_policies.append({"label": "no DI", "option": Lookahead._hold()})
	# 1. first moves
	var root = {"path": [], "result": {"steps": [], "node": {"reached": "decision", "options": _root_options}}}
	var seeds = options.get("seeds", [])
	var screen = _search(root)
	if screen is GDScriptFunctionState:
		screen = yield(screen, "completed")
	stats["options"] = screen.size()
	var firsts = screen.slice(0, FIRST_KEEP - 1) if not screen.empty() else []
	for wanted in seeds:
		if _find(firsts, wanted) == null:
			var path = [{attacker: wanted, defender: _defense(_root_options[defender], _policies[0])}]
			var result = _eval(path)
			if result is GDScriptFunctionState:
				result = yield(result, "completed")
			if result != null:
				firsts.append({"option": wanted, "path": path, "result": result})
	var plans = []
	for item in firsts:
		var plan = {"id": plans.size(), "first": item["option"], "route": {"path": item["path"], "result": item["result"]}, "escapes": [],
			"validated": false, "seeded": _find(seeds, item["option"]) != null}
		# The routes not grown yet: a grown one is worth its best continuation, not its bonus.
		plan["leaves"] = {_key(item["path"]): plan["route"]}
		plan["branches"] = [_branch(_policies[0], item["path"], item["result"])]
		plans.append(plan)
	# 2. grow the routes against no DI
	var search_end = Util.now_ms() + int((_deadline - Util.now_ms()) * SEARCH_SHARE)
	var beam = []
	for plan in plans:
		if _going(plan["route"]["path"], plan["route"]["result"]):
			beam.append({"plan": plan["id"], "path": plan["route"]["path"], "result": plan["route"]["result"]})
	var stop = "done"
	while not beam.empty():
		if _out_of_time() or Util.now_ms() >= search_end:
			stop = "out_of_time"
			break
		var children = []
		for route in beam:
			if _out_of_time() or Util.now_ms() >= search_end:
				break
			var items = _search(route)
			if items is GDScriptFunctionState:
				items = yield(items, "completed")
			if items.empty():
				continue
			var plan = plans[route["plan"]]
			# A search cut short by time keeps the route itself in the running.
			if not _out_of_time():
				plan["leaves"].erase(_key(route["path"]))
			for item in items:
				children.append({"plan": route["plan"], "path": item["path"], "result": item["result"], "value": item["value"]})
				plan["leaves"][_key(item["path"])] = {"path": item["path"], "result": item["result"]}
			var best = null
			for key in plan["leaves"]:
				var leaf = plan["leaves"][key]
				if best == null or _value(leaf["result"]) > _value(best["result"]):
					best = leaf
			plan["route"] = best
		children.sort_custom(self, "_higher")
		beam = []
		var per_plan = {}
		for child in children:
			if beam.size() >= WIDTH:
				break
			# Room for at least two first moves while there are.
			if not _going(child["path"], child["result"]) or per_plan.get(child["plan"], 0) >= WIDTH - 1:
				continue
			per_plan[child["plan"]] = per_plan.get(child["plan"], 0) + 1
			beam.append(child)
		stats["rounds"] += 1
	# 3. the best routes against every DI policy
	for plan in plans:
		plan["branches"] = [_branch(_policies[0], plan["route"]["path"], plan["route"]["result"])]
	var by_route = plans.duplicate()
	by_route.sort_custom(self, "_route_higher")
	for plan in by_route.slice(0, VALIDATE - 1) if not by_route.empty() else []:
		if _out_of_time():
			stop = "out_of_time"
			break
		var checked = _validate(plan)
		if checked is GDScriptFunctionState:
			yield(checked, "completed")
	for plan in plans:
		_rate(plan)
	plans.sort_custom(self, "_better")
	# 4. escapes along the best route
	if not plans.empty() and not _out_of_time():
		var escaped = _check_escapes(plans[0])
		if escaped is GDScriptFunctionState:
			yield(escaped, "completed")
	if _sim != null:
		runtime.simulator.give_back(_sim)
		_sim = null
	if plans.empty():
		return {"ok": false, "error": _error if _error != "" else "out of thinking time before any move was played"}
	for plan in plans:
		_finish(plan)
	var labels = []
	var moves = []
	for policy in _policies:
		labels.append(policy["label"])
		moves.append(policy["option"])
	stats["stop"] = stop
	stats["ms"] = Util.now_ms() - started
	return {"ok": true, "attacker": attacker, "defender": defender, "goal": goal, "policies": labels, "policy_options": moves, "plans": plans,
		"searched": stats}


# The next step of a route ({"path", "result"}, or the live decision point
# with an empty path) against no DI: one variant of every move, then every
# variant of the best FAMILIES moves and finer aims around the best REFINE
# aimed ones. Returns [{"option", "path", "result", "value"}], best first.
func _search(route: Dictionary):
	var at = route
	if not route["result"]["node"].has("options"):
		var played = _goto(route["path"])
		if played is GDScriptFunctionState:
			played = yield(played, "completed")
		if played == null:
			return []
		at = {"path": route["path"], "result": played}
	var options = _attacks(at["result"]["node"]["options"].get(attacker, []))
	var defense = _defense(at["result"]["node"]["options"].get(defender, []), _policies[0])
	var families = {}
	var coarse = []
	for option in options:
		if not families.has(option["action"]):
			families[option["action"]] = []
			coarse.append(option)
		families[option["action"]].append(option)
	var out = _play(at, coarse, defense)
	if out is GDScriptFunctionState:
		out = yield(out, "completed")
	var more = []
	for item in out.slice(0, FAMILIES - 1) if not out.empty() else []:
		more += families[item["option"]["action"]].slice(1, families[item["option"]["action"]].size() - 1) if families[item["option"]["action"]].size() > 1 else []
	if not more.empty():
		var played = _play(at, more, defense)
		if played is GDScriptFunctionState:
			played = yield(played, "completed")
		out += played
		out.sort_custom(self, "_higher")
	var aims = []
	var specs = ctx["catalogs"].get(attacker, {}).get("specs", {}) if at["path"].empty() else ctx["sides"][attacker]["specs"]
	var view = _start if at["path"].empty() else at["result"]["steps"].back()["fighters"]
	var forward = 1 if view[defender]["position"]["x"] >= view[attacker]["position"]["x"] else -1
	var refined = 0
	for item in out:
		if refined >= REFINE:
			break
		var spec = specs.get(item["option"]["action"], {})
		if item["option"].get("input") is Dictionary and spec.get("kind") == "xy":
			refined += 1
			for option in _neighbours(item["option"], spec, forward):
				if _find(out, option) == null and _find(aims, option) == null:
					aims.append(option)
	if not aims.empty():
		var played = _play(at, aims, defense)
		if played is GDScriptFunctionState:
			played = yield(played, "completed")
		out += played
		out.sort_custom(self, "_higher")
	return out


# Plays each option one step from `route`'s position, the defender answering
# with `defense`. Returns [{"option", "path", "result", "value"}], best first.
# For many options from a deep position it copies the position once and
# plays every option from the copy; a single one plays on from the main
# preview when it stands there.
func _play(route: Dictionary, options: Array, defense: Dictionary):
	var out = []
	var fork = null
	var here = _key(route["path"])
	if not route["path"].empty() and options.size() >= FORK_MIN:
		var standing = _goto(route["path"])
		if standing is GDScriptFunctionState:
			standing = yield(standing, "completed")
		if standing != null:
			var forked = yield(runtime.simulator.fork(_sim), "completed")
			if forked["ok"]:
				fork = forked["game"]
				stats["forks"] += 1
	var fresh = true
	for option in options:
		if _out_of_time():
			break
		var path = route["path"] + [{attacker: option, defender: defense}]
		var key = _key(path)
		var result = _memo.get(key)
		if result == null and fork != null:
			if not fresh:
				var reused = runtime.lookahead.reuse(fork, _sim)
				if reused is GDScriptFunctionState:
					reused = yield(reused, "completed")
				fork = reused
			if fork != null:
				var outcome = runtime.lookahead.play_step(ctx, fork, path.back(), _hp)
				if outcome is GDScriptFunctionState:
					outcome = yield(outcome, "completed")
				fresh = false
				if outcome == null:
					fork = null
				else:
					result = {"steps": route["result"]["steps"] + [outcome], "node": runtime.lookahead.node_at(ctx, fork, outcome["stop"], false)}
					_memo[key] = result
					stats["exchanges"] += 1
		elif result == null and _at == here and not route["path"].empty() and _memo.has(here):
			var outcome = runtime.lookahead.play_step(ctx, _sim, path.back(), _hp)
			if outcome is GDScriptFunctionState:
				outcome = yield(outcome, "completed")
			if outcome != null:
				result = {"steps": _memo[here]["steps"] + [outcome], "node": runtime.lookahead.node_at(ctx, _sim, outcome["stop"], false)}
				_memo[key] = result
				_at = key
				stats["exchanges"] += 1
			else:
				_sim = null
				_at = ""
		if result == null:
			result = _eval(path)
			if result is GDScriptFunctionState:
				result = yield(result, "completed")
			if result == null:
				break
		out.append({"option": option, "path": path, "result": result, "value": _value(result)})
	if fork != null:
		runtime.simulator.discard(fork)
	out.sort_custom(self, "_higher")
	return out


# Aims next to `option`'s: AIM_STEP degrees either side at the same strength,
# and the same angle at half and three-quarter strength (unless the move
# always uses full length), within the pad's limits.
static func _neighbours(option: Dictionary, spec: Dictionary, forward: int) -> Array:
	var x = float(Util.as_int(option["input"].get("x", 0))) * forward
	var y = float(Util.as_int(option["input"].get("y", 0)))
	if x == 0.0 and y == 0.0:
		return []
	var degrees = rad2deg(atan2(y, x))
	var strength = min(1.0, Vector2(x, y).length() / PayloadSpec.XY_RANGE)
	var aims = []
	for turn in [-AIM_STEP, AIM_STEP]:
		if SimTurns.aim_allowed(spec, degrees + turn):
			aims.append(SimTurns.aim_input(degrees + turn, strength, forward))
	if not bool(spec.get("always_max", false)):
		for less in [0.5, 0.75]:
			if abs(less - strength) > 0.1:
				aims.append(SimTurns.aim_input(degrees, less, forward))
	var out = []
	for aim in aims:
		out.append(Lookahead._option(option["action"], "aim %d,%d" % [aim["x"], aim["y"]], aim, null, option["description"]))
	return out


# Plays the plan's route against every other DI policy: the same moves, until
# the combo ends or a move is not possible. Its branches become the full
# routes (no DI's is the route itself).
func _validate(plan: Dictionary):
	yield(runtime.lookahead.get_tree(), "idle_frame")
	var moves = []
	for step in plan["route"]["path"]:
		moves.append(step[attacker])
	var branches = [_branch(_policies[0], plan["route"]["path"], plan["route"]["result"])]
	for p in range(1, _policies.size()):
		var followed = _follow(moves, _policies[p])
		if followed is GDScriptFunctionState:
			followed = yield(followed, "completed")
		if followed == null:
			return
		var branch = _branch(_policies[p], followed["path"], followed["result"])
		if followed.has("broke"):
			branch["broke"] = followed["broke"]
		branches.append(branch)
	plan["branches"] = branches
	plan["validated"] = true


# Coroutine-like: `moves` (the attacker's, one per step) against `policy`,
# from the live decision point. Returns {"path", "result", "broke"?} or null
# when nothing could be played.
func _follow(moves: Array, policy: Dictionary):
	var ready = _prepare()
	if ready is GDScriptFunctionState:
		ready = yield(ready, "completed")
	if not ready:
		return null
	var path = []
	var steps = []
	var node = {"reached": "decision", "options": _root_options}
	var broke = ""
	for j in range(moves.size()):
		if j > 0:
			var legal = false
			for option in node["options"].get(attacker, []):
				legal = legal or option["action"] == moves[j]["action"]
			if not legal:
				broke = "%s is not possible at step %d" % [moves[j]["label"], j + 1]
				break
		var step = {attacker: moves[j], defender: _defense(node["options"].get(defender, []), policy)}
		path.append(step)
		_dirty = true
		var outcome = runtime.lookahead.play_step(ctx, _sim, step, _hp, j == 0)
		if outcome is GDScriptFunctionState:
			outcome = yield(outcome, "completed")
		if outcome == null:
			_sim = null
			_error = "the preview game was freed"
			return null
		stats["exchanges"] += 1
		steps.append(outcome)
		node = runtime.lookahead.node_at(ctx, _sim, outcome["stop"], true)
		if not _going(path, {"steps": steps, "node": node}):
			break
	var result = {"steps": steps, "node": node}
	_at = _key(path)
	_memo[_at] = result
	var out = {"path": path, "result": result}
	if broke != "":
		out["broke"] = broke
	return out


# The defender's other ways out along the best route against no DI: each
# escape (burst, counters) the defender has at a step, against the move the
# route plays there.
func _check_escapes(plan: Dictionary):
	var path = plan["route"]["path"]
	for k in range(path.size()):
		var before = {"node": {"options": _root_options}} if k == 0 else _memo.get(_key(path.slice(0, k - 1)))
		if before == null or not before["node"].has("options"):
			continue
		for escape in _escapes(before["node"]["options"].get(defender, [])):
			if _out_of_time():
				return
			var result = _eval((path.slice(0, k - 1) if k > 0 else []) + [{attacker: path[k][attacker], defender: escape}])
			if result is GDScriptFunctionState:
				result = yield(result, "completed")
			if result != null:
				plan["escapes"].append({"step": k + 1, "option": escape, "result": result})


# Coroutine-like: play_path's result for `path`, from the memo when it was
# played before; null when no preview could be played (see _error). Yields
# (and must be awaited) only when it waits for a frame or a new preview.
func _eval(path: Array, with_options: bool = false):
	var key = _key(path)
	var known = _memo.get(key)
	if known != null and (not with_options or known["node"]["reached"] != "decision" or known["node"].has("options")):
		return known
	var ready = _prepare()
	if ready is GDScriptFunctionState:
		ready = yield(ready, "completed")
	if not ready:
		return null
	_dirty = true
	var played = runtime.lookahead.play_path(ctx, _sim, path, with_options)
	if played is GDScriptFunctionState:
		played = yield(played, "completed")
	if played.has("gone"):
		_sim = null
		_error = "the preview game was freed"
		return null
	stats["exchanges"] += 1
	_memo[key] = played
	_at = key
	return played


# Coroutine-like: the main preview standing at the end of `path` with its
# move lists; play_path's result, or null.
func _goto(path: Array):
	var key = _key(path)
	if _at == key and _memo.has(key) and _memo[key]["node"].has("options"):
		return _memo[key]
	_memo.erase(key)
	var played = _eval(path, true)
	if played is GDScriptFunctionState:
		played = yield(played, "completed")
	return played


# Coroutine-like: the main preview back at the live decision point; false
# when no preview could be had (see _error).
func _prepare():
	if _sim != null and _dirty:
		var reused = runtime.lookahead.reuse(_sim)
		if reused is GDScriptFunctionState:
			reused = yield(reused, "completed")
		_sim = reused
	if _sim == null:
		var taken = yield(runtime.lookahead.preview(), "completed")
		if not taken["ok"]:
			_error = taken["error"]
			return false
		_sim = taken["game"]
	_dirty = false
	_at = ""
	return true


func _out_of_time() -> bool:
	return _error != "" or Util.now_ms() >= _deadline or runtime.matches.turn_for_token(ctx["token"]) == null


static func _key(path: Array) -> String:
	var keys = []
	for step in path:
		var pair = []
		for side in ["p1", "p2"]:
			pair.append(Lookahead._move_key(step[side]) if step.has(side) else null)
		keys.append(pair)
	return Util.json_str(keys)


func _branch(policy: Dictionary, path: Array, result: Dictionary) -> Dictionary:
	var branch = {"policy": policy, "path": path, "result": result}
	var state = _status(result)
	branch["status"] = state["status"]
	if state.has("end"):
		branch["end"] = state["end"]
	if branch["status"] == "open" and path.size() >= MAX_STEPS:
		branch["cut"] = "step limit (%d)" % MAX_STEPS
	return branch


# Where a played path left the combo: {"status": open (the defender still
# cannot act), ended, ko or stuck (no decision point within the tick limit),
# "end"? (ended: "defender acts first" or "even")}.
func _status(result: Dictionary) -> Dictionary:
	var node = result["node"]
	if node["reached"] != "decision":
		return {"status": node["reached"]}
	var busy = node["busy"]
	var view = result["steps"].back()["fighters"]
	if busy[defender] and (not busy[attacker] or (view[defender]["hurt"] and not view[attacker]["hurt"])):
		return {"status": "open"}
	return {"status": "ended", "end": "defender acts first" if busy[attacker] else "even"}


func _going(path: Array, result: Dictionary) -> bool:
	return path.size() < MAX_STEPS and _status(result)["status"] == "open"


# Damage the attacker dealt and took over a played path: {"dealt", "taken",
# "ko": defender, attacker or ""}.
func damage(result: Dictionary) -> Dictionary:
	if result["steps"].empty():
		return {"dealt": 0, "taken": 0, "ko": ""}
	var last = result["steps"].back()
	var mine = attacker == ctx["slot"]
	var ko = ""
	if last["ko"] != "":
		ko = "defender" if (last["ko"] == "opponent") == mine else "attacker"
	return {"dealt": last["dealt"] if mine else last["taken"], "taken": last["taken"] if mine else last["dealt"], "ko": ko}


# How the search ranks a played path for the attacker: damage dealt minus
# taken (a KO counts KO_VALUE), CONTINUE_BONUS while the combo is going, the
# goal's term and what the attacker spent.
func _value(result: Dictionary) -> float:
	var hurt = damage(result)
	var value = float(hurt["dealt"] - hurt["taken"]) + (KO_VALUE if hurt["ko"] == "defender" else (-KO_VALUE if hurt["ko"] == "attacker" else 0.0))
	var state = _status(result)
	if state["status"] == "open":
		value += CONTINUE_BONUS
	elif goal == "safe" and state.get("end") == "defender acts first":
		value -= SAFE_PENALTY
	if not result["steps"].empty():
		var end = result["steps"].back()["fighters"]
		if goal == "corner":
			value += CORNER_WEIGHT * _carry(end)
		var used = spent(end)
		value -= SPEND[goal][0] * used["meter_bars"] + SPEND[goal][1] * used["bursts"]
	return value


# Meter bars and bursts the attacker used, from the live decision point to a
# position's fighter views.
func spent(end: Dictionary) -> Dictionary:
	return {"meter_bars": int(max(0, _start[attacker]["meter_bars"] - end[attacker]["meter_bars"])),
		"bursts": int(max(0, _start[attacker]["bursts"] - end[attacker]["bursts"]))}


# How far the defender was carried toward the wall behind them (the one away
# from the attacker at the start).
func _carry(end: Dictionary) -> float:
	var behind = "right" if _start[defender]["position"]["x"] >= _start[attacker]["position"]["x"] else "left"
	if not (_start[defender].has("walls") and end[defender].has("walls")):
		return 0.0
	return float(_start[defender]["walls"][behind] - end[defender]["walls"][behind])


# A plan is worth its worst branch; the mean breaks ties.
func _rate(plan: Dictionary) -> void:
	var worst = INF
	var total = 0.0
	for branch in plan["branches"]:
		var value = _value(branch["result"])
		worst = min(worst, value)
		total += value
	plan["value"] = worst
	plan["mean"] = total / plan["branches"].size()


# Damage over the branches, for the report; branches still going count what
# they dealt so far.
func _finish(plan: Dictionary) -> void:
	var totals = {"robust": INF, "expected": 0.0, "max": -INF}
	var taken = 0
	for branch in plan["branches"]:
		if branch["status"] == "open" and not branch.has("cut"):
			branch["cut"] = "the search ended" if plan["validated"] else "only the first step was played against this DI"
		var hurt = damage(branch["result"])
		branch["dealt"] = hurt["dealt"]
		branch["taken"] = hurt["taken"]
		branch["ko"] = hurt["ko"]
		totals["robust"] = min(totals["robust"], hurt["dealt"])
		totals["max"] = max(totals["max"], hurt["dealt"])
		totals["expected"] += float(hurt["dealt"]) / plan["branches"].size()
		taken = int(max(taken, hurt["taken"]))
	totals["robust"] = int(totals["robust"])
	totals["max"] = int(totals["max"])
	plan["damage"] = totals
	plan["taken"] = taken
	# Where the route (against no DI) leaves both fighters, and what it spent.
	var end = plan["route"]["result"]["steps"].back()["fighters"]
	var used = spent(end)
	plan["spent"] = {}
	for key in used:
		if used[key] > 0:
			plan["spent"][key] = used[key]
	var gap = end[defender]["position"]["x"] - end[attacker]["position"]["x"]
	plan["end_position"] = {"distance_x": int(abs(gap)), "attacker_state": end[attacker]["state"], "defender_state": end[defender]["state"]}
	if end[defender].has("walls"):
		plan["end_position"]["defender_to_wall_behind"] = end[defender]["walls"]["right" if gap >= 0 else "left"]


# Routes checked against every DI policy first, then by worst branch and
# mean; on a tie, a seed (a remembered route's next move, a named move).
func _better(a: Dictionary, b: Dictionary) -> bool:
	if a["validated"] != b["validated"]:
		return a["validated"]
	if a["value"] != b["value"]:
		return a["value"] > b["value"]
	if a["mean"] != b["mean"]:
		return a["mean"] > b["mean"]
	return a["seeded"] and not b["seeded"]


func _route_higher(a: Dictionary, b: Dictionary) -> bool:
	return _value(a["route"]["result"]) > _value(b["route"]["result"])


static func _higher(a: Dictionary, b: Dictionary) -> bool:
	return a["value"] > b["value"]


# Attacker options worth searching: defensive moves (blocks, dodges) cannot
# extend a combo, so they are left out while anything else is legal.
static func _attacks(options: Array) -> Array:
	var out = []
	for option in options:
		if not option["description"].ends_with("(Defense)"):
			out.append(option)
	return out if not out.empty() else options


static func _escapes(options: Array) -> Array:
	var out = []
	for option in options:
		if option["action"] != "Continue":
			out.append(option)
	return out


# The defender's move for `policy` among a position's options: the same DI,
# else no DI.
static func _defense(options: Array, policy: Dictionary) -> Dictionary:
	for option in options:
		if option["label"] == policy["option"]["label"]:
			return option
	for option in options:
		if option["action"] == "Continue" and option.get("di") == null:
			return option
	return options[0] if not options.empty() else Lookahead._hold()


# The entry of `list` (options, or {"option"} items) that is the same move as
# `option`, or null.
static func _find(list: Array, option: Dictionary):
	var key = Util.json_str(Lookahead._move_key(option))
	for item in list:
		var other = item["option"] if item.has("option") else item
		if Util.json_str(Lookahead._move_key(other)) == key:
			return other
	return null

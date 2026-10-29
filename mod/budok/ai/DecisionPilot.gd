extends Node

# Decision-model player: plays every slot whose controller is "decision" with
# the decision core (ai/DecisionCore.gd). Each turn the core ranks your moves,
# plays them ahead on the real engine and picks the best by what it saw; when
# several are close, the models choose among those, and the move is drawn
# from their ranking (ai.decide.pick "sample", so the bot is hard to read) or
# is the top one ("best"). Combo turns are the combo solver's alone. Notes and
# lessons still come from chat models; this player only reads them.

const Util = preload("res://budok/core/Util.gd")
const Lookahead = preload("res://budok/core/Lookahead.gd")

var runtime = null
var stats := {"turns": 0, "fallbacks": 0, "last_error": "", "last_decision": "", "last_think_ms": 0}
var _busy := {"p1": "", "p2": ""}


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	runtime.matches.connect("turn_opened", self, "_on_turn_opened")


func _on_turn_opened(slot: String, token: String) -> void:
	if runtime.matches.controllers.get(slot) != "decision" or _busy[slot] == token:
		return
	_busy[slot] = token
	_take_turn(slot, token)


func _take_turn(slot: String, token: String) -> void:
	yield(get_tree(), "idle_frame")
	# Match-start notes for these characters come first (schemas.auto).
	while runtime.schema_jobs.holding() and runtime.matches.turn_for_token(token) != null:
		yield(get_tree().create_timer(0.5), "timeout")
	var turn = runtime.matches.turn_for_token(token)
	if turn == null or turn.has("applied"):
		_busy[slot] = ""
		return
	var started = Util.now_ms()
	var pick = null
	var summary = "only option"
	var mine = runtime.lookahead.live_options(runtime.lookahead.context(slot, turn, 2), slot)
	if mine.size() == 1:
		pick = mine[0]
	else:
		var timeout_s = float(runtime.config.get_value("turns.timeout_s.decision", 0))
		# Everything, waits for a free request included, ends 5 s before the turn timeout.
		var limit = started + int((timeout_s - 5.0 if timeout_s > 0 else 600.0) * 1000.0)
		var analysis = yield(runtime.core.analyze(slot, turn, {"rank": true, "limit": limit}), "completed")
		if analysis["ok"] and not analysis["candidates"].empty():
			var chosen = _choose(analysis)
			pick = chosen["option"]
			summary = chosen["summary"]
		else:
			stats["last_error"] = str(analysis.get("error", "no candidates"))
			push_warning("budok decision %s: %s" % [slot, stats["last_error"]])
	if runtime.matches.turn_for_token(token) != null:
		var result = {"ok": false}
		if pick != null:
			result = runtime.matches.submit(token, pick["action"], pick["input"], Lookahead.extra_of(pick), "decision")
			if not result.get("ok", false):
				stats["last_error"] = "submit %s: %s" % [pick["label"], result.get("message", result.get("error", ""))]
		if not result.get("ok", false):
			stats["fallbacks"] += 1
			var fallback = str(runtime.config.get_value("turns.fallback_action", "Continue"))
			if not runtime.matches.submit(token, fallback, null, {}, "decision_fallback").get("ok", false):
				runtime.matches.submit(token, "Continue", null, {}, "decision_fallback")
		elif pick != null:
			stats["last_decision"] = "%s t%d: %s (%s)" % [slot, turn["tick"], pick["label"], summary]
	stats["turns"] += 1
	stats["last_think_ms"] = Util.now_ms() - started
	if _busy[slot] == token:
		_busy[slot] = ""


# {"option", "summary"} from an analysis: drawn from the last ranking, or the
# best simulation score when the ranking request failed.
func _choose(analysis: Dictionary) -> Dictionary:
	var candidates = []
	for entry in analysis["candidates"]:
		candidates.append(entry["option"])
	var ranking = analysis["ranking"]
	if ranking.empty():
		var best = 0
		for i in range(analysis["candidates"].size()):
			if analysis["candidates"][i]["score"] > analysis["candidates"][best]["score"]:
				best = i
		ranking = {candidates[best]["label"]: 1.0}
	var mode = "best" if str(runtime.config.get_value("ai.decide.pick", "sample")) == "best" else "sample"
	var option = runtime.core.pick(candidates, ranking, mode)
	var notes = []
	if analysis.has("combo"):
		var plan = analysis["combo"]["plans"][0]
		notes.append("combo solver, %s: %d exchanges, best route keeps %d damage against every DI%s" % [analysis["situation"],
			analysis["combo"]["searched"]["exchanges"], plan["damage"]["robust"], "" if plan["validated"] else " (no DI check)"])
		if analysis.has("route") and analysis["route"]["status"] != "new":
			notes.append("route " + analysis["route"]["status"])
	elif analysis["depth"] > 0:
		notes.append("%d of %d lines, depth %d" % [analysis["lines_played"], analysis["lines_planned"], analysis["depth"]])
	else:
		notes.append("no simulations")
	if analysis.has("ranking_error"):
		notes.append("ranking failed, the engine's pick")
	return {"option": option, "summary": "%d%%, %s" % [int(round(float(ranking.get(option["label"], 0.0)) * 100)), PoolStringArray(notes).join("; ")]}

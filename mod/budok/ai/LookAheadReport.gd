extends Reference

# The look_ahead tool's answer: the decision core's analysis
# (DecisionCore.analyze) as a chat model reads it.

const Util = preload("res://budok/core/Util.gd")
const Lookahead = preload("res://budok/core/Lookahead.gd")
const Evidence = preload("res://budok/ai/Evidence.gd")
# Steps shown per line or route unless detail is full.
const STEPS_SHOWN := 6


# The analysis as the chat model sees it: where the runs start, how much was
# covered, what the engine recommends, and per move what to submit, its
# average and worst case over the replies, the likeliest and most dangerous
# replies, and the deep lines with every step as submit_action takes it. On a
# combo turn, the solver's routes. detail "full" adds every reply and step.
static func summarize(analysis: Dictionary, detail: String = "summary") -> Dictionary:
	var full = detail == "full"
	var combo = analysis.has("combo")
	var replies = []
	for reply in analysis["replies"]:
		replies.append(reply["option"])
	var moves = []
	for entry in analysis["candidates"]:
		var item = {"move": entry["option"]["label"]}
		var action = Lookahead.action_of(entry["option"])
		for key in action:
			item[key] = action[key]
		if not entry["replies"].empty() or entry.has("played"):
			var played = entry.get("played", entry["replies"][0]["outcome"] if not entry["replies"].empty() else {}).get("step", {}).get("you", {})
			if played.get("engine_data") != null and Util.json_str(played["engine_data"]) != Util.json_str(action.get("data")):
				item["engine_data"] = played["engine_data"]
			if played.has("note"):
				item["note"] = played["note"]
		if entry.has("added"):
			item["added"] = "defense: not one of the moves you named or the core picked"
		if entry["tested"] > 0:
			item["average"] = int(round(entry["average"]))
			var from = entry.get("followup_from", {})
			if not combo and from.get("measured", 0) + from.get("estimated", 0) > 0:
				item["followup"] = int(round(entry["followup"]))
				item["followup_from"] = "%d of %d replies from this move's own deep lines, %d estimated from lines that started from the same kind of position" % [
					from["measured"], entry["tested"], from["estimated"]]
			item["worst"] = {"reply": replies[entry["worst"]["index"]]["label"], "p": Evidence.percent(entry["worst"]["p"]),
				"result": Evidence.result_text(entry["worst"]["outcome"]), "reply_action": Lookahead.action_of(replies[entry["worst"]["index"]])}
			item["best"] = Evidence.reply_text(entry["best"], replies)
			var likely = []
			for reply in Evidence.likely(entry, 3):
				likely.append(Evidence.reply_text(reply, replies))
			item["likely"] = likely
			var dangerous = []
			for reply in Evidence.dangerous(entry, 3):
				dangerous.append(Evidence.reply_text(reply, replies))
			if not dangerous.empty():
				item["dangerous"] = dangerous
			if entry["tested"] < replies.size():
				item["tested_against"] = "%d of %d replies" % [entry["tested"], replies.size()]
			if full:
				var all = []
				for reply in Evidence.likely(entry, entry["replies"].size()):
					all.append(Evidence.reply_text(reply, replies))
				item["replies"] = all
		else:
			item["not_simulated"] = "out of thinking time before this move was played"
		if entry["score"] != -INF:
			item["score"] = int(round(entry["score"]))
		if entry.get("prior") != null:
			item["decision_model_first_guess"] = Evidence.percent(float(entry["prior"]))
		if analysis.get("ranking_by", "") == "decision models" and analysis["ranking"].has(entry["option"]["label"]):
			item["decision_model_pick"] = Evidence.percent(float(analysis["ranking"][entry["option"]["label"]]))
		var lines = []
		for line in entry["lines"]:
			lines.append(_line_view(line, replies, analysis["depth"], full))
		if not lines.empty():
			item["lines"] = lines
		moves.append(item)
	var start = analysis["start"].duplicate()
	if not combo:
		start["preview"] = "matches the live match" if analysis["sweep"]["check"].empty() else {"differs_from_live": analysis["sweep"]["check"]}
	var out = {"ok": true, "situation": analysis.get("situation", "open"), "start": start}
	var engine = analysis.get("engine", {})
	if engine.has("best"):
		out["recommended"] = {"move": engine["best"], "why": (_combo_why(analysis) if combo else
			"the best score among moves whose worst case is not a KO against you")}
		if engine["close"].size() > 1 and not combo:
			out["close_calls"] = engine["close"]
		if not engine["unsafe"].empty():
			out["avoid"] = {"moves": engine["unsafe"], "why": "their worst case is a KO against you"}
	if analysis.get("ranking_by", "") == "decision models":
		out["decision_model_pick"] = _top_label(analysis["ranking"])
	if combo:
		out["combo"] = _combo_view(analysis, full)
		out["how_to_read"] = ("A combo turn: one fighter can only DI, burst or wait. The solver played the attacker's moves on the real engine (no "
			+ "decision models): every first move, the best routes step by step until the combo ends, then those routes, the same moves, "
			+ "against every DI (none, and eight directions held for the whole combo). robust_damage is what a route keeps whatever the "
			+ "defender DIs, max_damage the most it does against one DI. Per move, average and worst are over the DIs (attacking) or over the "
			+ "attacker's routes (defending), for the whole route, as damage dealt minus taken. Submit the recommended move with its action, "
			+ "data and extra exactly as listed, and look again next turn from where the hit really sent them.")
	else:
		out["coverage"] = _coverage(analysis, replies)
		out["depth"] = analysis["depth"]
		out["how_to_read"] = ("Each move was played on the real engine against the opponent's replies up to the next decision point. average: "
			+ "damage dealt minus taken (a KO counts 1000) weighted by how likely each reply is; worst: the reply that hurts that move most; "
			+ "followup: what the deep lines (the decision models picking both sides) showed after that exchange; score = average + followup. "
			+ "recommended is the engine's pick; close_calls are within %d of it, where reading the opponent decides. Submit a move with its "
			+ "action, data and extra exactly as listed.") % int(Evidence.CLOSE_MARGIN)
	out["moves"] = moves
	if analysis["lines_planned"] > 0:
		out["lines_played"] = "%d of %d" % [analysis["lines_played"], analysis["lines_planned"]]
	var notes = analysis["notes"].duplicate()
	if analysis.has("ranking_error"):
		notes.append("no ranking from the decision models (%s): the engine's pick stands" % str(analysis["ranking_error"]))
	if not notes.empty():
		out["notes"] = notes
	return out


static func _top_label(ranking: Dictionary) -> String:
	var best = ""
	for label in ranking:
		if best == "" or ranking[label] > ranking[best]:
			best = label
	return best


static func _combo_why(analysis: Dictionary) -> String:
	if analysis["situation"] == "attacking":
		return "the route that keeps the most damage whatever the opponent DIs (see combo.best_route)"
	return "the DI or escape that holds the opponent's best routes lowest (see combo.their_best_route and each move's worst)"


# The solver's routes for the chat model: the best in full, a few others in brief.
static func _combo_view(analysis: Dictionary, full: bool) -> Dictionary:
	var solved = analysis["combo"]
	var attacking = analysis["situation"] == "attacking"
	var searched = solved["searched"]
	var out = {"you_are": ("attacking: the opponent can only DI, burst or wait" if attacking
			else "being hit (or stuck in a move): you can only DI, burst or wait, and the routes are the opponent's"),
		"goal": solved["goal"],
		"searched": "%d exchanges in %.1f s: %d first moves, %d rounds deeper%s" % [searched["exchanges"], searched["ms"] / 1000.0, searched["options"],
			searched["rounds"], "; routes were still going when the thinking time ran out (ai.core.think_s)" if searched["stop"] == "out_of_time" else ""]}
	var plans = solved["plans"]
	out["best_route" if attacking else "their_best_route"] = _route_view(plans[0], solved, attacking, full)
	var others = []
	for plan in plans.slice(1, min(3, plans.size() - 1)) if plans.size() > 1 else []:
		others.append({"first": step_view(plan["route"]["result"]["steps"][0]["step"].get("you" if attacking else "opponent")),
			"robust_damage": plan["damage"]["robust"], "max_damage": plan["damage"]["max"], "checked_against_every_di": plan["validated"]})
	if not others.empty():
		out["other_routes" if attacking else "their_other_routes"] = others
	if analysis.has("route"):
		out["remembered_route"] = analysis["route"]
	return out


static func _route_view(plan: Dictionary, solved: Dictionary, attacking: bool, full: bool) -> Dictionary:
	var who = "you" if attacking else "opponent"
	var steps = []
	for outcome in plan["route"]["result"]["steps"]:
		steps.append(step_view(outcome["step"].get(who)))
	var out = {"first": steps[0], "robust_damage": plan["damage"]["robust"], "expected_damage": int(round(plan["damage"]["expected"])),
		"max_damage": plan["damage"]["max"],
		"checked": ("against every DI (%d)" % solved["policies"].size()) if plan["validated"] else "against no DI only: out of time before the DI check",
		"steps": steps if full else steps.slice(0, min(STEPS_SHOWN, steps.size()) - 1)}
	if steps.size() > out["steps"].size():
		out["more_steps"] = "%d more (detail: full shows them)" % (steps.size() - out["steps"].size())
	if plan["taken"] > 0:
		out["attacker_took_up_to"] = plan["taken"]
	var by_di = []
	var soonest = {}
	for branch in plan["branches"]:
		by_di.append({"di": branch["policy"]["label"], "damage": branch["dealt"], "end": branch_end(branch, attacking)})
		if branch["status"] != "open" and (soonest.empty() or branch["path"].size() < soonest["path"].size()):
			soonest = branch
	out["by_di"] = by_di
	if not soonest.empty() and plan["validated"]:
		out["escape"] = "%s ends it soonest: after %d steps, %d damage" % [soonest["policy"]["label"], soonest["path"].size(), soonest["dealt"]]
	var escapes = []
	for escape in plan["escapes"]:
		escapes.append("%s at step %d: %s" % [escape["option"]["label"], escape["step"], Evidence.result_text(escape["result"]["steps"].back())])
	if not escapes.empty():
		out["if_they_escape" if attacking else "if_you_escape"] = escapes
	if not plan["spent"].empty():
		out["spends"] = plan["spent"]
	out["ends"] = plan["end_position"]
	return out


# How a route's branch ended, in words.
static func branch_end(branch: Dictionary, attacking: bool) -> String:
	var n = branch["path"].size()
	if branch.has("broke"):
		return "the route broke after %d steps: %s" % [n, branch["broke"]]
	match branch["status"]:
		"ko":
			return "KO after %d steps" % n
		"stuck":
			return "no decision point within the tick limit after %d steps" % n
		"open":
			return "still going after %d steps (%s)" % [n, branch.get("cut", "")]
	if branch.get("end", "") == "defender acts first":
		return "%s can act first after %d steps" % ["the opponent" if attacking else "you", n]
	return "both can act after %d steps" % n


static func _coverage(analysis: Dictionary, replies: Array) -> String:
	var moves = {}
	for reply in replies:
		moves[reply["action"]] = true
	var sweep = analysis["sweep"]
	var text = "your %d moves against %s: %d of %d exchanges played" % [analysis["candidates"].size(),
		("the %d replies you named" % replies.size()) if analysis["replies_named"] else ("all %d opponent replies (%d moves and their variants)" % [replies.size(), moves.size()]),
		sweep["played"], sweep["pairs"]]
	if sweep["played"] < sweep["pairs"]:
		text += "; out of time before the least likely replies (raise ai.core.think_s, or name fewer moves)"
	return text


static func _line_view(line: Dictionary, replies: Array, depth: int, full: bool) -> Dictionary:
	var out = {"vs": replies[line["reply"]]["label"], "turns": line["turns"],
		"result": "dealt %d, took %d%s" % [line["dealt"], line["taken"], Evidence.ko_text(line["ko"])],
		"followup": "%+d after the first exchange%s" % [int(round(line.get("followup", 0.0))), " (not counted: cut short)" if line.get("unresolved", false) else ""],
		"stopped": stop_text(line["stop"], line.get("stop_detail", ""), line["turns"], depth)}
	if line["stop"] == "depth" and line.get("unresolved", false):
		out["stopped"] = "played %d turns, but a combo was still going (it got %d extra turns to finish)" % [line["turns"], Lookahead.COMBO_GRACE]
	var steps = []
	for step in line["steps"] if full else line["steps"].slice(0, STEPS_SHOWN - 1):
		steps.append({"you": step_view(step.get("you")), "opponent": step_view(step.get("opponent"))})
	out["steps"] = steps
	if steps.size() < line["steps"].size():
		out["more_steps"] = "%d more turns (detail: full shows them)" % (line["steps"].size() - steps.size())
	return out


# One fighter's move in a line, as submit_action takes it, plus what the
# engine got when that differs.
static func step_view(played):
	if not (played is Dictionary):
		return "busy: keeps doing their move"
	var out = {"move": played["move"]}
	for key in played["action"]:
		out[key] = played["action"][key]
	if played.get("engine_data") != null and Util.json_str(played["engine_data"]) != Util.json_str(played["action"].get("data")):
		out["engine_data"] = played["engine_data"]
	if played.has("note"):
		out["note"] = played["note"]
	return out


# Why a line ended, in words.
static func stop_text(stop: String, detail: String, turns: int, depth: int) -> String:
	match stop:
		"depth":
			return "played all %d turns" % turns
		"ko":
			return "KO after %d turns" % turns
		"stuck":
			return "stopped after %d of %d turns: no decision point within the tick limit (simulation.max_ticks), e.g. a long move" % [turns, depth]
		"out_of_time":
			return "stopped after %d of %d turns: out of thinking time (ai.core.think_s)" % [turns, depth]
		"turn_over":
			return "stopped after %d of %d turns: the live turn ended" % [turns, depth]
		"model":
			return "stopped after %d of %d turns: the decision model gave no move (%s)" % [turns, depth, detail]
	return "stopped after %d of %d turns (%s)" % [turns, depth, stop]

extends Reference

# What the engine showed for a move, as numbers and words: an exchange's
# value, the replies worth naming, the text the decision models read, and the
# engine's pick among candidates. Shared by the decision core
# (ai/DecisionCore.gd) and the look_ahead report (ai/LookAheadReport.gd).

const KO_VALUE := 1000
# Moves whose score is within this of the best one's are close calls, which
# the decision models may choose among.
const CLOSE_MARGIN := 25.0


static func value(outcome: Dictionary) -> float:
	return float(outcome["dealt"] - outcome["taken"]) + (KO_VALUE if outcome["ko"] == "opponent" else (-KO_VALUE if outcome["ko"] == "you" else 0))


# Indices of `values`, largest first (ties keep their order).
static func ranked(values: Array) -> Array:
	var out = []
	for i in range(values.size()):
		var at = out.size()
		while at > 0 and values[out[at - 1]] < values[i]:
			at -= 1
		out.insert(at, i)
	return out


# The n likeliest replies an entry was played against.
static func likely(entry: Dictionary, n: int) -> Array:
	var ps = []
	for item in entry["replies"]:
		ps.append(item["p"])
	var out = []
	for i in ranked(ps).slice(0, n - 1) if not ps.empty() else []:
		out.append(entry["replies"][i])
	return out


# Replies that cost the entry damage or a KO, worst first.
static func dangerous(entry: Dictionary, n: int) -> Array:
	var losses = []
	var values = []
	for item in entry["replies"]:
		if item["value"] < 0:
			losses.append(item)
			values.append(-item["value"])
	var out = []
	for i in ranked(values).slice(0, n - 1) if not values.empty() else []:
		out.append(losses[i])
	return out


static func percent(p: float) -> String:
	return "%d%%" % int(round(p * 100)) if p >= 0.005 else "<1%"


static func ko_text(ko: String) -> String:
	return " - KO for you" if ko == "opponent" else (" - you are KO'd" if ko == "you" else "")


static func result_text(outcome: Dictionary) -> String:
	var parts = []
	if outcome["dealt"] != 0 or outcome["taken"] == 0:
		parts.append("deal %d" % outcome["dealt"])
	if outcome["taken"] != 0 or outcome["dealt"] == 0:
		parts.append("take %d" % outcome["taken"])
	if outcome.get("next_turn", "") != "":
		parts.append(outcome["next_turn"])
	elif outcome.get("stop", "") == "stuck":
		parts.append("no decision point within the tick limit")
	return PoolStringArray(parts).join(", ") + ko_text(outcome["ko"])


# "vs Grab (5%): take 120, they act first"
static func reply_text(item: Dictionary, replies: Array) -> String:
	return "vs %s (%s): %s" % [replies[item["index"]]["label"], percent(item["p"]), result_text(item["outcome"])]


# What the engine showed for one candidate, as text for the ranking request.
static func evidence(entry: Dictionary, replies: Array) -> String:
	var parts = [entry["option"]["description"]]
	if entry["tested"] == 0:
		parts.append("not simulated (out of time)")
		return PoolStringArray(parts).join(". ")
	parts.append("against %d replies: average %+d (damage dealt minus taken)" % [entry["tested"], int(round(entry["average"]))])
	if entry.get("followup", 0.0) != 0.0:
		parts.append("follow-up %+d (what happened after the next exchange)" % int(round(entry["followup"])))
	parts.append("worst " + reply_text(entry["worst"], replies))
	var texts = []
	for item in likely(entry, 3):
		texts.append(reply_text(item, replies))
	parts.append("likeliest: " + PoolStringArray(texts).join("; "))
	for line in entry["lines"]:
		parts.append("played %d turns vs %s: you dealt %d, took %d%s%s" % [line["turns"], replies[line["reply"]]["label"], line["dealt"], line["taken"],
			ko_text(line["ko"]), " (cut short)" if line.get("unresolved", false) else ""])
	return PoolStringArray(parts).join(". ")


# The candidate the engine's evidence favours: the best score among those
# whose worst case is not a KO against you (when any avoids it), and the
# candidates close enough to it (CLOSE_MARGIN) that choosing is a judgement
# call. Returns {"best", "close": [index], "unsafe": [index]}, or {} when none
# was simulated.
static func engine_pick(entries: Array) -> Dictionary:
	var tested = []
	var safe = []
	for i in range(entries.size()):
		if entries[i]["tested"] > 0:
			tested.append(i)
			if entries[i]["worst"]["outcome"]["ko"] != "you":
				safe.append(i)
	if tested.empty():
		return {}
	var pool = safe if not safe.empty() else tested
	var best = pool[0]
	for i in pool:
		if entries[i]["score"] > entries[best]["score"]:
			best = i
	var close = []
	for i in pool:
		if entries[i]["score"] >= entries[best]["score"] - CLOSE_MARGIN:
			close.append(i)
	var unsafe = []
	for i in tested:
		if not (i in pool):
			unsafe.append(i)
	return {"best": best, "close": close, "unsafe": unsafe}


static func engine_labels(entries: Array, pick: Dictionary) -> Dictionary:
	if pick.empty():
		return {}
	var out = {"best": entries[pick["best"]]["option"]["label"], "close": [], "unsafe": []}
	for key in ["close", "unsafe"]:
		for i in pick[key]:
			out[key].append(entries[i]["option"]["label"])
	return out

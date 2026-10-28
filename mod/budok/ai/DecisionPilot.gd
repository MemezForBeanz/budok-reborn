extends Node

# Decision-model player: plays every slot whose controller is "decision" with
# the model set in ai.decide (Jev through Vercel's AI Gateway or TypeSafe).
# Decision models pick one of fixed options and give a probability for each
# instead of chatting, so budok builds the options and the facts. Each turn:
#   1. one call ranks your moves and predicts the opponent's (two questions,
#      one request);
#   2. your top candidates are played on the real engine against the
#      opponent's likeliest replies, up to the next decision point;
#   3. `threads` lines keep playing from there for `depth` turns in all, the
#      model choosing both fighters' moves at every decision point (depth 1:
#      step 2 only; depth 0: no simulations, the first call decides);
#   4. a last call picks among the candidates, each now described with what the
#      engine showed. The move is drawn from its probabilities (pick "sample",
#      so the bot is hard to read) or is the likeliest one (pick "best").
# Notes and lessons still come from chat models; this player only reads them.

const Util = preload("res://budok/core/Util.gd")
const Observation = preload("res://budok/core/Observation.gd")
# Options below this share of the likeliest one are never drawn.
const SAMPLE_FLOOR := 0.1
const NOTE_CHARS := 140
const MAX_THREADS := 16
const MAX_DEPTH := 30
const KO_VALUE := 1000

var runtime = null
var llm = null
var stats := {"turns": 0, "fallbacks": 0, "calls": 0, "lines": 0, "sim_ticks": 0, "input_tokens": 0, "output_tokens": 0,
	"last_error": "", "last_decision": "", "last_think_ms": 0}
var _busy := {"p1": "", "p2": ""}
var _rng := RandomNumberGenerator.new()


func setup(runtime_ref, llm_ref) -> void:
	runtime = runtime_ref
	llm = llm_ref
	_rng.randomize()
	runtime.matches.connect("turn_opened", self, "_on_turn_opened")


func _on_turn_opened(slot: String, token: String) -> void:
	if runtime.matches.controllers.get(slot) != "decision" or _busy[slot] == token:
		return
	_busy[slot] = token
	_take_turn(slot, token)


func settings() -> Dictionary:
	var cfg = runtime.config.get_value("ai.decide", {})
	var simulate = bool(runtime.config.get_value("simulation.enabled", true))
	var think_s = clamp(float(cfg.get("think_s", 30)), 3.0, 600.0)
	var timeout_s = float(runtime.config.get_value("turns.timeout_s.decision", 0))
	if timeout_s > 0:
		think_s = clamp(timeout_s - 5.0, 1.0, think_s)
	return {
		"model": str(cfg.get("model", "")),
		"depth": int(clamp(Util.as_int(cfg.get("depth", 10)), 0, MAX_DEPTH)) if simulate else 0,
		"threads": int(clamp(Util.as_int(cfg.get("threads", 4)), 1, MAX_THREADS)),
		"candidates": int(clamp(Util.as_int(cfg.get("candidates", 4)), 1, 16)),
		"replies": int(clamp(Util.as_int(cfg.get("replies", 3)), 1, 8)),
		"max_options": int(clamp(Util.as_int(cfg.get("max_options", 48)), 2, 255)),
		"pick": "best" if str(cfg.get("pick", "sample")) == "best" else "sample",
		"think_ms": int(think_s * 1000.0),
		"request_timeout_s": clamp(float(cfg.get("request_timeout_s", 20)), 2.0, 300.0),
	}


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
	var cfg = settings()
	var ctx = runtime.lookahead.context(slot, turn, cfg["max_options"])
	var mine = runtime.lookahead.live_options(ctx, slot)
	var pick = mine[0]
	var summary = "only option"
	if mine.size() > 1:
		var decided = yield(_decide(ctx, mine, runtime.lookahead.live_options(ctx, ctx["other"]), cfg, started), "completed")
		pick = decided.get("option")
		summary = decided.get("summary", "")
		if pick == null:
			stats["last_error"] = str(decided.get("error", "no decision"))
			push_warning("budok decision %s: %s" % [slot, stats["last_error"]])
	if runtime.matches.turn_for_token(token) != null:
		var result = {"ok": false}
		if pick != null:
			result = runtime.matches.submit(token, pick["action"], pick["input"], {"di": pick["di"]} if pick["di"] is Dictionary else {},
				"decision:%s" % cfg["model"])
			if not result.get("ok", false):
				stats["last_error"] = "submit %s: %s" % [pick["label"], result.get("message", result.get("error", ""))]
		if not result.get("ok", false):
			stats["fallbacks"] += 1
			var fallback = str(runtime.config.get_value("turns.fallback_action", "Continue"))
			if not runtime.matches.submit(token, fallback, null, {}, "decision_fallback").get("ok", false):
				runtime.matches.submit(token, "Continue", null, {}, "decision_fallback")
		elif pick != null:
			stats["last_decision"] = "%s t%d: %s (%s)" % [slot, ctx["tick"], pick["label"], summary]
	stats["turns"] += 1
	stats["last_think_ms"] = Util.now_ms() - started
	stats["sim_ticks"] = runtime.lookahead.ticks_total
	if _busy[slot] == token:
		_busy[slot] = ""


# Coroutine: {"option", "summary"} or {"error"}.
func _decide(ctx: Dictionary, mine: Array, theirs: Array, cfg: Dictionary, started: int) -> Dictionary:
	var deadline = started + cfg["think_ms"]
	var state = _root_state(ctx)
	var names = _names(ctx)
	var questions = {"you": {"instructions": ("You are %s (%s) fighting %s in YOMI Hustle, a turn-based fighting game where both players "
		+ "lock in a move at the same time without seeing the other's. Pick your best move now.") % [names["you"], ctx["slot"], names["opponent"]],
		"options": _criteria(mine, ctx, ctx["slot"])}}
	if theirs.size() > 1:
		questions["opponent"] = {"instructions": "Which move will the opponent, %s, most likely lock in now?" % names["opponent"],
			"options": _criteria(theirs, ctx, ctx["other"])}
	var prior = yield(_call(state, questions, deadline, cfg), "completed")
	if not prior["ok"]:
		return {"error": prior["error"]}
	var my_p = prior["answers"]["you"]["probabilities"]
	var their_p = prior["answers"]["opponent"]["probabilities"] if prior["answers"].has("opponent") else {theirs[0]["label"]: 1.0}
	var candidates = _top(mine, my_p, cfg["candidates"])
	if candidates.size() == 1 or cfg["depth"] == 0:
		var only = _pick(mine, my_p, cfg["pick"])
		return {"option": only, "summary": "%d%% without simulations" % int(round(my_p[only["label"]] * 100))}
	var replies = _top(theirs, their_p, cfg["replies"])
	var lines = _plan(candidates, replies, cfg)
	# Leave time for the last call.
	var lines_deadline = deadline - int(min(cfg["request_timeout_s"] * 1000.0, cfg["think_ms"] / 3.0))
	var results = yield(_run_lines(ctx, lines, cfg, lines_deadline), "completed")
	if runtime.matches.turn_for_token(ctx["token"]) == null:
		return {"error": "the turn ended while thinking"}
	var played = 0
	for result in results:
		if result is Dictionary and result.get("ok", false):
			played += 1
	stats["lines"] += played
	var facts = _facts(candidates, replies, their_p, lines, results)
	var options = {}
	for i in range(candidates.size()):
		options[candidates[i]["label"]] = facts[i]["text"]
	var final = yield(_call(state + "\nbudok played your candidate moves on the real game engine; each option says what happened.", {"move": {
		"instructions": ("Lock in one move for this turn. Damage you deal minus damage you take matters most; a KO for you is best and a KO "
			+ "against you is worst. The opponent's replies are guesses, weighted by how likely each one is."),
		"options": options}}, deadline, cfg), "completed")
	var probabilities = {}
	if final["ok"]:
		probabilities = final["answers"]["move"]["probabilities"]
	else:
		# Fall back to the simulations' own verdict.
		var best = 0
		for i in range(candidates.size()):
			if facts[i]["score"] > facts[best]["score"]:
				best = i
		probabilities[candidates[best]["label"]] = 1.0
	var chosen = _pick(candidates, probabilities, cfg["pick"])
	return {"option": chosen, "summary": "%d%%, %d of %d lines played%s" % [int(round(probabilities.get(chosen["label"], 0.0) * 100)), played, lines.size(),
		"" if final["ok"] else "; last call failed, picked by simulations"]}


# Deep lines first (they take longest), spread over the candidates; then one
# short line for every other candidate/reply pair.
static func _plan(candidates: Array, replies: Array, cfg: Dictionary) -> Array:
	var lines = []
	var covered = {}
	if cfg["depth"] > 1:
		for t in range(cfg["threads"]):
			var c = t % candidates.size()
			var r = int(t / candidates.size()) % replies.size()
			lines.append({"candidate": c, "reply": r, "depth": cfg["depth"]})
			covered["%d/%d" % [c, r]] = true
	for c in range(candidates.size()):
		for r in range(replies.size()):
			if not covered.has("%d/%d" % [c, r]):
				lines.append({"candidate": c, "reply": r, "depth": 1})
	for line in lines:
		line["root"] = {"candidate": candidates[line["candidate"]], "reply": replies[line["reply"]]}
	return lines


# Coroutine: runs `lines` with at most `threads` of them at once.
func _run_lines(ctx: Dictionary, lines: Array, cfg: Dictionary, deadline: int) -> Array:
	yield(get_tree(), "idle_frame")
	var pool = {"next": 0, "done": 0, "results": []}
	for _line in lines:
		pool["results"].append(null)
	var workers = int(min(cfg["threads"], lines.size()))
	for _w in range(workers):
		_worker(ctx, lines, pool, deadline)
	while pool["done"] < workers:
		yield(get_tree(), "idle_frame")
	return pool["results"]


func _worker(ctx: Dictionary, lines: Array, pool: Dictionary, deadline: int) -> void:
	while pool["next"] < lines.size() and Util.now_ms() < deadline and runtime.matches.turn_for_token(ctx["token"]) != null:
		var index = pool["next"]
		pool["next"] += 1
		var line = lines[index]
		var root = {ctx["slot"]: line["root"]["candidate"], ctx["other"]: line["root"]["reply"]}
		pool["results"][index] = yield(runtime.lookahead.run_line(ctx, root, line["depth"], self, deadline), "completed")
	pool["done"] += 1


# Lookahead policy: the model picks both fighters' moves at a decision point
# inside a line; picks are drawn from its probabilities so lines differ.
func choose(info: Dictionary) -> Dictionary:
	var ctx = info["ctx"]
	var obs = Observation.build(info["sim"], ctx["slot"], ctx["infos"], [], "summary")
	var state = "Imagined continuation of the match, turn %d of %d. %s" % [info["turn"], info["depth"], Observation.situation(obs)]
	var names = _names(ctx)
	var questions = {}
	for side in info["options"]:
		var mine = side == ctx["slot"]
		questions["you" if mine else "opponent"] = {"options": _criteria(info["options"][side], {}, side),
			"instructions": "Pick your best move now." if mine else "Which move will the opponent, %s, most likely lock in now?" % names["opponent"]}
	var reply = yield(_call(state, questions, info["deadline"], settings()), "completed")
	if not reply["ok"]:
		return {}
	var picks = {}
	for side in info["options"]:
		picks[side] = _pick(info["options"][side], reply["answers"]["you" if side == ctx["slot"] else "opponent"]["probabilities"], "sample")
	return picks


# Coroutine: decide() bounded by the turn's thinking time.
func _call(state: String, questions: Dictionary, deadline: int, cfg: Dictionary) -> Dictionary:
	var remaining = (deadline - Util.now_ms()) / 1000.0
	if remaining < 1.0:
		yield(get_tree(), "idle_frame")
		return {"ok": false, "error": "out of thinking time (ai.decide.think_s)"}
	var reply = yield(llm.decide("decide", state, questions, min(cfg["request_timeout_s"], remaining)), "completed")
	stats["calls"] += 1
	if reply["ok"]:
		stats["input_tokens"] += Util.as_int(reply["usage"].get("input_tokens", 0))
		stats["output_tokens"] += Util.as_int(reply["usage"].get("output_tokens", 0))
	else:
		stats["last_error"] = str(reply.get("error", ""))
	return reply


func _root_state(ctx: Dictionary) -> String:
	var obs = runtime.matches.observation(ctx["slot"], "summary")
	var parts = [Observation.situation(obs)]
	if not obs["history"].empty():
		parts.append("Last turns (both moves, revealed after they played out): " + Util.json_str(obs["history"]))
	var memories = runtime.memory.lines(runtime.match_memories())
	if not memories.empty():
		parts.append("Lessons from earlier matches: " + PoolStringArray(memories).join(" | "))
	return PoolStringArray(parts).join("\n")


func _names(ctx: Dictionary) -> Dictionary:
	var characters = runtime.matches.match_info.get("characters", {})
	return {"you": str(characters.get(ctx["slot"], {}).get("display_name", ctx["slot"])),
		"opponent": str(characters.get(ctx["other"], {}).get("display_name", ctx["other"]))}


# {label: description}; with ctx, live options also get their move notes.
func _criteria(options: Array, ctx: Dictionary, side: String) -> Dictionary:
	var info = ctx.get("infos", {}).get(side, {})
	var out = {}
	for option in options:
		var text = option["description"]
		if not info.empty():
			var notes = runtime.schemas.move_notes(info, option["action"])
			if notes.has("summary"):
				text += ". " + Util.truncate(str(notes["summary"]), NOTE_CHARS)
		out[option["label"]] = text
	return out


# Per candidate: {"text": description with the engine's results, "score"}.
static func _facts(candidates: Array, replies: Array, their_p: Dictionary, lines: Array, results: Array) -> Array:
	var facts = []
	for c in range(candidates.size()):
		var parts = [candidates[c]["description"]]
		var weighted = 0.0
		var weight = 0.0
		var deep = []
		for i in range(lines.size()):
			var result = results[i]
			if lines[i]["candidate"] != c or not (result is Dictionary) or not result.get("ok", false):
				continue
			if lines[i]["depth"] > 1:
				deep.append(result)
			var reply = replies[lines[i]["reply"]]
			var p = float(their_p.get(reply["label"], 0.0))
			var first = result["first"]
			parts.append("vs %s (%d%% likely): you deal %d, take %d%s%s" % [reply["label"], int(round(p * 100)), first["dealt"], first["taken"],
				", " + first["next_turn"] if first.has("next_turn") else "", _ko_text(first["ko"])])
			weighted += p * _value(first)
			weight += p
		var score = weighted / weight if weight > 0.0 else 0.0
		if not deep.empty():
			var total = 0.0
			for result in deep:
				parts.append("played on %d turns: you dealt %d, took %d%s (you: %s; opponent: %s)" % [result["turns"], result["dealt"], result["taken"],
					_ko_text(result["ko"]), PoolStringArray(result["moves"]["you"]).join(", "), PoolStringArray(result["moves"]["opponent"]).join(", ")])
				total += _value(result)
			score += total / deep.size()
		if parts.size() == 1:
			parts.append("not simulated (out of time)")
		facts.append({"text": PoolStringArray(parts).join(". "), "score": score})
	return facts


static func _value(outcome: Dictionary) -> float:
	return float(outcome["dealt"] - outcome["taken"]) + (KO_VALUE if outcome["ko"] == "opponent" else (-KO_VALUE if outcome["ko"] == "you" else 0))


static func _ko_text(ko: String) -> String:
	return " - KO for you" if ko == "opponent" else (" - you are KO'd" if ko == "you" else "")


# The n likeliest options, likeliest first.
static func _top(options: Array, probabilities: Dictionary, n: int) -> Array:
	var rest = options.duplicate()
	var out = []
	while out.size() < n and not rest.empty():
		var best = 0
		for i in range(rest.size()):
			if float(probabilities.get(rest[i]["label"], 0.0)) > float(probabilities.get(rest[best]["label"], 0.0)):
				best = i
		out.append(rest[best])
		rest.remove(best)
	return out


func _pick(options: Array, probabilities: Dictionary, mode: String) -> Dictionary:
	var top = _top(options, probabilities, 1)[0]
	var ceiling = float(probabilities.get(top["label"], 0.0))
	if mode == "best" or ceiling <= 0.0:
		return top
	var total = 0.0
	for option in options:
		var p = float(probabilities.get(option["label"], 0.0))
		if p >= ceiling * SAMPLE_FLOOR:
			total += p
	var roll = _rng.randf() * total
	for option in options:
		var p = float(probabilities.get(option["label"], 0.0))
		if p >= ceiling * SAMPLE_FLOOR:
			roll -= p
			if roll <= 0.0:
				return option
	return top

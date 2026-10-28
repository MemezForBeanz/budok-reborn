extends Node

# The decision core: one or more decision-model endpoints (ai.core.endpoints,
# each with its own provider, model, API key, parallel requests and requests-
# per-minute limit) behind one dispatcher, and the lookahead analysis built on
# it. A request goes to the first endpoint (in list order) with a free slot, so
# several keys add up; a failing or rate-limited endpoint passes the request
# to the next one. The decision bot plays with analyze() directly; in Tandem
# mode a chat model (in the game or over MCP) calls look_ahead() to explore
# futures and decides itself, without spending its own context on them.
#
# analyze() for one turn:
#   1. unless the caller named them, one request ranks your moves and predicts
#      the opponent's (two questions, one request);
#   2. your candidates are played on the real engine against the opponent's
#      replies, up to the next decision point;
#   3. deep lines (one per parallel request the core has) keep playing for
#      `depth` turns in all, the model choosing both fighters' moves;
#   4. optionally, a last request ranks the candidates, each described with
#      what the engine showed.

const Util = preload("res://budok/core/Util.gd")
const Observation = preload("res://budok/core/Observation.gd")
const SimTurns = preload("res://budok/core/SimTurns.gd")
const PayloadSpec = preload("res://budok/core/PayloadSpec.gd")
const PROVIDERS := ["typesafe", "vercel"]
const MINUTE_MS := 60000
const MAX_DEPTH := 30
const MAX_THREADS := 32
const MAX_MOVES := 8
const KO_VALUE := 1000
const NOTE_CHARS := 140
# Options below this share of the likeliest one are never drawn.
const SAMPLE_FLOOR := 0.1
# How long an endpoint sits out after an error: a rejected key (401/403), else.
const BAD_KEY_PAUSE_MS := 300000
const ERROR_PAUSE_MS := 10000
const LOOK_AHEAD_HELP := ("Ask the decision core (fast decision models) to play this turn ahead on the real game engine for you. "
	+ "It tests your candidate moves against the opponent's likely replies, plays lines several turns deep with the decision models choosing both "
	+ "fighters' moves, and returns a few lines per move: the result against each reply, how the deep lines went, a score and the decision models' pick. "
	+ "Name your candidates (or omit them and the core picks its top ones), and steer the imagined lines with focus and opponent_style. "
	+ "It never reveals the opponent's real choice. You still decide: call submit_action afterwards.")

var runtime = null
var llm = null
var stats := {"calls": 0, "lines": 0, "input_tokens": 0, "output_tokens": 0, "last_error": ""}
var _rng := RandomNumberGenerator.new()
# Per endpoint id: active requests, recent request times, the limit learned
# from its rate-limit errors and when it lets us retry.
var _state := {}
var _limit_regex := RegEx.new()
var _retry_regex := RegEx.new()


func setup(runtime_ref, llm_ref) -> void:
	runtime = runtime_ref
	llm = llm_ref
	_rng.randomize()
	# Vercel's wording: "this team's limit of 5 requests per minute ... Retry after 48s."
	_limit_regex.compile("limit of (\\d+) requests per minute")
	_retry_regex.compile("[Rr]etry after (\\d+) ?s")


func settings() -> Dictionary:
	var cfg = runtime.config.get_value("ai.core", {})
	return {
		"depth": int(clamp(Util.as_int(cfg.get("depth", 10)), 0, MAX_DEPTH)) if bool(runtime.config.get_value("simulation.enabled", true)) else 0,
		"candidates": int(clamp(Util.as_int(cfg.get("candidates", 4)), 1, MAX_MOVES)),
		"replies": int(clamp(Util.as_int(cfg.get("replies", 3)), 1, MAX_MOVES)),
		"max_options": int(clamp(Util.as_int(cfg.get("max_options", 48)), 2, 255)),
		"think_ms": int(clamp(float(cfg.get("think_s", 30)), 3.0, 600.0) * 1000.0),
		"request_timeout_s": clamp(float(cfg.get("request_timeout_s", 20)), 2.0, 300.0),
	}


# Configured endpoints, each with its key resolved (its own, else the
# provider's key or environment variable) and whether it can be used.
func endpoints() -> Array:
	var out = []
	var list = runtime.config.get_value("ai.core.endpoints", [])
	for i in range(list.size() if list is Array else 0):
		var raw = list[i] if list[i] is Dictionary else {}
		var provider = str(raw.get("provider", "typesafe"))
		var endpoint = {
			"id": "%d:%s:%s" % [i, provider, str(raw.get("model", ""))],
			"label": str(raw.get("label", "")) if str(raw.get("label", "")) != "" else str(raw.get("model", provider)),
			"provider": provider,
			"model": str(raw.get("model", "")),
			"key": str(raw.get("api_key", "")) if str(raw.get("api_key", "")) != "" else runtime.config.api_key(provider),
			"base_url": str(runtime.config.get_value("ai.providers.%s.base_url" % provider, "")),
			"threads": int(clamp(Util.as_int(raw.get("threads", 4)), 1, MAX_THREADS)),
			"max_rpm": int(max(0, Util.as_int(raw.get("max_rpm", 0)))),
			"enabled": bool(raw.get("enabled", true)),
		}
		endpoint["problem"] = _problem(endpoint)
		out.append(endpoint)
	return out


static func _problem(endpoint: Dictionary) -> String:
	if not endpoint["enabled"]:
		return "turned off"
	if not (endpoint["provider"] in PROVIDERS):
		return "unknown provider %s" % endpoint["provider"]
	if endpoint["key"] == "":
		return "no API key"
	if endpoint["model"] == "" and endpoint["provider"] == "vercel":
		return "no model"
	return ""


func usable() -> Array:
	var out = []
	for endpoint in endpoints():
		if endpoint["problem"] == "":
			out.append(endpoint)
	return out


# Parallel requests the core can make: deep lines run this many at a time.
func capacity() -> int:
	var total = 0
	for endpoint in usable():
		total += endpoint["threads"]
	return total


# Requests per minute all usable endpoints allow together (0 = unlimited).
func rate_per_minute() -> int:
	var total = 0
	for endpoint in usable():
		var rpm = _rpm(endpoint)
		if rpm <= 0:
			return 0
		total += rpm
	return total


func status() -> Dictionary:
	var list = []
	for endpoint in endpoints():
		var state = _state_of(endpoint)
		var entry = {"label": endpoint["label"], "provider": endpoint["provider"], "model": endpoint["model"], "threads": endpoint["threads"],
			"calls": state["calls"], "errors": state["errors"]}
		if endpoint["problem"] != "":
			entry["problem"] = endpoint["problem"]
		if _rpm(endpoint) > 0:
			entry["requests_per_minute"] = _rpm(endpoint)
		if state["last_error"] != "":
			entry["last_error"] = state["last_error"]
		list.append(entry)
	return {"endpoints": list, "parallel_requests": capacity(), "calls": stats["calls"], "lines": stats["lines"], "last_error": stats["last_error"]}


# --- dispatch ---

# Coroutine: one question set to the decision model, on the first endpoint
# with a free slot. Calls inside lines never wait for a free request and keep
# one per endpoint in reserve, so a turn's own questions can still be asked.
func ask(state: String, questions: Dictionary, deadline: int, in_line: bool = false) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var tried = []
	var reply = {"ok": false, "error": "no decision model is set up (Models tab, Decision core)"}
	var last_error = ""
	while true:
		var pick = _next_endpoint(tried, 1 if in_line else 0)
		if pick.empty():
			return reply
		if pick["wait"] > 0:
			if in_line or Util.now_ms() + pick["wait"] > deadline - 1000:
				return {"ok": false, "error": "every decision model is busy or rate limited%s" % ("" if last_error == "" else "; last error: " + last_error)}
			yield(get_tree().create_timer(pick["wait"] / 1000.0), "timeout")
			continue
		var remaining = (deadline - Util.now_ms()) / 1000.0
		if remaining < 1.0:
			return {"ok": false, "error": "out of thinking time (ai.core.think_s)"}
		var endpoint = pick["endpoint"]
		var state_of = _state_of(endpoint)
		state_of["active"] += 1
		state_of["call_times"].append(Util.now_ms())
		state_of["calls"] += 1
		reply = yield(llm.decide_with(endpoint, state, questions, min(settings()["request_timeout_s"], remaining)), "completed")
		state_of["active"] -= 1
		stats["calls"] += 1
		if reply["ok"]:
			stats["input_tokens"] += Util.as_int(reply["usage"].get("input_tokens", 0))
			stats["output_tokens"] += Util.as_int(reply["usage"].get("output_tokens", 0))
			return reply
		state_of["errors"] += 1
		state_of["last_error"] = str(reply.get("error", ""))
		last_error = state_of["last_error"]
		stats["last_error"] = "%s: %s" % [endpoint["label"], state_of["last_error"]]
		var status = int(reply.get("status", 0))
		if status == 429:
			_learn_limit(state_of, state_of["last_error"])
		else:
			# A rejected key or a model it may not use won't work on the next
			# request either; other errors may be about this request only.
			state_of["blocked_until"] = Util.now_ms() + (BAD_KEY_PAUSE_MS if status in [401, 403] else ERROR_PAUSE_MS)
		if in_line:
			return reply
		tried.append(endpoint["id"])
	return reply


# {"endpoint", "wait"}: the first endpoint (in list order) that can take a
# request now, else the one free soonest; {} when none is left to try.
func _next_endpoint(tried: Array, reserve: int) -> Dictionary:
	var best = {}
	for endpoint in usable():
		if endpoint["id"] in tried:
			continue
		var state = _state_of(endpoint)
		var wait = _rate_wait_ms(state, _rpm(endpoint), reserve)
		if state["active"] >= endpoint["threads"]:
			wait = int(max(wait, 50))
		if wait == 0:
			return {"endpoint": endpoint, "wait": 0}
		if best.empty() or wait < best["wait"]:
			best = {"endpoint": endpoint, "wait": wait}
	return best


func _rpm(endpoint: Dictionary) -> int:
	var learned = _state_of(endpoint)["learned_rpm"]
	if endpoint["max_rpm"] > 0 and learned > 0:
		return int(min(endpoint["max_rpm"], learned))
	return endpoint["max_rpm"] if endpoint["max_rpm"] > 0 else learned


func _state_of(endpoint: Dictionary) -> Dictionary:
	if not _state.has(endpoint["id"]):
		_state[endpoint["id"]] = {"active": 0, "call_times": [], "learned_rpm": 0, "blocked_until": 0, "calls": 0, "errors": 0, "last_error": ""}
	return _state[endpoint["id"]]


# Milliseconds until `state`'s endpoint may take a request, keeping `reserve` free.
static func _rate_wait_ms(state: Dictionary, rpm: int, reserve: int) -> int:
	var now = Util.now_ms()
	var times = state["call_times"]
	while not times.empty() and times[0] <= now - MINUTE_MS:
		times.pop_front()
	var wait = int(max(0, state["blocked_until"] - now))
	if rpm > 0:
		var allowed = rpm - reserve
		if allowed <= 0:
			return MINUTE_MS
		if times.size() >= allowed:
			wait = int(max(wait, times[times.size() - allowed] + MINUTE_MS - now))
	return wait


func _learn_limit(state: Dictionary, error: String) -> void:
	var limit = _limit_regex.search(error)
	if limit != null:
		state["learned_rpm"] = int(limit.get_string(1))
	var retry = _retry_regex.search(error)
	state["blocked_until"] = Util.now_ms() + (int(retry.get_string(1)) * 1000 if retry != null else 5000)


# Lookahead depth that fits a rate limit: `fixed` requests a turn are needed
# for the turn's own questions, the rest go to deep lines (one per turn each).
static func depth_for_rate(depth: int, lines: int, rpm: int, think_ms: int, consumers: int, fixed: int = 2) -> int:
	if rpm <= 0 or depth <= 1:
		return depth
	var per_turn = int(rpm * think_ms / MINUTE_MS / max(1, consumers))
	var for_lines = per_turn - fixed
	if for_lines < lines:
		return 1
	return int(min(depth, 1 + for_lines / lines))


# --- analysis ---

# Coroutine. request: {"candidates"?: [option], "replies"?: [option], "depth"?,
# "lines"?, "focus"?, "opponent_style"?, "rank": bool, "think_ms"?, "limit"
# (absolute ms the whole analysis must end by)}. Returns {"ok", "candidates":
# [{"option", "prior"?, "replies": [...], "lines": [...], "text", "score"}],
# "replies": [{"option", "p"}], "ranking": {label: p}, "depth", "lines_planned",
# "lines_played"} or {"ok": false, "error"}.
func analyze(slot: String, turn: Dictionary, request: Dictionary) -> Dictionary:
	yield(get_tree(), "idle_frame")
	if usable().empty():
		return {"ok": false, "error": "no decision model is set up (Models tab, Decision core): add one with a model and an API key"}
	var cfg = settings()
	var think_ms = int(request.get("think_ms", cfg["think_ms"]))
	var limit = int(request.get("limit", Util.now_ms() + think_ms))
	var ctx = runtime.lookahead.context(slot, turn, cfg["max_options"])
	ctx["focus"] = str(request.get("focus", ""))
	ctx["opponent_style"] = str(request.get("opponent_style", ""))
	var state = _root_state(ctx)
	var names = _names(ctx)
	var candidates = request.get("candidates", [])
	var replies = request.get("replies", [])
	var mine = runtime.lookahead.live_options(ctx, slot)
	var theirs = runtime.lookahead.live_options(ctx, ctx["other"])
	var my_p = {}
	var their_p = {}
	var questions = {}
	if candidates.empty():
		questions["you"] = {"instructions": ("You are %s (%s) fighting %s in YOMI Hustle, a turn-based fighting game where both players "
			+ "lock in a move at the same time without seeing the other's. Pick your best move now.%s") % [names["you"], ctx["slot"], names["opponent"],
			_focus_text(ctx)], "options": _criteria(mine, ctx, slot)}
	if replies.empty() and theirs.size() > 1:
		questions["opponent"] = {"instructions": "Which move will the opponent, %s, most likely lock in now?%s" % [names["opponent"], _style_text(ctx)],
			"options": _criteria(theirs, ctx, ctx["other"])}
	if not questions.empty():
		var prior = yield(ask(state, questions, limit - int(min(think_ms, 10000))), "completed")
		if not prior["ok"]:
			return {"ok": false, "error": prior["error"]}
		if prior["answers"].has("you"):
			my_p = prior["answers"]["you"]["probabilities"]
			candidates = _top(mine, my_p, cfg["candidates"])
		if prior["answers"].has("opponent"):
			their_p = prior["answers"]["opponent"]["probabilities"]
			replies = _top(theirs, their_p, cfg["replies"])
	if replies.empty():
		replies = [theirs[0]]
	if their_p.empty():
		for reply in replies:
			their_p[reply["label"]] = 1.0 / replies.size()
	var deadline = int(min(Util.now_ms() + think_ms, limit))
	var depth = int(clamp(Util.as_int(request.get("depth", cfg["depth"])), 0, MAX_DEPTH))
	if not bool(runtime.config.get_value("simulation.enabled", true)):
		depth = 0
	var result = {"ok": true, "depth": depth, "replies": [], "lines_planned": 0, "lines_played": 0, "ranking": {}}
	for reply in replies:
		result["replies"].append({"option": reply, "p": float(their_p.get(reply["label"], 0.0))})
	if depth == 0:
		result["candidates"] = []
		for candidate in candidates:
			result["candidates"].append({"option": candidate, "prior": my_p.get(candidate["label"]), "replies": [], "lines": [], "text": candidate["description"], "score": 0.0})
		result["ranking"] = my_p
		return result
	var deep_lines = int(clamp(Util.as_int(request.get("lines", capacity())), 0, MAX_THREADS))
	var rank = bool(request.get("rank", true))
	var fixed = (1 if not questions.empty() else 0) + (1 if rank else 0)
	depth = depth_for_rate(depth, int(max(1, deep_lines)), rate_per_minute(), think_ms, _consumers(), fixed)
	result["depth"] = depth
	var lines = plan(candidates, replies, depth, deep_lines)
	# Leave time for the ranking request.
	var lines_deadline = deadline - (int(min(cfg["request_timeout_s"] * 1000.0, think_ms / 3.0)) if rank else 0)
	var results = yield(_run_lines(ctx, lines, lines_deadline), "completed")
	if runtime.matches.turn_for_token(ctx["token"]) == null:
		return {"ok": false, "error": "the turn ended while thinking"}
	for line_result in results:
		if line_result is Dictionary and line_result.get("ok", false):
			result["lines_played"] += 1
	result["lines_planned"] = lines.size()
	stats["lines"] += result["lines_played"]
	result["candidates"] = facts(candidates, replies, their_p, lines, results)
	for i in range(candidates.size()):
		if my_p.has(candidates[i]["label"]):
			result["candidates"][i]["prior"] = my_p[candidates[i]["label"]]
	if rank and candidates.size() > 1:
		var options = {}
		for entry in result["candidates"]:
			options[entry["option"]["label"]] = entry["text"]
		var final = yield(ask(state + "\nbudok played your candidate moves on the real game engine; each option says what happened.", {"move": {
			"instructions": ("Lock in one move for this turn. Damage you deal minus damage you take matters most; a KO for you is best and a KO "
				+ "against you is worst. The opponent's replies are guesses, weighted by how likely each one is.%s") % _focus_text(ctx),
			"options": options}}, deadline), "completed")
		if final["ok"]:
			result["ranking"] = final["answers"]["move"]["probabilities"]
		else:
			result["ranking_error"] = final["error"]
	return result


# Turns played with a decision model at the same time (they share the core).
func _consumers() -> int:
	var count = 0
	for slot in ["p1", "p2"]:
		count += 1 if runtime.matches.controllers.get(slot) in ["decision", "tandem"] or runtime.matches.owners.get(slot, "") != "" else 0
	return int(max(1, count))


static func _focus_text(ctx: Dictionary) -> String:
	return (" Your plan: %s." % ctx["focus"]) if str(ctx.get("focus", "")) != "" else ""


static func _style_text(ctx: Dictionary) -> String:
	return (" They play like this: %s." % ctx["opponent_style"]) if str(ctx.get("opponent_style", "")) != "" else ""


# Deep lines first (they take longest), spread over the candidates; then one
# short line for every other candidate/reply pair.
static func plan(candidates: Array, replies: Array, depth: int, deep_lines: int) -> Array:
	var lines = []
	var covered = {}
	if depth > 1:
		for t in range(deep_lines):
			var c = t % candidates.size()
			var r = int(t / candidates.size()) % replies.size()
			lines.append({"candidate": c, "reply": r, "depth": depth})
			covered["%d/%d" % [c, r]] = true
	for c in range(candidates.size()):
		for r in range(replies.size()):
			if not covered.has("%d/%d" % [c, r]):
				lines.append({"candidate": c, "reply": r, "depth": 1})
	for line in lines:
		line["root"] = {"candidate": candidates[line["candidate"]], "reply": replies[line["reply"]]}
	return lines


# Coroutine: runs `lines`, as many at once as the core has parallel requests.
func _run_lines(ctx: Dictionary, lines: Array, deadline: int) -> Array:
	yield(get_tree(), "idle_frame")
	var pool = {"next": 0, "done": 0, "results": []}
	for _line in lines:
		pool["results"].append(null)
	var workers = int(min(max(1, capacity()), lines.size()))
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
		var instructions = "Pick your best move now." + _focus_text(ctx)
		if not mine:
			instructions = "Which move will the opponent, %s, most likely lock in now?%s" % [names["opponent"], _style_text(ctx)]
		questions["you" if mine else "opponent"] = {"options": _criteria(info["options"][side], {}, side), "instructions": instructions}
	var reply = yield(ask(state, questions, info["deadline"], true), "completed")
	if not reply["ok"]:
		return {}
	var picks = {}
	for side in info["options"]:
		picks[side] = pick(info["options"][side], reply["answers"]["you" if side == ctx["slot"] else "opponent"]["probabilities"], "sample")
	return picks


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


# Per candidate: what the engine showed against each reply and in deep lines,
# as text for the model and a score (damage dealt minus taken, KOs count most).
static func facts(candidates: Array, replies: Array, their_p: Dictionary, lines: Array, results: Array) -> Array:
	var out = []
	for c in range(candidates.size()):
		var entry = {"option": candidates[c], "replies": [], "lines": []}
		var parts = [candidates[c]["description"]]
		var weighted = 0.0
		var weight = 0.0
		for i in range(lines.size()):
			var result = results[i]
			if lines[i]["candidate"] != c or not (result is Dictionary) or not result.get("ok", false):
				continue
			var reply = replies[lines[i]["reply"]]
			var p = float(their_p.get(reply["label"], 0.0))
			var first = result["first"]
			entry["replies"].append({"reply": reply["label"], "p": p, "dealt": first["dealt"], "taken": first["taken"],
				"next_turn": first.get("next_turn", ""), "ko": first["ko"]})
			parts.append("vs %s (%d%% likely): you deal %d, take %d%s%s" % [reply["label"], int(round(p * 100)), first["dealt"], first["taken"],
				", " + first["next_turn"] if first.has("next_turn") else "", _ko_text(first["ko"])])
			weighted += p * _value(first)
			weight += p
			if lines[i]["depth"] > 1:
				entry["lines"].append({"turns": result["turns"], "dealt": result["dealt"], "taken": result["taken"], "ko": result["ko"],
					"you": result["moves"]["you"], "opponent": result["moves"]["opponent"]})
		var score = weighted / weight if weight > 0.0 else 0.0
		if not entry["lines"].empty():
			var total = 0.0
			for line in entry["lines"]:
				parts.append("played on %d turns: you dealt %d, took %d%s (you: %s; opponent: %s)" % [line["turns"], line["dealt"], line["taken"],
					_ko_text(line["ko"]), PoolStringArray(line["you"]).join(", "), PoolStringArray(line["opponent"]).join(", ")])
				total += _value(line)
			score += total / entry["lines"].size()
		if parts.size() == 1:
			parts.append("not simulated (out of time)")
		entry["text"] = PoolStringArray(parts).join(". ")
		entry["score"] = score
		out.append(entry)
	return out


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


# One option: the likeliest ("best"), or drawn from the probabilities
# ("sample"), never one under SAMPLE_FLOOR of the likeliest.
func pick(options: Array, probabilities: Dictionary, mode: String) -> Dictionary:
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


# --- Tandem: look_ahead for chat models ---


static func look_ahead_properties() -> Dictionary:
	var move = {"description": "A move: its name (\"Slash\"), an option name from an earlier look_ahead (\"Jump up-fwd\"), or {action, data?, extra?}."}
	return {
		"moves": {"type": "array", "items": move, "maxItems": MAX_MOVES, "description": "Your candidate moves to compare (1-8). Omit to let the decision core pick its top candidates."},
		"opponent_moves": {"type": "array", "items": move, "maxItems": MAX_MOVES, "description": "Opponent replies to test each move against. Omit to use the core's prediction of their likeliest replies."},
		"depth": {"type": "integer", "minimum": 1, "maximum": MAX_DEPTH, "description": "Turns each deep line plays, counting this one (default from settings, 10)."},
		"lines": {"type": "integer", "minimum": 0, "maximum": MAX_THREADS, "description": "Deep lines to play (default: one per parallel request the core has)."},
		"focus": {"type": "string", "description": "Your plan, used when the core picks your moves inside the lines (e.g. \"go for a corner combo\", \"play safe, I am ahead\")."},
		"opponent_style": {"type": "string", "description": "How the opponent plays, used when the core picks their moves (e.g. \"aggressive, grabs a lot\")."},
	}


# Coroutine behind the look_ahead tool (in-game Tandem bots and MCP). args:
# {moves?, opponent_moves?, depth?, lines?, focus?, opponent_style?}; each move
# is an option label from an earlier look_ahead, a move name, or {action,
# data?, extra?}. Returns a compact summary for the chat model.
func look_ahead(slot: String, args: Dictionary, limit: int) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var turn = runtime.matches.turns.get(slot)
	if turn == null or turn.has("applied"):
		return {"ok": false, "error": "%s has no open turn; call it while choosing a move" % slot}
	var cfg = settings()
	var ctx = runtime.lookahead.context(slot, turn, cfg["max_options"])
	var request = {"rank": true, "limit": limit, "focus": str(args.get("focus", "")), "opponent_style": str(args.get("opponent_style", ""))}
	for key in ["depth", "lines"]:
		if args.has(key):
			request[key] = Util.as_int(args[key])
	for pair in [["moves", slot, "candidates"], ["opponent_moves", ctx["other"], "replies"]]:
		var wanted = args.get(pair[0])
		if wanted is Array and not wanted.empty():
			var resolved = resolve_moves(ctx, pair[1], wanted)
			if not resolved["ok"]:
				return {"ok": false, "error": "%s: %s" % [pair[0], resolved["error"]]}
			request[pair[2]] = resolved["options"]
	var analysis = yield(analyze(slot, turn, request), "completed")
	if not analysis["ok"]:
		return analysis
	return summarize(analysis)


# Options for moves a chat model named. Returns {"ok", "options"} or {"ok": false, "error"}.
func resolve_moves(ctx: Dictionary, side: String, wanted: Array) -> Dictionary:
	var available = runtime.lookahead.live_options(ctx, side)
	var catalog = ctx["catalogs"].get(side, {})
	var out = []
	for item in wanted.slice(0, MAX_MOVES - 1):
		var found = null
		var name = str(item.get("action", "")) if item is Dictionary else str(item)
		if item is Dictionary and item.get("data") != null:
			var spec = catalog.get("specs", {}).get(name)
			if spec == null:
				return {"ok": false, "error": "%s is not legal for %s right now" % [name, side]}
			var forward = Util.as_int(Util.call_or(Util.prop(runtime.matches.game, side, null), "get_opponent_dir", [], 1), 1)
			var coerced = PayloadSpec.coerce(SimTurns.facing_spec(spec, forward, ctx["sides"][side]["live_facing"]), item["data"], null)
			if not coerced["ok"]:
				return {"ok": false, "error": "%s data: %s" % [name, coerced["error"]]}
			found = {"label": "%s %s" % [name, Util.truncate(Util.json_str(item["data"]), 40)], "action": name, "input": item["data"],
				"di": item.get("extra", {}).get("di") if item.get("extra") is Dictionary else null, "description": SimTurns.describe_state(Util.prop(runtime.matches.game, side, null), name)}
		else:
			for option in available:
				if option["label"].to_lower() == name.to_lower():
					found = option
					break
			if found == null:
				for option in available:
					if option["action"].to_lower() == name.to_lower():
						found = option
						break
		if found == null:
			var legal = []
			for option in available:
				if not (option["action"] in legal):
					legal.append(option["action"])
			return {"ok": false, "error": "%s is not a legal move for %s right now; legal: %s" % [name, side, PoolStringArray(legal).join(", ")]}
		out.append(found)
	return {"ok": true, "options": out}


# The analysis as the chat model sees it: short lines per move, the decision
# model's ranking and the options the next call can name.
static func summarize(analysis: Dictionary) -> Dictionary:
	var moves = []
	for entry in analysis["candidates"]:
		var item = {"move": entry["option"]["label"], "score": int(round(entry["score"]))}
		if entry["option"]["input"] != null:
			item["data"] = entry["option"]["input"]
		if entry.get("prior") != null:
			item["decision_model_first_guess"] = "%d%%" % int(round(float(entry["prior"]) * 100))
		if analysis["ranking"].has(entry["option"]["label"]):
			item["decision_model_pick"] = "%d%%" % int(round(float(analysis["ranking"][entry["option"]["label"]]) * 100))
		var vs = []
		for reply in entry["replies"]:
			vs.append("vs %s (%d%%): deal %d, take %d%s%s" % [reply["reply"], int(round(reply["p"] * 100)), reply["dealt"], reply["taken"],
				", " + reply["next_turn"] if reply["next_turn"] != "" else "", _ko_text(reply["ko"])])
		item["next_turn"] = vs
		var deep = []
		for line in entry["lines"]:
			deep.append("%d turns: dealt %d, took %d%s; you %s / them %s" % [line["turns"], line["dealt"], line["taken"], _ko_text(line["ko"]),
				PoolStringArray(line["you"]).join(">"), PoolStringArray(line["opponent"]).join(">")])
		if not deep.empty():
			item["lines"] = deep
		moves.append(item)
	var replies = []
	for reply in analysis["replies"]:
		replies.append("%s (%d%%)" % [reply["option"]["label"], int(round(reply["p"] * 100))])
	var out = {"ok": true, "depth": analysis["depth"], "lines_played": "%d of %d" % [analysis["lines_played"], analysis["lines_planned"]],
		"opponent_replies_tested": replies, "moves": moves,
		"how_to_read": "score = damage dealt minus taken (KO = 1000), averaged over the replies (weighted) plus the deep lines. Name moves exactly as listed to look again or submit."}
	var best = ""
	for label in analysis["ranking"]:
		if best == "" or analysis["ranking"][label] > analysis["ranking"][best]:
			best = label
	if best != "":
		out["decision_model_recommends"] = best
	if analysis.has("ranking_error"):
		out["note"] = "no ranking: " + str(analysis["ranking_error"])
	return out

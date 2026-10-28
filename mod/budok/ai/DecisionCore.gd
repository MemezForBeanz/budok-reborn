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
#   1. unless the caller named them, one request ranks your moves and guesses
#      the opponent's move (two questions, one request); your defensive moves
#      (blocks, dodges) join the candidates;
#   2. the sweep: every candidate is played on the real engine against every
#      reply the opponent has (each move and its aim, strength and direction
#      variants) up to the next decision point, likeliest replies first. No
#      model is needed for this, so it works without one when moves are named;
#   3. deep lines (one per parallel request the core has) start from the best
#      candidates against their likeliest and their worst reply, and keep
#      playing for `depth` turns, the models choosing both fighters' moves;
#   4. optionally, a last request ranks the candidates, each described with
#      what the engine showed (average, worst case, likeliest replies, lines).

const Util = preload("res://budok/core/Util.gd")
const Observation = preload("res://budok/core/Observation.gd")
const SimTurns = preload("res://budok/core/SimTurns.gd")
const PayloadSpec = preload("res://budok/core/PayloadSpec.gd")
const Lookahead = preload("res://budok/core/Lookahead.gd")
const PROVIDERS := ["typesafe", "vercel"]
const MINUTE_MS := 60000
const MAX_DEPTH := 30
const MAX_THREADS := 32
const MAX_MOVES := 8
const KO_VALUE := 1000
const NOTE_CHARS := 140
# Defensive moves added to the candidates, and line steps shown per line.
const MAX_DEFENSES := 4
const STEPS_SHOWN := 6
# Options below this share of the likeliest one are never drawn.
const SAMPLE_FLOOR := 0.1
# How long an endpoint sits out after an error: a rejected key (401/403), else.
const BAD_KEY_PAUSE_MS := 300000
const ERROR_PAUSE_MS := 10000
const LOOK_AHEAD_HELP := ("Play this turn ahead on the real game engine. First it plays each of your candidate moves against EVERY legal "
	+ "opponent reply (each move and its aim, strength and direction variants) up to the next decision point, and reports per move the average "
	+ "(weighted by how likely each reply is), the worst case with the reply that causes it, and the likeliest and most dangerous replies. Your "
	+ "defensive moves (block, low block, dodges) are added unless defenses is false. Then, with a decision model set up, it plays the best moves "
	+ "several turns deeper with the models choosing both fighters' moves. Every move and line step comes as action, data and extra exactly as "
	+ "submit_action takes them; start shows the position the runs start from. Name your candidates in moves (or omit them and the decision "
	+ "core picks its top ones). It never reveals the opponent's real choice. You still decide: call submit_action afterwards.")

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
# "lines"?, "focus"?, "opponent_style"?, "defenses"? (add your defensive
# moves; default true), "rank": bool, "think_ms"?, "limit" (absolute ms the
# whole analysis must end by)}. Returns {"ok", "candidates": [entry (see
# facts) + "lines", "prior"?, "added"?, "text"], "replies": [{"option", "p"}],
# "replies_named", "ranking": {label: p}, "depth", "lines_planned",
# "lines_played", "start" (the live match where every run starts), "sweep":
# {"pairs", "played", "check"}, "notes": [text]} or {"ok": false, "error"}.
# The previews it used are freed when it ends.
func analyze(slot: String, turn: Dictionary, request: Dictionary) -> Dictionary:
	var result = yield(_analyze(slot, turn, request), "completed")
	runtime.simulator.release_pool()
	return result


func _analyze(slot: String, turn: Dictionary, request: Dictionary) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var model = not usable().empty()
	var cfg = settings()
	var think_ms = int(request.get("think_ms", cfg["think_ms"]))
	var limit = int(request.get("limit", Util.now_ms() + think_ms))
	var deadline = int(min(Util.now_ms() + think_ms, limit))
	var ctx = runtime.lookahead.context(slot, turn, cfg["max_options"])
	ctx["focus"] = str(request.get("focus", ""))
	ctx["opponent_style"] = str(request.get("opponent_style", ""))
	var names = _names(ctx)
	var notes = []
	var candidates = request.get("candidates", []).duplicate()
	var named_replies = request.get("replies", [])
	var mine = runtime.lookahead.live_options(ctx, slot)
	var theirs = runtime.lookahead.live_options(ctx, ctx["other"])
	if candidates.empty() and not model:
		return {"ok": false, "error": "name the moves to compare (moves), or set up a decision model to pick them (budok settings: Models tab, Decision core)"}
	# The models choose among the first options (each move as it stands, then
	# variants) and guess the opponent's move, not its aim or strength.
	var asked = mine.slice(0, cfg["max_options"] - 1) if mine.size() > cfg["max_options"] else mine
	var my_p = {}
	var move_p = {}
	var questions = {}
	if candidates.empty():
		questions["you"] = {"instructions": ("You are %s (%s) fighting %s in YOMI Hustle, a turn-based fighting game where both players "
			+ "lock in a move at the same time without seeing the other's. Pick your best move now.%s") % [names["you"], ctx["slot"], names["opponent"],
			_focus_text(ctx)], "options": _criteria(asked, ctx, slot)}
	if named_replies.empty() and model and theirs.size() > 1:
		questions["opponent"] = {"instructions": "Which move will the opponent, %s, most likely lock in now?%s" % [names["opponent"], _style_text(ctx)],
			"options": _move_criteria(theirs, ctx, ctx["other"])}
	var state = _root_state(ctx) if model else ""
	if not questions.empty():
		var prior = yield(ask(state, questions, limit - int(min(think_ms, 10000))), "completed")
		if prior["ok"]:
			my_p = prior["answers"].get("you", {}).get("probabilities", {})
			move_p = prior["answers"].get("opponent", {}).get("probabilities", {})
		elif candidates.empty():
			return {"ok": false, "error": prior["error"]}
		else:
			notes.append("no guess of the opponent's move (%s), so every move of theirs counts the same" % prior["error"])
	if candidates.empty():
		candidates = _top(asked, my_p, cfg["candidates"])
	var added = _defenses(ctx, slot, mine, candidates) if bool(request.get("defenses", true)) else []
	candidates += added
	var replies = named_replies if not named_replies.empty() else theirs
	var weights = reply_weights(replies, move_p, not named_replies.empty())
	var depth = int(clamp(Util.as_int(request.get("depth", cfg["depth"])), 0, MAX_DEPTH))
	if not bool(runtime.config.get_value("simulation.enabled", true)):
		depth = 0
	var result = {"ok": true, "depth": depth, "replies": [], "replies_named": not named_replies.empty(), "ranking": {}, "lines_planned": 0,
		"lines_played": 0, "notes": notes, "start": runtime.lookahead.root_state(ctx), "sweep": {"pairs": 0, "played": 0, "check": {}}}
	for i in range(replies.size()):
		result["replies"].append({"option": replies[i], "p": weights[i]})
	if depth == 0:
		result["candidates"] = []
		for candidate in candidates:
			result["candidates"].append({"option": candidate, "prior": my_p.get(candidate["label"]), "replies": [], "lines": [], "tested": 0,
				"average": 0.0, "worst": {}, "best": {}, "text": candidate["description"], "score": 0.0})
		result["ranking"] = my_p
		return result
	var deep = int(clamp(Util.as_int(request.get("lines", capacity())), 0, MAX_THREADS)) if model and depth > 1 else 0
	if depth > 1 and not model:
		notes.append("only the next exchange was played: deeper lines need a decision model to pick both fighters' moves (Models tab, Decision core)")
	if deep == 0:
		depth = 1
	var rank = model and bool(request.get("rank", true)) and candidates.size() > 1
	if deep > 0:
		var fitted = depth_for_rate(depth, deep, rate_per_minute(), think_ms, _consumers(), (1 if not questions.empty() else 0) + (1 if rank else 0))
		if fitted < depth:
			notes.append("deep lines play %d turns, not %d, to stay within the decision models' rate limit" % [fitted, depth])
			depth = fitted
	result["depth"] = depth
	# Time: the sweep first, with up to two thirds of it (covering the next
	# exchange fully matters most, and it decides which lines go deep), then
	# the deep lines, then the ranking request.
	var lines_deadline = deadline - (int(min(cfg["request_timeout_s"] * 1000.0, think_ms / 6.0)) if rank else 0)
	var sweep_deadline = lines_deadline - (int((lines_deadline - Util.now_ms()) / 3) if deep > 0 and depth > 1 else 0)
	var order = sweep_order(candidates.size(), weights)
	var swept = yield(runtime.lookahead.sweep(ctx, candidates, replies, order, sweep_deadline), "completed")
	if runtime.matches.turn_for_token(ctx["token"]) == null:
		return {"ok": false, "error": "the turn ended while thinking"}
	if swept["played"] == 0 and swept.has("error"):
		return {"ok": false, "error": swept["error"]}
	result["sweep"] = {"pairs": order.size(), "played": swept["played"], "check": swept["check"]}
	result["candidates"] = facts(candidates, replies, weights, swept["results"])
	for i in range(candidates.size()):
		if my_p.has(candidates[i]["label"]):
			result["candidates"][i]["prior"] = my_p[candidates[i]["label"]]
		if candidates[i] in added:
			result["candidates"][i]["added"] = "defense"
	if deep > 0 and depth > 1:
		var lines = deep_plan(result["candidates"], replies, weights, deep, depth)
		var results = yield(_run_lines(ctx, lines, lines_deadline), "completed")
		if runtime.matches.turn_for_token(ctx["token"]) == null:
			return {"ok": false, "error": "the turn ended while thinking"}
		_add_lines(result, lines, results)
	stats["lines"] += result["lines_played"]
	for entry in result["candidates"]:
		entry["text"] = _evidence(entry, replies)
	if rank:
		var options = {}
		for entry in result["candidates"]:
			options[entry["option"]["label"]] = entry["text"]
		var final = yield(ask(state + "\nbudok played your candidate moves on the real game engine; each option says what happened.", {"move": {
			"instructions": ("Lock in one move for this turn. Damage you deal minus damage you take matters most; a KO for you is best and a KO "
				+ "against you is worst. Each move was played against every reply the opponent has; their likeliest replies are guesses, "
				+ "so a move whose worst case is a heavy loss is risky even when its average is good.%s") % _focus_text(ctx),
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


# Your defensive options (blocks, dodges, bursts: noted as defense, or of the
# game's Defense type when there are no notes) that are not candidates yet,
# each move as it stands first, then variants such as a low block.
func _defenses(ctx: Dictionary, slot: String, options: Array, candidates: Array) -> Array:
	var info = ctx["infos"].get(slot, {})
	var fighter = Util.prop(runtime.matches.game, slot, null)
	var labels = []
	for candidate in candidates:
		labels.append(candidate["label"])
	var out = []
	for option in options:
		if out.size() >= MAX_DEFENSES:
			break
		if option["label"] in labels or option["action"] == "Continue":
			continue
		var category = str(runtime.schemas.move_notes(info, option["action"]).get("category", "")) if not info.empty() else ""
		if category == "defense" or (category == "" and SimTurns.describe_state(fighter, option["action"]).ends_with("(Defense)")):
			out.append(option)
	return out


# Each reply's probability, summing to 1. uniform: the same for each (replies
# someone named); else the guess for its move (move_p, by action), shared
# among that move's variants since the models guess moves, not aims; with no
# guess, every move counts the same.
static func reply_weights(replies: Array, move_p: Dictionary, uniform: bool) -> Array:
	var variants = {}
	for reply in replies:
		variants[reply["action"]] = variants.get(reply["action"], 0) + 1
	var weights = []
	var total = 0.0
	for reply in replies:
		var p = 1.0
		if not uniform:
			p = (float(move_p.get(reply["action"], 0.0)) if not move_p.empty() else 1.0) / variants[reply["action"]]
		weights.append(p)
		total += p
	for i in range(weights.size()):
		weights[i] = weights[i] / total if total > 0.0 else 1.0 / weights.size()
	return weights


# Sweep pairs, likeliest replies first, each against every candidate: when
# time runs out, every candidate has met the same replies.
static func sweep_order(candidate_count: int, weights: Array) -> Array:
	var order = []
	for r in _ranked(weights):
		for c in range(candidate_count):
			order.append([c, r])
	return order


# Indices of `values`, largest first (ties keep their order).
static func _ranked(values: Array) -> Array:
	var out = []
	for i in range(values.size()):
		var at = out.size()
		while at > 0 and values[out[at - 1]] < values[i]:
			at -= 1
		out.insert(at, i)
	return out


# Per candidate, what the sweep showed: {"option", "replies": [{"index", "p",
# "value", "outcome"}] (each reply played), "tested", "average" (weighted by
# how likely each reply is), "worst" and "best" (one of the replies, {} when
# none was played), "score", "lines": []}. value: damage dealt minus taken,
# a KO counting KO_VALUE.
static func facts(candidates: Array, replies: Array, weights: Array, results: Array) -> Array:
	var out = []
	for c in range(candidates.size()):
		var entry = {"option": candidates[c], "replies": [], "lines": [], "tested": 0, "average": 0.0, "worst": {}, "best": {}}
		var weighted = 0.0
		var weight = 0.0
		for r in range(replies.size()):
			var outcome = results[c][r] if c < results.size() else null
			if outcome == null:
				continue
			var item = {"index": r, "p": weights[r], "value": _value(outcome), "outcome": outcome}
			entry["replies"].append(item)
			weighted += weights[r] * item["value"]
			weight += weights[r]
			if entry["worst"].empty() or item["value"] < entry["worst"]["value"] or (item["value"] == entry["worst"]["value"] and item["p"] > entry["worst"]["p"]):
				entry["worst"] = item
			if entry["best"].empty() or item["value"] > entry["best"]["value"] or (item["value"] == entry["best"]["value"] and item["p"] > entry["best"]["p"]):
				entry["best"] = item
		entry["tested"] = entry["replies"].size()
		entry["average"] = weighted / weight if weight > 0.0 else 0.0
		entry["score"] = entry["average"]
		out.append(entry)
	return out


# Deep lines for the candidates that did best in the sweep, each against the
# reply it is likeliest to meet and the one that hurt it most. With more lines
# than such pairs, the best pairs get another (lines differ: the models' picks
# are drawn from their probabilities).
static func deep_plan(entries: Array, replies: Array, weights: Array, count: int, depth: int) -> Array:
	var scores = []
	for entry in entries:
		scores.append(entry["score"])
	var likely = _ranked(weights)[0] if not weights.empty() else -1
	var pairs = []
	var seen = {}
	for c in _ranked(scores):
		for r in [likely, entries[c]["worst"].get("index", -1)]:
			if r >= 0 and not seen.has("%d/%d" % [c, r]):
				seen["%d/%d" % [c, r]] = true
				pairs.append([c, r])
	var lines = []
	for t in range(count if not pairs.empty() else 0):
		var pair = pairs[t % pairs.size()]
		lines.append({"candidate": pair[0], "reply": pair[1], "depth": depth, "root": {"candidate": entries[pair[0]]["option"], "reply": replies[pair[1]]}})
	return lines


# Deep lines into their candidates' entries; their average value joins the
# score, and lines that never ran are explained.
func _add_lines(result: Dictionary, lines: Array, results: Array) -> void:
	result["lines_planned"] = lines.size()
	var not_started = 0
	var failed = []
	for i in range(lines.size()):
		var line = results[i]
		if line == null:
			not_started += 1
		elif not line.get("ok", false):
			failed.append(str(line.get("error", "")))
		else:
			result["lines_played"] += 1
			var view = {"reply": lines[i]["reply"], "turns": line["turns"], "dealt": line["dealt"], "taken": line["taken"], "ko": line["ko"],
				"stop": line["stop"], "steps": line["steps"]}
			if line.has("stop_detail"):
				view["stop_detail"] = line["stop_detail"]
			result["candidates"][lines[i]["candidate"]]["lines"].append(view)
	if not_started > 0:
		result["notes"].append("%d of %d deep lines did not start: out of thinking time (ai.core.think_s)" % [not_started, lines.size()])
	if not failed.empty():
		result["notes"].append("%d deep lines failed: %s" % [failed.size(), failed[0]])
	for entry in result["candidates"]:
		if not entry["lines"].empty():
			var total = 0.0
			for line in entry["lines"]:
				total += _value(line)
			entry["score"] += total / entry["lines"].size()


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
# Returns {"error"} when the model gave no answer.
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
		return {"error": str(reply.get("error", "no answer"))}
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


# {move name: description}, one per move (its variants share it).
func _move_criteria(options: Array, ctx: Dictionary, side: String) -> Dictionary:
	var firsts = []
	var seen = {}
	for option in options:
		if not seen.has(option["action"]):
			seen[option["action"]] = true
			var first = option.duplicate()
			first["label"] = option["action"]
			firsts.append(first)
	return _criteria(firsts, ctx, side)


# What the engine showed for one candidate, as text for the ranking request.
static func _evidence(entry: Dictionary, replies: Array) -> String:
	var parts = [entry["option"]["description"]]
	if entry["tested"] == 0:
		parts.append("not simulated (out of time)")
		return PoolStringArray(parts).join(". ")
	parts.append("against %d replies: average %+d (damage dealt minus taken)" % [entry["tested"], int(round(entry["average"]))])
	parts.append("worst " + _reply_text(entry["worst"], replies))
	var likely = _likely(entry, 3)
	var texts = []
	for item in likely:
		texts.append(_reply_text(item, replies))
	parts.append("likeliest: " + PoolStringArray(texts).join("; "))
	for line in entry["lines"]:
		parts.append("played %d turns vs %s: you dealt %d, took %d%s" % [line["turns"], replies[line["reply"]]["label"], line["dealt"], line["taken"], _ko_text(line["ko"])])
	return PoolStringArray(parts).join(". ")


# The n likeliest replies an entry was played against.
static func _likely(entry: Dictionary, n: int) -> Array:
	var ps = []
	for item in entry["replies"]:
		ps.append(item["p"])
	var out = []
	for i in _ranked(ps).slice(0, n - 1) if not ps.empty() else []:
		out.append(entry["replies"][i])
	return out


# "vs Grab (5%): take 120, they act first"
static func _reply_text(item: Dictionary, replies: Array) -> String:
	return "vs %s (%s): %s" % [replies[item["index"]]["label"], _percent(item["p"]), _result_text(item["outcome"])]


static func _result_text(outcome: Dictionary) -> String:
	var parts = []
	if outcome["dealt"] != 0 or outcome["taken"] == 0:
		parts.append("deal %d" % outcome["dealt"])
	if outcome["taken"] != 0 or outcome["dealt"] == 0:
		parts.append("take %d" % outcome["taken"])
	if outcome.get("next_turn", "") != "":
		parts.append(outcome["next_turn"])
	elif outcome.get("stop", "") == "stuck":
		parts.append("no decision point within the tick limit")
	return PoolStringArray(parts).join(", ") + _ko_text(outcome["ko"])


static func _percent(p: float) -> String:
	return "%d%%" % int(round(p * 100)) if p >= 0.005 else "<1%"


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
	var move = {"description": "A move: its name (\"Slash\"), an option name from an earlier look_ahead (\"Jump up-fwd\"), or {action, data?, extra?} as submit_action takes it."}
	return {
		"moves": {"type": "array", "items": move, "maxItems": MAX_MOVES, "description": "Your candidate moves to compare (1-8). Omit to let the decision core pick its top candidates (needs a decision model)."},
		"opponent_moves": {"type": "array", "items": move, "maxItems": MAX_MOVES, "description": "Only test these opponent replies. Omit to test every legal reply and its aim, strength and direction variants."},
		"defenses": {"type": "boolean", "description": "Also test your defensive moves (block, low block, dodges, burst) against every reply (default true)."},
		"depth": {"type": "integer", "minimum": 1, "maximum": MAX_DEPTH, "description": "Turns each deep line plays, counting this one (default from settings, 10). 1 = the next exchange only."},
		"lines": {"type": "integer", "minimum": 0, "maximum": MAX_THREADS, "description": "Deep lines to play (default: one per parallel request the core has)."},
		"focus": {"type": "string", "description": "Your plan, used when the core picks your moves inside the lines (e.g. \"go for a corner combo\", \"play safe, I am ahead\")."},
		"opponent_style": {"type": "string", "description": "How the opponent plays, used when the core picks their moves (e.g. \"aggressive, grabs a lot\")."},
		"detail": {"type": "string", "enum": ["summary", "full"], "description": "full: every reply's result for every move and every step of the deep lines (long)."},
	}


# Coroutine behind the look_ahead tool (in-game Tandem bots and MCP). args:
# {moves?, opponent_moves?, defenses?, depth?, lines?, focus?, opponent_style?,
# detail?}; each move is an option label from an earlier look_ahead, a move
# name, or {action, data?, extra?}. Returns a compact summary for the chat model.
func look_ahead(slot: String, args: Dictionary, limit: int) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var turn = runtime.matches.turns.get(slot)
	if turn == null or turn.has("applied"):
		return {"ok": false, "error": "%s has no open turn; call it while choosing a move" % slot}
	var cfg = settings()
	var ctx = runtime.lookahead.context(slot, turn, cfg["max_options"])
	var request = {"rank": true, "limit": limit, "focus": str(args.get("focus", "")), "opponent_style": str(args.get("opponent_style", "")),
		"defenses": bool(args.get("defenses", true))}
	for key in ["depth", "lines"]:
		if args.has(key):
			request[key] = Util.as_int(args[key])
	var notes = []
	for pair in [["moves", slot, "candidates"], ["opponent_moves", ctx["other"], "replies"]]:
		var wanted = args.get(pair[0])
		if wanted is Array and not wanted.empty():
			var resolved = resolve_moves(ctx, pair[1], wanted)
			if not resolved["ok"]:
				return {"ok": false, "error": "%s: %s" % [pair[0], resolved["error"]]}
			request[pair[2]] = resolved["options"]
			for note in resolved["notes"]:
				notes.append("%s: %s" % [pair[0], note])
	var analysis = yield(analyze(slot, turn, request), "completed")
	if not analysis["ok"]:
		return analysis
	analysis["notes"] = notes + analysis["notes"]
	return summarize(analysis, str(args.get("detail", "summary")))


# Options for moves a chat model named. Returns {"ok", "options", "notes"
# (data the move's limits changed)} or {"ok": false, "error"}.
func resolve_moves(ctx: Dictionary, side: String, wanted: Array) -> Dictionary:
	var available = runtime.lookahead.live_options(ctx, side)
	var catalog = ctx["catalogs"].get(side, {})
	var out = []
	var notes = []
	for item in wanted.slice(0, MAX_MOVES - 1):
		var found = null
		var name = str(item.get("action", "")) if item is Dictionary else str(item)
		if item is Dictionary and (item.get("data") != null or item.get("extra") is Dictionary):
			var spec = catalog.get("specs", {}).get(name)
			if spec == null:
				return {"ok": false, "error": "%s is not legal for %s right now" % [name, side]}
			var forward = Util.as_int(Util.call_or(Util.prop(runtime.matches.game, side, null), "get_opponent_dir", [], 1), 1)
			var coerced = PayloadSpec.coerce(SimTurns.facing_spec(spec, forward, ctx["sides"][side]["live_facing"]), item.get("data"), null)
			if not coerced["ok"]:
				return {"ok": false, "error": "%s data: %s" % [name, coerced["error"]]}
			if coerced.has("note"):
				notes.append("%s data: %s" % [name, coerced["note"]])
			var extra = item.get("extra") if item.get("extra") is Dictionary else {}
			var di = extra.get("di", extra.get("DI"))
			found = {"label": name if item.get("data") == null else "%s %s" % [name, Util.truncate(Util.json_str(item["data"]), 40)], "action": name,
				"input": item.get("data"), "di": di if di is Dictionary else null,
				"description": SimTurns.describe_state(Util.prop(runtime.matches.game, side, null), name)}
			# The same move an earlier look_ahead listed keeps its name.
			for option in available:
				if Util.json_str(Lookahead._move_key(option)) == Util.json_str(Lookahead._move_key(found)):
					found = option
					break
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
	return {"ok": true, "options": out, "notes": notes}


# The analysis as the chat model sees it: where the runs start, how much was
# covered, and per move what to submit, its average and worst case over the
# replies, the likeliest and most dangerous replies, and the deep lines with
# every step as submit_action takes it. detail "full" adds every reply.
static func summarize(analysis: Dictionary, detail: String = "summary") -> Dictionary:
	var full = detail == "full"
	var replies = []
	for reply in analysis["replies"]:
		replies.append(reply["option"])
	var moves = []
	for entry in analysis["candidates"]:
		var item = {"move": entry["option"]["label"]}
		var action = Lookahead.action_of(entry["option"])
		for key in action:
			item[key] = action[key]
		if not entry["replies"].empty():
			var played = entry["replies"][0]["outcome"]["step"].get("you", {})
			if played.get("engine_data") != null and Util.json_str(played["engine_data"]) != Util.json_str(action.get("data")):
				item["engine_data"] = played["engine_data"]
			if played.has("note"):
				item["note"] = played["note"]
		if entry.has("added"):
			item["added"] = "defense: not one of the moves you named or the core picked"
		if entry["tested"] > 0:
			item["average"] = int(round(entry["average"]))
			item["worst"] = {"reply": replies[entry["worst"]["index"]]["label"], "p": _percent(entry["worst"]["p"]),
				"result": _result_text(entry["worst"]["outcome"]), "reply_action": Lookahead.action_of(replies[entry["worst"]["index"]])}
			item["best"] = _reply_text(entry["best"], replies)
			var likely = []
			for reply in _likely(entry, 3):
				likely.append(_reply_text(reply, replies))
			item["likely"] = likely
			var dangerous = []
			for reply in _dangerous(entry, 3):
				dangerous.append(_reply_text(reply, replies))
			if not dangerous.empty():
				item["dangerous"] = dangerous
			if entry["tested"] < replies.size():
				item["tested_against"] = "%d of %d replies" % [entry["tested"], replies.size()]
			if full:
				var all = []
				for reply in _likely(entry, entry["replies"].size()):
					all.append(_reply_text(reply, replies))
				item["replies"] = all
		else:
			item["not_simulated"] = "out of thinking time before this move was played"
		item["score"] = int(round(entry["score"]))
		if entry.get("prior") != null:
			item["decision_model_first_guess"] = _percent(float(entry["prior"]))
		if analysis["ranking"].has(entry["option"]["label"]):
			item["decision_model_pick"] = _percent(float(analysis["ranking"][entry["option"]["label"]]))
		var lines = []
		for line in entry["lines"]:
			lines.append(_line_view(line, replies, analysis["depth"], full))
		if not lines.empty():
			item["lines"] = lines
		moves.append(item)
	var start = analysis["start"].duplicate()
	start["preview"] = "matches the live match" if analysis["sweep"]["check"].empty() else {"differs_from_live": analysis["sweep"]["check"]}
	var out = {"ok": true, "start": start, "coverage": _coverage(analysis, replies), "depth": analysis["depth"], "moves": moves,
		"how_to_read": ("Each move was played on the real engine against the opponent's replies up to the next decision point. average: damage dealt "
			+ "minus taken (a KO counts 1000) weighted by how likely each reply is; worst: the reply that hurts that move most; lines: deeper "
			+ "imagined play with the decision models picking both sides, each step as submit_action takes it. score = average plus the deep lines. "
			+ "Submit a move with its action, data and extra exactly as listed.")}
	if analysis["lines_planned"] > 0:
		out["lines_played"] = "%d of %d" % [analysis["lines_played"], analysis["lines_planned"]]
	var best = ""
	for label in analysis["ranking"]:
		if best == "" or analysis["ranking"][label] > analysis["ranking"][best]:
			best = label
	if best != "":
		out["decision_model_recommends"] = best
	var notes = analysis["notes"].duplicate()
	if analysis.has("ranking_error"):
		notes.append("no ranking from the decision models: " + str(analysis["ranking_error"]))
	if not notes.empty():
		out["notes"] = notes
	return out


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


# Replies that cost the entry damage or a KO, worst first.
static func _dangerous(entry: Dictionary, n: int) -> Array:
	var losses = []
	var values = []
	for item in entry["replies"]:
		if item["value"] < 0:
			losses.append(item)
			values.append(-item["value"])
	var out = []
	for i in _ranked(values).slice(0, n - 1) if not values.empty() else []:
		out.append(losses[i])
	return out


static func _line_view(line: Dictionary, replies: Array, depth: int, full: bool) -> Dictionary:
	var out = {"vs": replies[line["reply"]]["label"], "turns": line["turns"],
		"result": "dealt %d, took %d%s" % [line["dealt"], line["taken"], _ko_text(line["ko"])],
		"stopped": stop_text(line["stop"], line.get("stop_detail", ""), line["turns"], depth)}
	var steps = []
	for step in line["steps"] if full else line["steps"].slice(0, STEPS_SHOWN - 1):
		steps.append({"you": _step_view(step.get("you")), "opponent": _step_view(step.get("opponent"))})
	out["steps"] = steps
	if steps.size() < line["steps"].size():
		out["more_steps"] = "%d more turns (detail: full shows them)" % (line["steps"].size() - steps.size())
	return out


# One fighter's move in a line, as submit_action takes it, plus what the
# engine got when that differs.
static func _step_view(played):
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

extends Node

# Provider-neutral tool-calling chat and decision-model calls over raw HTTPS
# (Godot HTTPRequest).
#   anthropic                    - Messages API (/v1/messages)
#   openai / openrouter / local  - OpenAI-compatible /chat/completions
#   vercel                       - AI Gateway decision models (/decision-model)
#   typesafe                     - TypeSafe's API for Jev (/v1/systemone)
# Each role (ai.play, ai.annotate, ai.decide) picks its own provider, model and limits.
#
# chat() is a coroutine returning:
#   {"ok", "provider", "assistant": <message to append verbatim>, "text",
#    "tool_calls": [{"id", "name", "input"}], "stop_reason", "usage", "error"?}
# decide() is a coroutine returning:
#   {"ok", "answers": {name: {"choice", "probabilities": {label: p}}}, "usage", "error"?}

const Util = preload("res://budok/core/Util.gd")
const ANTHROPIC_VERSION := "2026-10-21"
const FALLBACK_BETA := "server-side-fallback-2026-07-01"
# Models that accept server-side refusal fallbacks ("default" routing) on the Claude API.
const FALLBACK_MODELS := ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
const RETRY_CODES := [408, 429, 500, 502, 503, 504, 529]
const MAX_ATTEMPTS := 3
const DECISION_PROVIDERS := ["vercel", "typesafe"]
# Headers the AI SDK's gateway provider sends (@ai-sdk/gateway).
const GATEWAY_PROTOCOL_VERSION := "0.0.1"
const DECISION_SPEC_VERSION := "4"

var config = null


func setup(config_ref) -> void:
	config = config_ref


func describe_role(role: String) -> Dictionary:
	var cfg = config.get_value("ai." + role, {})
	var provider = str(cfg.get("provider", "vercel" if role == "decide" else "anthropic"))
	return {
		"provider": provider,
		"model": str(cfg.get("model", "")),
		"has_key": provider == "local" or config.api_key(provider) != "",
	}


func chat(role: String, system: String, messages: Array, tools: Array) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var cfg = config.get_value("ai." + role, {})
	var provider = str(cfg.get("provider", "anthropic"))
	var key = config.api_key(provider)
	if key == "" and provider != "local":
		return {"ok": false, "error": "no API key for provider '%s': set it in the budok panel (F8) or the %s environment variable" % [
			provider, config.get_value("ai.providers.%s.api_key_env" % provider, "?")]}
	var request = _anthropic_request(cfg, key, system, messages, tools) if provider == "anthropic" else _openai_request(provider, cfg, key, system, messages, tools)
	var response = {}
	for attempt in range(MAX_ATTEMPTS):
		response = yield(_send(request["url"], request["headers"], Util.json_str(request["body"]), float(cfg.get("request_timeout_s", 180))), "completed")
		if response["ok"] or not (int(response.get("status", 0)) in RETRY_CODES) or attempt == MAX_ATTEMPTS - 1:
			break
		yield(get_tree().create_timer(2.0 * pow(2, attempt)), "timeout")
	if not response["ok"]:
		return {"ok": false, "provider": provider, "error": response["error"]}
	return _parse_anthropic(response["json"]) if provider == "anthropic" else _parse_openai(response["json"])


# Coroutine: one call to a decision model (ai.<role>, provider vercel or
# typesafe). It answers every question at once against the same state by
# picking one of the question's options, with a probability for each.
# questions: {name: {"instructions": text, "options": {label: description}}}.
func decide(role: String, state: String, questions: Dictionary, timeout_s: float = 0.0) -> Dictionary:
	yield(get_tree(), "idle_frame")
	var cfg = config.get_value("ai." + role, {})
	var provider = str(cfg.get("provider", "vercel"))
	if not (provider in DECISION_PROVIDERS):
		return {"ok": false, "error": "ai.%s.provider must be one of %s" % [role, str(DECISION_PROVIDERS)]}
	var key = config.api_key(provider)
	if key == "":
		return {"ok": false, "error": "no API key for provider '%s': set it in the budok settings (Providers) or the %s environment variable" % [
			provider, config.get_value("ai.providers.%s.api_key_env" % provider, "?")]}
	var model = str(cfg.get("model", ""))
	if model == "" and provider == "vercel":
		return {"ok": false, "error": "set ai.%s.model to a decision model id, such as typesafe-ai/jev" % role}
	# The model id is sent as a header (and can be set over MCP).
	if model.find("\n") != -1 or model.find("\r") != -1:
		return {"ok": false, "error": "ai.%s.model must be a single line" % role}
	var wire = {}
	for name in questions:
		wire[name] = {"type": "choice", "instructions": questions[name]["instructions"], "criteria": questions[name]["options"]}
	var base = str(config.get_value("ai.providers.%s.base_url" % provider, "")).trim_suffix("/")
	var url = base + "/v1/systemone"
	var headers = ["content-type: application/json", "authorization: Bearer " + key]
	var body = {"state": state, "questions": wire}
	if provider == "vercel":
		url = base + "/decision-model"
		headers += ["ai-gateway-protocol-version: " + GATEWAY_PROTOCOL_VERSION, "ai-gateway-auth-method: api-key",
			"ai-decision-model-specification-version: " + DECISION_SPEC_VERSION, "ai-model-id: " + model]
		body = {"stateParts": [{"type": "text", "text": state}], "questions": wire}
	elif model != "":
		body["model"] = model
	_merge_extra(body, cfg)
	var timeout = timeout_s if timeout_s > 0.0 else float(cfg.get("request_timeout_s", 20))
	var response = {}
	for attempt in range(2):
		# Polled on a thread: the lookahead makes many short calls in a row.
		response = yield(_send(url, headers, Util.json_str(body), timeout, HTTPClient.METHOD_POST, true), "completed")
		# Rate limits are left to the caller, which paces its calls (a quick
		# retry would only use up the next request of a small budget).
		var status = int(response.get("status", 0))
		if response["ok"] or status == 429 or not (status in RETRY_CODES) or attempt == 1:
			break
		yield(get_tree().create_timer(1.0), "timeout")
	if not response["ok"]:
		return {"ok": false, "error": response["error"], "status": int(response.get("status", 0))}
	return parse_decision(response["json"], questions)


# Normalizes both APIs' answers: probabilities over exactly the asked labels,
# summing to 1 (a bare choice counts as certain).
static func parse_decision(json, questions: Dictionary) -> Dictionary:
	if not (json is Dictionary) or not (json.get("answers") is Dictionary):
		return {"ok": false, "error": "unexpected response: %s" % Util.truncate(Util.json_str(json), 300)}
	var answers = {}
	for name in questions:
		var answer = json["answers"].get(name)
		if not (answer is Dictionary):
			return {"ok": false, "error": "no answer for question '%s'" % name}
		if str(answer.get("type", "")) == "refusal":
			return {"ok": false, "error": "the model declined to answer '%s'" % name}
		var labels = questions[name]["options"].keys()
		var choice = str(answer.get("choice", ""))
		var probabilities = {}
		var total = 0.0
		var raw = answer.get("probabilities")
		for label in labels:
			var value = Util.numeric(raw.get(label, 0.0)) if raw is Dictionary else 0.0
			var p = max(0.0, float(value)) if (value is float or value is int) else 0.0
			probabilities[label] = p
			total += p
		if total <= 0.0:
			if not (choice in labels):
				return {"ok": false, "error": "question '%s' was answered with an unknown option '%s'" % [name, choice]}
			probabilities[choice] = 1.0
			total = 1.0
		var best = ""
		for label in labels:
			probabilities[label] /= total
			if best == "" or probabilities[label] > probabilities[best]:
				best = label
		answers[name] = {"choice": choice if choice in labels else best, "probabilities": probabilities}
	var usage = json.get("usage", {}) if json.get("usage") is Dictionary else {}
	return {"ok": true, "answers": answers, "model": str(json.get("model", "")), "usage": {
		"input_tokens": Util.as_int(usage.get("inputTokens", usage.get("input_tokens", 0))),
		"output_tokens": Util.as_int(usage.get("outputTokens", usage.get("output_tokens", 0)))}}


# Messages carrying tool results back, in the provider's format.
func tool_results(role: String, results: Array) -> Array:
	if _provider(role) == "anthropic":
		var blocks = []
		for result in results:
			blocks.append({"type": "tool_result", "tool_use_id": result["id"], "content": result["content"], "is_error": bool(result.get("is_error", false))})
		return [{"role": "user", "content": blocks}]
	var out = []
	for result in results:
		out.append({"role": "tool", "tool_call_id": result["id"], "content": result["content"]})
	return out


func user_message(text: String) -> Dictionary:
	return {"role": "user", "content": text}


func _provider(role: String) -> String:
	return str(config.get_value("ai.%s.provider" % role, "anthropic"))


func _anthropic_request(cfg: Dictionary, key: String, system: String, messages: Array, tools: Array) -> Dictionary:
	var base = str(config.get_value("ai.providers.anthropic.base_url", "https://api.anthropic.com")).trim_suffix("/")
	var model = str(cfg.get("model", "claude-opus-5-5"))
	var body = {
		"model": model,
		"max_tokens": int(cfg.get("max_tokens", 16000)),
		# The system prompt is stable for a whole match / annotation job: cache it.
		"system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
		"messages": messages,
	}
	if not tools.empty():
		var defs = []
		for tool_def in tools:
			defs.append({"name": tool_def["name"], "description": tool_def["description"], "input_schema": tool_def["parameters"]})
		body["tools"] = defs
		body["tool_choice"] = {"type": "auto"}
	var effort = str(cfg.get("effort", ""))
	if effort != "":
		body["output_config"] = {"effort": effort}
	var headers = ["content-type: application/json", "x-api-key: " + key, "anthropic-version: " + ANTHROPIC_VERSION]
	if bool(cfg.get("refusal_fallback", true)) and model in FALLBACK_MODELS and base == "https://api.anthropic.com":
		body["fallbacks"] = "default"
		headers.append("anthropic-beta: " + FALLBACK_BETA)
	_merge_extra(body, cfg)
	return {"url": base + "/v1/messages", "headers": headers, "body": body}


func _openai_request(provider: String, cfg: Dictionary, key: String, system: String, messages: Array, tools: Array) -> Dictionary:
	var base = str(config.get_value("ai.providers.%s.base_url" % provider, "https://api.openai.com/v1")).trim_suffix("/")
	var body = {
		"model": str(cfg.get("model", "")),
		"messages": [{"role": "system", "content": system}] + messages,
	}
	body["max_completion_tokens" if provider == "openai" else "max_tokens"] = int(cfg.get("max_tokens", 16000))
	if cfg.get("temperature") != null:
		body["temperature"] = float(cfg["temperature"])
	if not tools.empty():
		var defs = []
		for tool_def in tools:
			defs.append({"type": "function", "function": {"name": tool_def["name"], "description": tool_def["description"], "parameters": tool_def["parameters"]}})
		body["tools"] = defs
		body["tool_choice"] = "auto"
	var headers = ["content-type: application/json"]
	if key != "":
		headers.append("authorization: Bearer " + key)
	if provider == "openrouter":
		headers.append("http-referer: https://github.com/memezforbeanz/budok-reborn")
		headers.append("x-title: budok")
	_merge_extra(body, cfg)
	return {"url": base + "/chat/completions", "headers": headers, "body": body}


func _merge_extra(body: Dictionary, cfg: Dictionary) -> void:
	var extra = cfg.get("extra_body", {})
	if extra is Dictionary:
		for key in extra:
			body[key] = extra[key]


func _parse_anthropic(json) -> Dictionary:
	if not (json is Dictionary):
		return {"ok": false, "error": "unexpected response from Anthropic"}
	var content = json.get("content", [])
	var text = ""
	var calls = []
	for block in content:
		match str(block.get("type", "")):
			"text":
				text += str(block.get("text", ""))
			"tool_use":
				calls.append({"id": block.get("id"), "name": block.get("name"), "input": block.get("input", {})})
	var stop = str(json.get("stop_reason", ""))
	var result = {
		"ok": stop != "refusal",
		"provider": "anthropic",
		# Append the content unchanged (thinking blocks included) on later calls.
		"assistant": {"role": "assistant", "content": content},
		"text": text,
		"tool_calls": calls,
		"stop_reason": stop,
		"usage": json.get("usage", {}),
		"model": json.get("model", ""),
	}
	if stop == "refusal":
		result["error"] = "the model declined this request (%s)" % str(json.get("stop_details", {}))
	return result


func _parse_openai(json) -> Dictionary:
	if not (json is Dictionary) or not (json.get("choices") is Array) or json["choices"].empty():
		return {"ok": false, "error": "unexpected response: %s" % Util.truncate(Util.json_str(json), 300)}
	var choice = json["choices"][0]
	var message = choice.get("message", {})
	var calls = []
	var raw_calls = message.get("tool_calls", [])
	if raw_calls is Array:
		for call_info in raw_calls:
			var fn = call_info.get("function", {})
			var parsed = Util.json_parse(str(fn.get("arguments", "{}")))
			calls.append({"id": call_info.get("id"), "name": fn.get("name"), "input": parsed["value"] if parsed["ok"] else {"_unparsed": fn.get("arguments")}})
	var assistant = {"role": "assistant", "content": message.get("content")}
	if raw_calls is Array and not raw_calls.empty():
		assistant["tool_calls"] = raw_calls
	return {
		"ok": true,
		"provider": "openai",
		"assistant": assistant,
		"text": str(message.get("content", "")) if message.get("content") != null else "",
		"tool_calls": calls,
		"stop_reason": str(choice.get("finish_reason", "")),
		"usage": json.get("usage", {}),
		"model": json.get("model", ""),
	}


# Coroutine: plain JSON GET (used by the opt-in schema registry).
func get_json(url: String, timeout_s: float = 30.0) -> Dictionary:
	var response = yield(_send(url, ["accept: application/json"], "", timeout_s, HTTPClient.METHOD_GET), "completed")
	return response


func _send(url: String, headers: Array, body: String, timeout_s: float, method: int = HTTPClient.METHOD_POST, threaded: bool = false) -> Dictionary:
	var http = HTTPRequest.new()
	http.use_threads = threaded
	add_child(http)
	if Util.has_prop(http, "timeout"):
		http.timeout = timeout_s
	var err = http.request(url, PoolStringArray(headers), true, method, body)
	if err != OK:
		http.queue_free()
		yield(get_tree(), "idle_frame")
		return {"ok": false, "error": "could not start request to %s (error %d)" % [url, err]}
	var completed = yield(http, "request_completed")
	http.queue_free()
	var result = completed[0]
	var status = int(completed[1])
	var text = completed[3].get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "status": 0, "error": "network error %d talking to %s (timeout, DNS or TLS)" % [result, url]}
	var parsed = Util.json_parse(text)
	if status >= 400:
		var message = Util.truncate(text, 400)
		if parsed["ok"] and parsed["value"] is Dictionary:
			var error = parsed["value"].get("error", {})
			if error is Dictionary and error.has("message"):
				message = str(error["message"])
			elif error is String:
				message = error
		return {"ok": false, "status": status, "error": "HTTP %d: %s" % [status, message]}
	if not parsed["ok"]:
		return {"ok": false, "status": status, "error": "invalid JSON response"}
	return {"ok": true, "status": status, "json": parsed["value"]}

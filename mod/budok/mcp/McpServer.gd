extends Node

# MCP server (Streamable HTTP transport, JSON responses only) living inside the
# game. POST /mcp carries JSON-RPC; GET is answered 405 (no server stream:
# long-running work such as waiting for a turn is a long-poll tool call);
# DELETE ends a session. Auth is a bearer token shown in the in-game panel
# (also accepted as ?token= for clients that cannot set headers).

signal activity(kind)

const Util = preload("res://budok/core/Util.gd")
const HttpServer = preload("res://budok/mcp/HttpServer.gd")
const Tools = preload("res://budok/mcp/Tools.gd")
const Resources = preload("res://budok/mcp/Resources.gd")
const PROTOCOL_VERSIONS := ["2025-06-18", "2025-03-26", "2024-11-05"]
const DEFAULT_SESSION := "default"
const SESSION_IDLE_MS := 6 * 3600 * 1000
const INSTRUCTIONS := """budok lets you play YOMI Hustle, a turn-based simultaneous-move fighting game, live inside the player's game.
Typical flow: get_status -> list_characters -> start_match (or let the player start one) -> claim_slot ->
loop { wait_for_turn -> optionally describe_character / simulate a few candidate moves -> submit_action }.
Both players choose at the same time; you never see the opponent's choice before the turn resolves.
simulate previews a move on the real engine against an assumed opponent move. For modded characters without
notes, read the annotate_character prompt and use introspect_character / read_source / submit_character_schema.
Knowledge about the engine and modding conventions is available as resources (yomi://knowledge/...)."""

var runtime = null
var http = null
var tools = null
var resources = null
var sessions := {}
var _pending := {}
var _next_pending := 1


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	http = HttpServer.new()
	add_child(http)
	http.connect("request_received", self, "_on_request")
	tools = Tools.new(runtime)
	resources = Resources.new(runtime)


func start() -> Dictionary:
	if not bool(runtime.config.get_value("mcp.enabled", true)):
		http.stop()
		return {"ok": false, "error": "MCP server disabled in settings"}
	var host = str(runtime.config.get_value("mcp.host", "127.0.0.1"))
	var port = int(runtime.config.get_value("mcp.port", 8765))
	var err = http.start(host, port)
	if err != OK:
		return {"ok": false, "error": "could not listen on %s:%d (error %d); is another copy running or the port taken?" % [host, port, err]}
	return {"ok": true, "url": url()}


func url() -> String:
	var host = str(runtime.config.get_value("mcp.host", "127.0.0.1"))
	if host == "0.0.0.0" or host == "*":
		host = "127.0.0.1"
	return "http://%s:%d/mcp" % [host, int(runtime.config.get_value("mcp.port", 8765))]


func session_count() -> int:
	return sessions.size()


func _on_request(conn_id: int, req: Dictionary) -> void:
	var path = req["path"].trim_suffix("/")
	var headers = req["headers"]
	if req["method"] == "OPTIONS":
		_respond_raw(conn_id, 204, "", headers)
		return
	if path == "/health":
		_respond_json(conn_id, 200, {"ok": true, "server": "budok", "listening": true}, headers)
		return
	if path != "/mcp" and path != "":
		_respond_json(conn_id, 404, {"error": "not found; the MCP endpoint is /mcp"}, headers)
		return
	if not _origin_allowed(headers.get("origin", "")):
		_respond_json(conn_id, 403, {"error": "origin not allowed"}, headers)
		return
	if not _authorized(req):
		_respond_json(conn_id, 401, {"error": "missing or wrong token; copy it from the budok panel in game (F8)"}, headers,
			{"WWW-Authenticate": "Bearer realm=\"budok\""})
		return
	match req["method"]:
		"GET":
			_respond_raw(conn_id, 405, "", headers, {"Allow": "POST, DELETE"})
		"DELETE":
			var sid = headers.get("mcp-session-id", "")
			if sessions.has(sid):
				_end_session(sid)
			_respond_raw(conn_id, 200, "", headers)
		"POST":
			_handle_post(conn_id, req)
		_:
			_respond_raw(conn_id, 405, "", headers, {"Allow": "POST, DELETE"})


func _handle_post(conn_id: int, req: Dictionary) -> void:
	var headers = req["headers"]
	var parsed = Util.parse_json(req["body"])
	if not parsed["ok"]:
		_respond_json(conn_id, 400, _rpc_error(null, -32700, "parse error: %s" % parsed["error"]), headers)
		return
	var is_batch = parsed["value"] is Array
	var messages = parsed["value"] if is_batch else [parsed["value"]]
	var sid = headers.get("mcp-session-id", "")
	var new_session = ""
	for msg in messages:
		if msg is Dictionary and msg.get("method") == "initialize":
			new_session = _create_session(msg.get("params", {}))
			sid = new_session
	if sid == "":
		sid = _default_session()
	elif not sessions.has(sid):
		_respond_json(conn_id, 404, _rpc_error(null, -32001, "session not found; reinitialize"), headers)
		return
	sessions[sid]["last_seen_ms"] = Util.now_ms()
	var requests = []
	for msg in messages:
		if not (msg is Dictionary) or msg.get("jsonrpc") != "2.0":
			requests.append({"invalid": true, "id": msg.get("id") if msg is Dictionary else null})
		elif msg.has("method") and msg.has("id"):
			requests.append(msg)
		elif msg.has("method"):
			_notification(msg, sid)
	if requests.empty():
		_respond_raw(conn_id, 202, "", headers, _session_header(new_session))
		return
	var key = _next_pending
	_next_pending += 1
	_pending[key] = {
		"conn_id": conn_id, "batch": is_batch, "headers": headers, "extra": _session_header(new_session),
		"order": [], "results": {}, "remaining": requests.size(),
	}
	for i in range(requests.size()):
		_pending[key]["order"].append(i)
	for i in range(requests.size()):
		var msg = requests[i]
		if msg.has("invalid"):
			_store(key, i, _rpc_error(msg.get("id"), -32600, "invalid JSON-RPC request"))
			continue
		var outcome = _dispatch(msg, sid)
		if outcome is GDScriptFunctionState:
			outcome.connect("completed", self, "_on_async_done", [key, i])
		else:
			_store(key, i, outcome)


func _on_async_done(response, key: int, index: int) -> void:
	_store(key, index, response)


func _store(key: int, index: int, response) -> void:
	if not _pending.has(key):
		return
	var pending = _pending[key]
	pending["results"][index] = response
	pending["remaining"] -= 1
	if pending["remaining"] > 0:
		return
	_pending.erase(key)
	var body = []
	for i in pending["order"]:
		body.append(pending["results"][i])
	_respond_json(pending["conn_id"], 200, body if pending["batch"] else body[0], pending["headers"], pending["extra"])


func _dispatch(msg: Dictionary, sid: String):
	var id = msg["id"]
	# Godot parses every JSON number as float; echo integral ids back as ints.
	if id is float and id == floor(id):
		id = int(id)
	var params = msg.get("params", {})
	if params == null:
		params = {}
	if not (params is Dictionary):
		return _rpc_error(id, -32602, "params must be an object")
	var session = sessions[sid]
	match str(msg["method"]):
		"initialize":
			var requested = str(params.get("protocolVersion", PROTOCOL_VERSIONS[0]))
			session["protocol"] = requested if requested in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
			emit_signal("activity", "initialize")
			return _rpc_result(id, {
				"protocolVersion": session["protocol"],
				"capabilities": {
					"tools": {"listChanged": false},
					"resources": {"subscribe": false, "listChanged": false},
					"prompts": {"listChanged": false},
					"logging": {},
				},
				"serverInfo": {"name": "budok", "title": "budok - YOMI Hustle", "version": runtime.version()},
				"instructions": INSTRUCTIONS,
			})
		"ping":
			return _rpc_result(id, {})
		"tools/list":
			return _rpc_result(id, {"tools": tools.definitions()})
		"tools/call":
			return _call_tool(id, params, sid)
		"resources/list":
			return _rpc_result(id, {"resources": resources.list()})
		"resources/templates/list":
			return _rpc_result(id, {"resourceTemplates": resources.templates()})
		"resources/read":
			var read = resources.read(str(params.get("uri", "")))
			if not read["ok"]:
				return _rpc_error(id, -32002, read["error"])
			return _rpc_result(id, {"contents": read["contents"]})
		"prompts/list":
			return _rpc_result(id, {"prompts": resources.prompts()})
		"prompts/get":
			var prompt = resources.get_prompt(str(params.get("name", "")), params.get("arguments", {}))
			if not prompt["ok"]:
				return _rpc_error(id, -32602, prompt["error"])
			return _rpc_result(id, prompt["result"])
		"logging/setLevel":
			return _rpc_result(id, {})
		"completion/complete":
			return _rpc_result(id, {"completion": {"values": [], "hasMore": false}})
	return _rpc_error(id, -32601, "method not found: %s" % msg["method"])


func _call_tool(id, params: Dictionary, sid: String):
	var name = str(params.get("name", ""))
	if not tools.has_tool(name):
		return _rpc_error(id, -32602, "unknown tool: %s" % name)
	var arguments = params.get("arguments", {})
	if not (arguments is Dictionary):
		arguments = {}
	emit_signal("activity", name)
	var raw = tools.call_tool(name, arguments, sid)
	if raw is GDScriptFunctionState:
		raw = yield(raw, "completed")
	if not (raw is Dictionary):
		raw = {"ok": false, "error": "tool returned no result"}
	var is_error = raw.has("error") and raw.get("ok", false) != true
	var result = {"content": [{"type": "text", "text": Util.to_json(raw)}], "isError": is_error}
	if str(sessions.get(sid, {}).get("protocol", "")) >= "2025-06-18":
		result["structuredContent"] = raw
	return _rpc_result(id, result)


func _notification(msg: Dictionary, sid: String) -> void:
	if str(msg.get("method")) == "notifications/initialized":
		sessions[sid]["initialized"] = true


func _create_session(params) -> String:
	_prune_sessions()
	var sid = Util.random_hex(16)
	var client = params.get("clientInfo", {}) if params is Dictionary else {}
	sessions[sid] = {
		"id": sid,
		"created_ms": Util.now_ms(),
		"last_seen_ms": Util.now_ms(),
		"client": client if client is Dictionary else {},
		"protocol": PROTOCOL_VERSIONS[0],
	}
	emit_signal("activity", "session")
	return sid


func _default_session() -> String:
	if not sessions.has(DEFAULT_SESSION):
		sessions[DEFAULT_SESSION] = {"id": DEFAULT_SESSION, "created_ms": Util.now_ms(), "last_seen_ms": Util.now_ms(),
			"client": {"name": "(no session header)"}, "protocol": PROTOCOL_VERSIONS[0]}
	return DEFAULT_SESSION


func _end_session(sid: String) -> void:
	runtime.matches.release_session(sid)
	sessions.erase(sid)
	emit_signal("activity", "session")


func _prune_sessions() -> void:
	var now = Util.now_ms()
	for sid in sessions.keys():
		if now - int(sessions[sid]["last_seen_ms"]) > SESSION_IDLE_MS:
			_end_session(sid)


func _authorized(req: Dictionary) -> bool:
	if not bool(runtime.config.get_value("mcp.require_token", true)):
		return true
	var expected = str(runtime.config.get_value("mcp.auth_token", ""))
	if expected == "":
		return false
	var auth = str(req["headers"].get("authorization", ""))
	if auth.begins_with("Bearer ") and auth.substr(7).strip_edges() == expected:
		return true
	return str(req["query"].get("token", "")) == expected


func _origin_allowed(origin: String) -> bool:
	if origin == "":
		return true
	var allowed = runtime.config.get_value("mcp.allowed_origins", [])
	if allowed is Array and origin in allowed:
		return true
	var host = origin.split("://", false, 1)
	host = host[host.size() - 1].split("/")[0]
	if host.begins_with("["):
		host = host.substr(0, host.find("]") + 1)
	else:
		host = host.split(":")[0]
	return host in ["localhost", "127.0.0.1", "[::1]"]


func _session_header(sid: String) -> Dictionary:
	return {"Mcp-Session-Id": sid} if sid != "" else {}


func _respond_json(conn_id: int, status: int, value, req_headers: Dictionary, extra: Dictionary = {}) -> void:
	var headers = {"Content-Type": "application/json"}
	for key in extra:
		headers[key] = extra[key]
	_add_cors(headers, req_headers)
	http.respond(conn_id, status, headers, Util.to_json(value))


func _respond_raw(conn_id: int, status: int, body: String, req_headers: Dictionary, extra: Dictionary = {}) -> void:
	var headers = {}
	for key in extra:
		headers[key] = extra[key]
	_add_cors(headers, req_headers)
	http.respond(conn_id, status, headers, body)


func _add_cors(headers: Dictionary, req_headers: Dictionary) -> void:
	var origin = str(req_headers.get("origin", ""))
	if origin == "" or not _origin_allowed(origin):
		return
	headers["Access-Control-Allow-Origin"] = origin
	headers["Access-Control-Allow-Methods"] = "POST, DELETE, OPTIONS"
	headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, Mcp-Session-Id, MCP-Protocol-Version"
	headers["Access-Control-Expose-Headers"] = "Mcp-Session-Id"


static func _rpc_result(id, result) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


static func _rpc_error(id, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}

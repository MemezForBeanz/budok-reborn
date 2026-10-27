extends Node

# Minimal HTTP/1.1 server on top of TCP_Server, polled from _process so all
# request handling runs on the main thread next to the game state.
# One request per connection ("Connection: close"); bodies need Content-Length.
# Responses may be sent later (long-polls): the handler keeps the connection
# id and calls respond() when ready.

signal request_received(conn_id, request)

const MAX_HEADER_BYTES := 16384
const MAX_BODY_BYTES := 2 * 1024 * 1024
const READ_TIMEOUT_MS := 30000
const HANDLER_TIMEOUT_MS := 600000
const STATUS_TEXT := {
	200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
	403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 411: "Length Required",
	413: "Payload Too Large", 500: "Internal Server Error", 504: "Gateway Timeout",
}

var listening := false

var _server := TCP_Server.new()
var _conns := {}
var _next_id := 1


func start(host: String, port: int) -> int:
	stop()
	var err = _server.listen(port, host)
	listening = err == OK
	set_process(listening)
	return err


func stop() -> void:
	for conn_id in _conns.keys():
		_close(conn_id)
	if listening:
		_server.stop()
	listening = false


func respond(conn_id: int, status: int, headers: Dictionary, body: String = "") -> void:
	if not _conns.has(conn_id):
		return
	var peer = _conns[conn_id]["peer"]
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_close(conn_id)
		return
	var payload = body.to_utf8()
	var lines = ["HTTP/1.1 %d %s" % [status, STATUS_TEXT.get(status, "OK")]]
	headers["Content-Length"] = str(payload.size())
	headers["Connection"] = "close"
	for key in headers:
		lines.append("%s: %s" % [key, headers[key]])
	var head = (PoolStringArray(lines).join("\r\n") + "\r\n\r\n").to_utf8()
	peer.put_data(head)
	if payload.size() > 0:
		peer.put_data(payload)
	_close(conn_id)


func is_open(conn_id: int) -> bool:
	return _conns.has(conn_id) and _conns[conn_id]["peer"].get_status() == StreamPeerTCP.STATUS_CONNECTED


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		var peer = _server.take_connection()
		peer.set_no_delay(true)
		_conns[_next_id] = {"peer": peer, "buffer": PoolByteArray(), "opened_ms": OS.get_ticks_msec(), "waiting": false}
		_next_id += 1
	var now = OS.get_ticks_msec()
	for conn_id in _conns.keys():
		var conn = _conns[conn_id]
		var peer = conn["peer"]
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_close(conn_id)
			continue
		if conn["waiting"]:
			if now - conn["opened_ms"] > HANDLER_TIMEOUT_MS:
				respond(conn_id, 504, {"Content-Type": "text/plain"}, "handler timeout")
			continue
		var available = peer.get_available_bytes()
		if available > 0:
			var chunk = peer.get_data(available)
			if chunk[0] == OK:
				# Pool arrays are values in Godot 3: mutate a copy, then store it.
				var buffer = conn["buffer"]
				buffer.append_array(chunk[1])
				conn["buffer"] = buffer
		if now - conn["opened_ms"] > READ_TIMEOUT_MS:
			_close(conn_id)
			continue
		_try_parse(conn_id, conn)


func _try_parse(conn_id: int, conn: Dictionary) -> void:
	var buffer: PoolByteArray = conn["buffer"]
	var header_end = _find_header_end(buffer)
	if header_end == -1:
		if buffer.size() > MAX_HEADER_BYTES:
			respond(conn_id, 400, {"Content-Type": "text/plain"}, "headers too large")
		return
	var head = buffer.subarray(0, header_end - 1).get_string_from_utf8() if header_end > 0 else ""
	var head_lines = head.split("\r\n")
	var request_line = head_lines[0].split(" ")
	if request_line.size() < 3:
		respond(conn_id, 400, {"Content-Type": "text/plain"}, "bad request line")
		return
	var headers = {}
	for i in range(1, head_lines.size()):
		var colon = head_lines[i].find(":")
		if colon > 0:
			headers[head_lines[i].substr(0, colon).strip_edges().to_lower()] = head_lines[i].substr(colon + 1).strip_edges()
	if headers.get("transfer-encoding", "").to_lower().find("chunked") != -1:
		respond(conn_id, 411, {"Content-Type": "text/plain"}, "chunked bodies are not supported; send Content-Length")
		return
	var length = int(headers.get("content-length", "0"))
	if length > MAX_BODY_BYTES:
		respond(conn_id, 413, {"Content-Type": "text/plain"}, "body too large")
		return
	var body_start = header_end + 4
	if buffer.size() < body_start + length:
		return
	var body = buffer.subarray(body_start, body_start + length - 1).get_string_from_utf8() if length > 0 else ""
	var target = request_line[1]
	var query = {}
	var question = target.find("?")
	var path = target
	if question != -1:
		path = target.substr(0, question)
		for pair in target.substr(question + 1).split("&"):
			var eq = pair.find("=")
			if eq > 0:
				query[pair.substr(0, eq).percent_decode()] = pair.substr(eq + 1).percent_decode()
	conn["waiting"] = true
	conn["opened_ms"] = OS.get_ticks_msec()
	emit_signal("request_received", conn_id, {
		"method": request_line[0].to_upper(),
		"path": path,
		"query": query,
		"headers": headers,
		"body": body,
	})


static func _find_header_end(buffer: PoolByteArray) -> int:
	var size = buffer.size()
	for i in range(0, size - 3):
		if buffer[i] == 13 and buffer[i + 1] == 10 and buffer[i + 2] == 13 and buffer[i + 3] == 10:
			return i
	return -1


func _close(conn_id: int) -> void:
	if not _conns.has(conn_id):
		return
	var peer = _conns[conn_id]["peer"]
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()
	_conns.erase(conn_id)

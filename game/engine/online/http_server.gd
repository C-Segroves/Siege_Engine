class_name HttpServer
extends Node
## A minimal HTTP/1.1 server for the small JSON endpoints of the game (a server's match list, the master server). One
## request per connection ("Connection: close"). It parses the request line, the headers and a body of at most `max_body`
## bytes, hands the request to `handler` and writes the answer. Nothing else is served: no files, no directory listing.
## `handler(request: Dictionary) -> Dictionary`: request {method, path, query, headers (lower-case keys), body, ip},
## answer {code, type, body}. CORS is open (the lists hold no secret and a page may read them from any origin).

const MAX_HEAD_BYTES := 8192
const DEFAULT_MAX_BODY := 4096
const IDLE_SECONDS := 5.0
const MAX_CONNECTIONS := 64
const REASONS := {200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
	413: "Payload Too Large", 429: "Too Many Requests", 500: "Internal Server Error"}

var handler := Callable()
var max_body := DEFAULT_MAX_BODY
var _server := TCPServer.new()
## Open connections: {peer: StreamPeerTCP, buf: PackedByteArray, age: float}
var _clients: Array[Dictionary] = []


func start(port: int, bind_address := "*") -> Error:
	return _server.listen(port, bind_address)


func stop() -> void:
	_server.stop()
	for c in _clients:
		(c.peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()


func is_listening() -> bool:
	return _server.is_listening()


func _process(delta: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		var peer := _server.take_connection()
		if _clients.size() >= MAX_CONNECTIONS:
			peer.disconnect_from_host()
			continue
		_clients.append({"peer": peer, "buf": PackedByteArray(), "age": 0.0})
	for c in _clients.duplicate():
		if not _serve(c, delta):
			_clients.erase(c)


## Reads a request; returns false once the connection is finished.
func _serve(c: Dictionary, delta: float) -> bool:
	var peer: StreamPeerTCP = c.peer
	peer.poll()
	c.age += delta
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or c.age > IDLE_SECONDS:
		return false
	var n := peer.get_available_bytes()
	if n > 0:
		c.buf.append_array(peer.get_data(n)[1])
	var raw := (c.buf as PackedByteArray).get_string_from_utf8()
	var split := _find_head_end(raw)
	if split < 0:
		return _send(peer, 413, "text/plain", "too large") if raw.length() > MAX_HEAD_BYTES else true
	var parsed := parse_head(raw.substr(0, split))
	var declared := int(parsed.headers.get("content-length", "0"))
	if declared > max_body or declared < 0:
		return _send(peer, 413, "text/plain", "too large")
	var body_start := split + (4 if raw.substr(split, 4) == "\r\n\r\n" else 2)
	var body_bytes := (c.buf as PackedByteArray).slice(raw.substr(0, body_start).to_utf8_buffer().size())
	if body_bytes.size() < declared:
		return true   # the body is still arriving
	parsed["body"] = body_bytes.slice(0, declared).get_string_from_utf8()
	parsed["ip"] = normalize_ip(peer.get_connected_host())
	var answer: Dictionary = handler.call(parsed) if handler.is_valid() else {"code": 404, "type": "text/plain", "body": "not found"}
	return _send(peer, int(answer.get("code", 500)), str(answer.get("type", "text/plain")), str(answer.get("body", "")))


static func _find_head_end(raw: String) -> int:
	var crlf := raw.find("\r\n\r\n")
	var lf := raw.find("\n\n")
	if crlf >= 0 and (lf < 0 or crlf < lf):
		return crlf
	return lf


## {method, path, query, headers} of a request head (request line + header lines).
static func parse_head(head: String) -> Dictionary:
	var lines := head.replace("\r", "").split("\n")
	var parts := lines[0].strip_edges().split(" ")
	var target := parts[1] if parts.size() > 1 else ""
	var path_query := target.split("?", true, 1)
	var headers := {}
	for i in range(1, lines.size()):
		var kv := lines[i].split(":", true, 1)
		if kv.size() == 2:
			headers[kv[0].strip_edges().to_lower()] = kv[1].strip_edges()
	var path := path_query[0].rstrip("/")
	return {"method": parts[0] if parts.size() > 0 else "", "path": path, "query": path_query[1] if path_query.size() > 1 else "",
		"headers": headers, "body": "", "ip": ""}


## "::ffff:1.2.3.4" -> "1.2.3.4".
static func normalize_ip(ip: String) -> String:
	return ip.trim_prefix("::ffff:")


func _send(peer: StreamPeerTCP, code: int, type: String, body: String) -> bool:
	var data := body.to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" % [
		code, REASONS.get(code, "Error"), type, data.size()]
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(data)
	peer.disconnect_from_host()
	return false

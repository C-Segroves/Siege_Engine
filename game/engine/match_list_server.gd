class_name MatchListServer
extends Node
## A tiny HTTP endpoint of a dedicated server: GET /matches answers the JSON list of this server's matches
## ({"matches": [Net.make_match_info()]}); GET /health answers "ok". Nothing else is served: never game data.
## A reverse proxy (deploy/nginx-server.conf.template, deploy/Caddyfile.example) maps it next to the WebSocket path.
## CORS is open because the list holds no secret and desktop clients may read it from any page.

const DEFAULT_PORT := 47702
const MAX_REQUEST_BYTES := 4096
const IDLE_SECONDS := 5.0

var _server := TCPServer.new()
## Open connections: {peer: StreamPeerTCP, buf: String, age: float}
var _clients: Array[Dictionary] = []


func start(port := DEFAULT_PORT, bind_address := "*") -> Error:
	return _server.listen(port, bind_address)


func _process(delta: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buf": "", "age": 0.0})
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
		c.buf += peer.get_utf8_string(n)
	if c.buf.length() > MAX_REQUEST_BYTES:
		return _send(peer, 413, "text/plain", "too large")
	if not "\r\n\r\n" in c.buf and not "\n\n" in c.buf:
		return true
	return _send_for(peer, str(c.buf).split("\n")[0])


func _send_for(peer: StreamPeerTCP, request_line: String) -> bool:
	var parts := request_line.strip_edges().split(" ")
	if parts.size() < 2 or parts[0] not in ["GET", "HEAD", "OPTIONS"]:
		return _send(peer, 405, "text/plain", "method not allowed")
	var path := parts[1].split("?")[0].rstrip("/")
	match path:
		"/matches", "":
			return _send(peer, 200, "application/json", make_matches_json())
		"/health":
			return _send(peer, 200, "text/plain", "ok")
	return _send(peer, 404, "text/plain", "not found")


## The JSON body of GET /matches.
static func make_matches_json() -> String:
	var info := Net.make_match_info()
	info.erase("proto")
	return JSON.stringify({"matches": [info]})


func _send(peer: StreamPeerTCP, code: int, type: String, body: String) -> bool:
	var data := body.to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" % [
		code, "OK" if code == 200 else "Error", type, data.size()]
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(data)
	peer.disconnect_from_host()
	return false

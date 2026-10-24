class_name ServerAddress
extends RefCounted
## What a player types to join a server: an IP, "IP:port", a host name, "host:port", a "ws://" / "wss://" address or an
## "http(s)://" page address. parse() splits it; the game port is Net.GAME_PORT unless the text names one.
## `list_port` is where the server's match list (HTTP /matches) is expected: the default, or the port of an "http://" address.

const DEFAULT_LIST_PORT := MatchListServer.DEFAULT_PORT
const KIND_ENET := "enet"
const KIND_WS := "ws"
const KIND_HTTP := "http"
const MAX_TEXT := 255


## {ok, kind, host, port, list_port, text} or {ok: false, error}. `text` is the cleaned address to remember and join.
static func parse(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	if text == "" or text.length() > MAX_TEXT or " " in text:
		return {"ok": false, "error": "Type the server's IP or name, for example 192.168.1.20 or 192.168.1.20:47700"}
	if Net.is_ws_address(text):
		return {"ok": true, "kind": KIND_WS, "host": _host_of(text), "port": 0, "list_port": 0, "text": text}
	if text.begins_with("http://") or text.begins_with("https://"):
		return {"ok": true, "kind": KIND_HTTP, "host": _host_of(text), "port": 0, "list_port": 0, "text": text}
	var host := text
	var port := Net.GAME_PORT
	if text.count(":") == 1:
		var parts := text.split(":")
		host = parts[0]
		if not parts[1].is_valid_int() or int(parts[1]) < 1 or int(parts[1]) > 65535:
			return {"ok": false, "error": "The port must be a number from 1 to 65535"}
		port = int(parts[1])
	elif text.count(":") > 1:
		return {"ok": false, "error": "IPv6 addresses are not supported yet"}
	if host == "" or not _is_host_name(host):
		return {"ok": false, "error": "That is not an IP address or a host name"}
	return {"ok": true, "kind": KIND_ENET, "host": host, "port": port, "list_port": DEFAULT_LIST_PORT,
		"text": host if port == Net.GAME_PORT else "%s:%d" % [host, port]}


static func _is_host_name(host: String) -> bool:
	for ch in host:
		if not (ch.is_valid_identifier() or ch in ".-" or ch.is_valid_int()):
			return false
	return true


static func _host_of(url: String) -> String:
	var rest := url.substr(url.find("://") + 3)
	return rest.split("/")[0].split(":")[0]


## "host" or "host:port" for the match list of the server at `address` (a parse() result); "" when it has none.
static func make_list_origin(address: Dictionary) -> String:
	if address.kind == KIND_ENET:
		return "http://%s:%d" % [address.host, address.list_port]
	if address.kind == KIND_HTTP:
		return str(address.text)
	return ""


## True for an address that names this machine.
static func is_loopback(host: String) -> bool:
	return host in ["127.0.0.1", "localhost", "::1", "0.0.0.0"] or host.begins_with("127.")

class_name MasterClient
extends Node
## Asks a master server (MasterServer) for the list of online games: GET <master>/servers.
## Each entry gets `address` (where to join: the address the master observed, or the master's own host when the server
## runs on the master's machine and so was observed as 127.0.0.1) and `list_origin` (where to ask it for info and ping).

signal received(servers: Array)
signal failed(reason: String)


## "192.168.1.5", "192.168.1.5:47710", "http://host:47710/" -> "http://host:47710"; "" when empty.
static func make_base_url(text: String) -> String:
	var t := text.strip_edges().rstrip("/")
	if t == "":
		return ""
	if not t.begins_with("http://") and not t.begins_with("https://"):
		t = "http://" + t
	var host_part := t.substr(t.find("://") + 3)
	if not ":" in host_part:
		t += ":%d" % MasterServer.DEFAULT_PORT
	return t


func fetch(master: String) -> void:
	var base := make_base_url(master)
	if base == "":
		failed.emit("No master server address is set (Options & tools > Options).")
		return
	JsonHttp.send(self, HTTPClient.METHOD_GET, base + "/servers", null, PackedStringArray(), func(code: int, data: Variant, _ms: int) -> void:
		if code != 200 or not data is Dictionary:
			failed.emit("No answer from the master server at %s" % base)
			return
		received.emit(make_entries(data.get("servers", []), base)))


## The entries of a /servers answer with `address` and `list_origin` filled in.
static func make_entries(servers: Array, base: String) -> Array:
	var master_host := ServerAddress.parse(base).get("host", "") as String
	var out := []
	for s in servers:
		if not s is Dictionary:
			continue
		var e: Dictionary = (s as Dictionary).duplicate()
		var host := str(e.get("ip", ""))
		if ServerAddress.is_loopback(host) and not ServerAddress.is_loopback(master_host):
			host = master_host   # the server runs on the master's machine
		var port := int(e.get("port", Net.GAME_PORT))
		e["address"] = host if port == Net.GAME_PORT else "%s:%d" % [host, port]
		if str(e.get("transport", "enet")) == Net.TRANSPORT_WS:
			e["address"] = "ws://%s:%d" % [host, port]
		e["list_origin"] = "http://%s:%d" % [host, int(e.list_port)] if int(e.get("list_port", 0)) > 0 else ""
		out.append(e)
	return out

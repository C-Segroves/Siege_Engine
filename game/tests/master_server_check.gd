extends Node
## The master server: the registry (register, heartbeat, expiry, list, validation, rate limit, unregister), the HTTP routes
## with an auth token, the address parser, and one real round trip over a socket (MasterClient, MasterPresence).
##   godot --headless --audio-driver Dummy --path game res://tests/master_server_check.tscn
## Prints "master_server_check: PASS" or "FAIL (n)"; exit code 0 / 1.

const PORT := 47731
const SERVER_IP := "10.9.8.7"
const OTHER_IP := "10.9.8.8"

var _failures := 0


func _ready() -> void:
	_check_registry()
	_check_validation()
	_check_rate_limit()
	_check_routes()
	_check_address_parsing()
	await _check_round_trip()
	print("master_server_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


static func _body(port := 47700, players := 2) -> Dictionary:
	return {"name": "Test server", "game": "deathmatch", "mode": "vs", "map": "Katabatic", "players": players, "max": 16,
		"password": true, "version": "siege-engine/2", "transport": "enet", "port": port, "list_port": 47702, "in_game": false}


static func _with(key: String, value: Variant) -> Dictionary:
	var b := _body()
	b[key] = value
	return b


func _check_registry() -> void:
	var r := MasterRegistry.new()
	var res := r.register(SERVER_IP, _body(), 100.0)
	_expect(res.code == 200 and res.body.id == "%s:47700" % SERVER_IP, "register answers the observed address and port")
	var list := r.list(110.0)
	_expect(list.size() == 1 and list[0].ip == SERVER_IP and list[0].players == 2 and list[0].password == true, "the list holds the entry with the observed ip")
	_expect(not list[0].has("expires") and list[0].age == 10, "the list shows the age, not the expiry")
	var claimed := _body()
	claimed["ip"] = "1.2.3.4"
	r.register(SERVER_IP, claimed, 100.0)
	_expect(r.list(100.0)[0].ip == SERVER_IP, "an ip claimed in the body is ignored")
	_expect(r.heartbeat(SERVER_IP, _body(47700, 5), 130.0).code == 200 and r.list(130.0)[0].players == 5, "heartbeat updates the player count")
	_expect(r.list(130.0 + MasterRegistry.TTL_SECONDS - 1.0).size() == 1, "a heartbeat keeps the entry alive for the ttl")
	_expect(r.list(130.0 + MasterRegistry.TTL_SECONDS + 1.0).is_empty(), "the entry expires after the ttl without a heartbeat")
	_expect(r.heartbeat(SERVER_IP, _body(), 400.0).code == 404, "a heartbeat of an expired entry is refused (register again)")
	r.register(SERVER_IP, _body(), 500.0)
	_expect(r.unregister(OTHER_IP, {"port": 47700}).code == 404 and r.size() == 1, "another address cannot remove the entry")
	_expect(r.unregister(SERVER_IP, {"port": 47700}).code == 200 and r.size() == 0, "unregister removes it")
	_expect(r.unregister(SERVER_IP, {"port": 47700}).code == 404, "unregister of nothing is 404")
	for p in range(1, MasterRegistry.MAX_PER_IP + 2):
		r.register(SERVER_IP, _body(47000 + p), 600.0)
	_expect(r.size() == MasterRegistry.MAX_PER_IP, "one address lists at most %d servers" % MasterRegistry.MAX_PER_IP)
	r.register(OTHER_IP, _body(47001), 600.0)
	_expect(r.list(600.0).filter(func(e: Dictionary) -> bool: return e.port == 47001).size() == 2, "two addresses may use the same port")


func _check_validation() -> void:
	var r := MasterRegistry.new()
	var bad := [
		["not an object", "text"], ["no port", {"name": "x", "max": 8}], ["port 0", _with("port", 0)], ["port 70000", _with("port", 70000)],
		["port as text", _with("port", "47700")], ["no name", _with("name", "  ")], ["name not text", _with("name", {"a": 1})],
		["max 0", _with("max", 0)], ["max huge", _with("max", 100000)], ["players over max", _with("players", 99)],
		["negative players", _with("players", -1)], ["bad transport", _with("transport", "tcp")], ["bad list port", _with("list_port", -5)]]
	for b in bad:
		_expect(r.register(SERVER_IP, b[1], 0.0).code == 400, "rejected: %s" % b[0])
	var e := _body()
	e["name"] = "a\nb\u0001c" + "x".repeat(200)
	e["secret"] = "must not be kept"
	r.register(SERVER_IP, e, 0.0)
	var kept: Dictionary = r.list(0.0)[0]
	_expect(kept.name.length() <= MasterRegistry.MAX_NAME and not "\n" in kept.name and not kept.has("secret"), "text is cleaned and capped, unknown fields are dropped")


func _check_rate_limit() -> void:
	var r := MasterRegistry.new()
	r.rate_limit = 5
	var allowed := 0
	for i in 10:
		if r.allow(SERVER_IP, 1000.0 + i):
			allowed += 1
	_expect(allowed == 5, "an address gets %d requests per window (got %d)" % [r.rate_limit, allowed])
	_expect(r.allow(OTHER_IP, 1000.0), "another address is not limited")
	_expect(r.allow(SERVER_IP, 1000.0 + MasterRegistry.RATE_WINDOW_SECONDS + 1.0), "the window resets")


func _request(method: String, path: String, body: Variant, ip := SERVER_IP, headers := {}) -> Dictionary:
	return {"method": method, "path": path, "query": "", "headers": headers, "body": JSON.stringify(body) if body != null else "", "ip": ip}


func _check_routes() -> void:
	var m := MasterServer.new()
	m.cfg = MasterServer.DEFAULTS.duplicate()
	m.cfg.auth_token = "s3cret"
	_expect(m.answer(_request("POST", "/register", _body())).code == 401, "register without the token is refused")
	var auth := {"authorization": "Bearer s3cret"}
	_expect(m.answer(_request("POST", "/register", _body(), SERVER_IP, auth)).code == 200, "register with the token works")
	_expect(m.answer(_request("POST", "/heartbeat", _body(), SERVER_IP, auth)).code == 200, "heartbeat with the token works")
	var listed: Variant = JSON.parse_string(m.answer(_request("GET", "/servers", null)).body)
	_expect(listed is Dictionary and listed.servers.size() == 1, "GET /servers needs no token and lists the server")
	_expect(m.answer(_request("DELETE", "/unregister", {"port": 47700}, SERVER_IP, auth)).code == 200, "DELETE /unregister works")
	_expect(m.answer(_request("GET", "/health", null)).body == "ok", "GET /health answers ok")
	_expect(m.answer(_request("GET", "/nothing", null)).code == 404, "an unknown path is 404")
	_expect(m.answer(_request("PUT", "/servers", null)).code == 404, "an unknown method is 404")
	var junk := m.answer({"method": "POST", "path": "/register", "query": "", "headers": auth, "body": "{not json", "ip": SERVER_IP})
	_expect(junk.code == 400, "a body that is not JSON is 400")
	m.free()


func _check_address_parsing() -> void:
	var a := ServerAddress.parse("192.168.1.20")
	_expect(a.ok and a.kind == "enet" and a.port == Net.GAME_PORT and a.text == "192.168.1.20", "an IP uses the default port")
	a = ServerAddress.parse(" 192.168.1.20:47800 ")
	_expect(a.ok and a.port == 47800 and a.text == "192.168.1.20:47800", "IP:port")
	a = ServerAddress.parse("game.example.org")
	_expect(a.ok and a.host == "game.example.org", "a host name")
	_expect(ServerAddress.parse("ws://host:47700/ws").kind == "ws", "a ws:// address")
	_expect(ServerAddress.parse("https://host").kind == "http", "an https:// address")
	_expect(not ServerAddress.parse("").ok and not ServerAddress.parse("a b").ok and not ServerAddress.parse("1.2.3.4:99999").ok
		and not ServerAddress.parse("1.2.3.4:x").ok, "empty, spaces and bad ports are refused")
	_expect(MasterClient.make_base_url("192.168.1.5") == "http://192.168.1.5:47710" and MasterClient.make_base_url("http://m.example:80/") == "http://m.example:80"
		and MasterClient.make_base_url("  ") == "", "master addresses are completed")
	var e := MasterClient.make_entries([{"ip": "127.0.0.1", "port": 47700, "list_port": 47702, "transport": "enet"}], "http://192.168.1.5:47710")
	_expect(e[0].address == "192.168.1.5" and e[0].list_origin == "http://192.168.1.5:47702", "a server seen as 127.0.0.1 is joined at the master's host")


## A master over a real socket; this process registers a fake hosted game with MasterPresence and a client lists it.
func _check_round_trip() -> void:
	var master := MasterServer.new()
	master.cfg = MasterServer.DEFAULTS.duplicate()
	master.cfg.port = PORT
	master.cfg.bind = "127.0.0.1"
	master.autostart = false
	add_child(master)
	master.start()
	await get_tree().process_frame
	Net.server_name = "Round trip"
	Net.max_players = 8
	Net.game_port = 47740
	var presence := MasterPresence.begin(self, "127.0.0.1:%d" % PORT, "", 0)
	presence.interval = 0.5
	var client := MasterClient.new()
	add_child(client)
	var got := []
	client.received.connect(func(s: Array) -> void: got.append(s))
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000 and (got.is_empty() or got[-1].is_empty()):
		client.fetch("127.0.0.1:%d" % PORT)
		await get_tree().create_timer(0.3).timeout
	_expect(not got.is_empty() and not got[-1].is_empty() and got[-1][0].name == "Round trip" and got[-1][0].port == 47740, "a client lists the server the master was told about")
	_expect(presence.registered, "the presence knows it is registered")
	master.registry.purge(MasterServer.now() + 1000.0)   # the master forgets everything (as after a restart)
	_expect(master.registry.size() == 0, "the master forgot the entry")
	await get_tree().create_timer(1.6).timeout   # the next heartbeat gets 404 and registers again
	_expect(master.registry.size() == 1, "the presence registers again after the master forgot it")
	presence.stop()
	await get_tree().create_timer(0.8).timeout
	_expect(master.registry.size() == 0, "stopping the presence unregisters")
	master.queue_free()
	client.queue_free()

extends Node
## End to end on this machine, no internet: a master server process, a dedicated server process started the way the
## "Run dedicated server" sheet does (LocalServer) that lists itself on the master, and this process as the client:
## it lists the server from the master, probes it (info and ping), joins at the listed address, leaves, joins by a typed
## "IP:port" address, leaves; then the server is stopped and its entry must expire from the master.
##   godot --headless --audio-driver Dummy --path game res://tests/master_lan_check.tscn
## Needs the game data next to game/ (the server loads it). Uses ports 47770 (game), 47772 (match list) and 47711 (master);
## run it alone. Prints "master_lan_check: PASS" or "FAIL (n)"; exit code 0 / 1.

const MASTER_PORT := 47711
const GAME_PORT := 47770
const LIST_PORT := 47772
const TTL_SECONDS := 6
const SERVER_NAME := "LAN check server"
const START_SECONDS := 90.0
const LIST_SECONDS := 20.0
const JOIN_SECONDS := 20.0

var _failures := 0
var _master_pid := -1
var _master_url := "127.0.0.1:%d" % MASTER_PORT


func _ready() -> void:
	await _run()
	LocalServer.stop()
	if _master_pid > 0:
		OS.kill(_master_pid)
	print("master_lan_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _expect(ok: bool, what: String) -> bool:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
	return ok


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().create_timer(0.1).timeout
	return cond.call()


func _list_from_master() -> Array:
	var client := MasterClient.new()
	add_child(client)
	var result := []
	var done := [false]
	client.received.connect(func(s: Array) -> void:
		result.append_array(s)
		done[0] = true)
	client.failed.connect(func(_r: String) -> void: done[0] = true)
	client.fetch(_master_url)
	await _wait_for(func() -> bool: return done[0], 5.0)
	client.queue_free()
	return result


## The master's entry of the server under test, waiting up to `seconds` for it; {} when it is not listed.
func _find_entry(seconds: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	while true:
		LocalServer.poll()
		for s in await _list_from_master():
			if s.name == SERVER_NAME:
				return s
		if Time.get_ticks_msec() - t0 >= seconds * 1000.0:
			break
		await get_tree().create_timer(0.5).timeout
	return {}


func _run() -> void:
	var project := ProjectSettings.globalize_path("res://")
	_master_pid = OS.create_process(OS.get_executable_path(), ["--headless", "--audio-driver", "Dummy", "--path", project,
		"res://server/master_server.tscn", "--", "--port=%d" % MASTER_PORT, "--bind=127.0.0.1", "--ttl=%d" % TTL_SECONDS])
	if not _expect(_master_pid > 0, "the master process started"):
		return
	var err := LocalServer.start({"name": SERVER_NAME, "port": GAME_PORT, "list_port": LIST_PORT, "max_players": 8, "mode": "vs",
		"master": _master_url, "lobby_seconds": 600, "stats_seconds": 0})
	if not _expect(err == OK, "LocalServer starts the dedicated server"):
		return
	var ready := await _wait_for(func() -> bool:
		LocalServer.poll()
		return LocalServer.make_state() == "running", START_SECONDS)
	_expect(ready, "the server reports READY (log: %s)" % [LocalServer.tail(3)])
	if not ready:
		return
	var entry := await _find_entry(LIST_SECONDS)
	if entry.is_empty():
		print("  server log: %s" % [LocalServer.tail(8)])
	if not _expect(not entry.is_empty(), "the dedicated server registered with the master"):
		return
	_expect(entry.port == GAME_PORT and entry.max == 8 and entry.list_port == LIST_PORT and entry.address == "127.0.0.1" + ("" if GAME_PORT == Net.GAME_PORT else ":%d" % GAME_PORT)
		and entry.password == false and entry.version == Net.PROTOCOL, "the entry carries the port, the size, the list port and the version")
	await _check_probe(str(entry.list_origin))
	await _join_and_leave(str(entry.address), "the listed address")
	await _join_and_leave("127.0.0.1:%d" % GAME_PORT, "a typed IP:port")
	LocalServer.stop()
	var t0 := Time.get_ticks_msec()
	var still_listed := not (await _find_entry(0.0)).is_empty()
	while still_listed and Time.get_ticks_msec() - t0 < TTL_SECONDS * 3000.0:
		await get_tree().create_timer(1.0).timeout
		still_listed = not (await _find_entry(0.0)).is_empty()
	_expect(not still_listed, "the entry expires after the server stopped (%.0f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))


func _check_probe(origin: String) -> void:
	var probe := ServerProbe.new()
	add_child(probe)
	var got := []
	probe.probe(origin, func(ok: bool, info: Dictionary, ms: int) -> void: got.append([ok, info, ms]))
	await _wait_for(func() -> bool: return not got.is_empty(), 5.0)
	_expect(not got.is_empty() and got[0][0] and got[0][1].name == SERVER_NAME and got[0][2] >= 0, "the probe reads the server info and a ping (%s)" % [got])
	probe.queue_free()


func _join_and_leave(address_text: String, what: String) -> void:
	var address := ServerAddress.parse(address_text)
	var joined := [false]
	var on_joined := func() -> void: joined[0] = true
	Net.connected_to_server.connect(on_joined)
	var err := Net.join(str(address.host), int(address.port))
	var in_roster := false
	if err == OK:
		in_roster = await _wait_for(func() -> bool: return Net.roster.has(Net.my_id()), JOIN_SECONDS)
	_expect(err == OK and joined[0] and in_roster, "joined by %s (%s)" % [what, address_text])
	Net.connected_to_server.disconnect(on_joined)
	Net.leave()
	await get_tree().create_timer(1.0).timeout

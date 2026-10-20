extends Node
## A pilot connected when a match starts stays connected through the map load. The host and the client both build the
## same big battle (Varuna's Fall when the Tribes 2 pack is installed, else a versus match on the first map) while
## their main loops are busy; both ENet peers are given a 4 s timeout, far below the load, so only the load code
## servicing the peer (LoadKeepAlive.pump) keeps the session. One command; the host starts the client as a child
## process (killed by its pid at the end).
##   godot --headless --audio-driver Dummy --path game res://tests/net_load_keepalive_check.tscn [-- --map=fallback|varuna] [--control]
## --control turns the keep-alive off and expects the session to be dropped (proves the test can fail).
## Prints "net_load_keepalive_check: OK" or "FAILED: <why>"; exit code 0 / 1.

## The host picks a port from its process id (other checks may run at the same time); the client gets it as --port=.
const PORT_BASE := 47800
const PORT_SPAN := 150
const BATTLE_SCENE := "res://games/es1/battle.tscn"
const CONNECT_SECONDS := 30.0
const AFTER_SECONDS := 3.0
const LOAD_LIMIT_SECONDS := 240.0
const TIMEOUT_LIMIT := 2
const TIMEOUT_MIN_MS := 3000
const TIMEOUT_MAX_MS := 4000
## The longest time the load may go without servicing the peer: well inside the timeout.
const MAX_GAP_MS := 2000

var _role := "host"
var _map := "auto"
var _control := false
var _left: Array[int] = []
var _ended := [false]
var _battle: Battle
var _gap_ms := -1
var _port := PORT_BASE + OS.get_process_id() % PORT_SPAN
var _verdict_path := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.substr(7)
		elif a.begins_with("--map="):
			_map = a.substr(6)
		elif a.begins_with("--port="):
			_port = int(a.substr(7))
		elif a.begins_with("--verdict="):
			_verdict_path = a.substr(10)
		elif a == "--control":
			_control = true
	LoadKeepAlive.enabled = not _control
	Net.player_name = "Host" if _role == "host" else "Client"
	Net.game_starting.connect(_on_game_starting)
	Net.session_ended.connect(func(_r: String) -> void: _ended[0] = true)
	Net.player_left.connect(func(id: int) -> void:
		_left.append(id)
		print("net_load_keepalive_check %s: peer %d left at %d ms" % [_role, id, Time.get_ticks_msec()]))
	if _role == "client":
		_run_client.call_deferred()
	else:
		_run_host.call_deferred()


func _finish(ok: bool, why := "") -> void:
	var verdict := "OK" if ok else "FAILED: " + why
	print("net_load_keepalive_check%s: %s" % ["" if _role == "host" else " client", verdict])
	if _role == "client" and _verdict_path != "":
		# stay connected (a client that quits would look like a dropped one); the host reads this and kills us
		var f := FileAccess.open(_verdict_path, FileAccess.WRITE)
		f.store_string(verdict)
		f.close()
		return
	get_tree().quit(0 if ok else 1)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _shorten_timeout(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	enet.get_peer(peer_id).set_timeout(TIMEOUT_LIMIT, TIMEOUT_MIN_MS, TIMEOUT_MAX_MS)


## Both sides build the battle the host's config describes; the time between two services of the peer is measured.
func _on_game_starting(cfg: Dictionary) -> void:
	print("net_load_keepalive_check %s: load starts at %d ms" % [_role, Time.get_ticks_msec()])
	_battle = load(BATTLE_SCENE).instantiate()
	_battle.config = cfg
	LoadKeepAlive.begin()
	get_tree().root.add_child(_battle)
	await get_tree().physics_frame   # an extraction raid is set up (map, caches, garrisons) one physics frame after _ready
	await get_tree().process_frame
	_gap_ms = LoadKeepAlive.end()
	print("net_load_keepalive_check %s: load ends at %d ms" % [_role, Time.get_ticks_msec()])
	print("net_load_keepalive_check %s: battle built, longest gap %d ms, %d services" % [_role, _gap_ms, LoadKeepAlive.service_count()])


func _make_config() -> Dictionary:
	var world = preload("res://tests/server_bench_world.gd").new()
	var kind: String = world.make_kind(_map)
	var peers := Net.roster.keys()
	var cfg: Dictionary = world.make_config(kind, peers, 8)
	print("net_load_keepalive_check: building a %s match" % kind)
	return cfg


func _run_host() -> void:
	if Net.host(_port) != OK:
		_finish(false, "cannot host on port %d" % _port)
		return
	var log_path := OS.get_cache_dir().path_join("net_load_keepalive_client_%d.log" % OS.get_process_id())
	var verdict_path := log_path + ".verdict"
	DirAccess.remove_absolute(verdict_path)
	var args := ["--headless", "--audio-driver", "Dummy", "--log-file", log_path, "--path", ProjectSettings.globalize_path("res://"),
		"res://tests/net_load_keepalive_check.tscn", "--", "--role=client", "--port=%d" % _port, "--map=" + _map, "--verdict=" + verdict_path]
	if _control:
		args.append("--control")
	var pid := OS.create_process(OS.get_executable_path(), args)
	if pid <= 0:
		_finish(false, "cannot start the client process")
		return
	if not await _wait_for(func() -> bool: return Net.roster.size() >= 2, CONNECT_SECONDS):
		OS.kill(pid)
		_finish(false, "the client never joined")
		return
	var client_id := 0
	for id in Net.roster:
		if int(id) != 1:
			client_id = int(id)
	_shorten_timeout(client_id)
	var cfg := _make_config()
	cfg["extraction_seed"] = 4242
	Net.start_game(cfg)   # the host builds the battle here; the client builds it as soon as it receives the config
	await _wait_for(func() -> bool: return _gap_ms >= 0, LOAD_LIMIT_SECONDS)
	await get_tree().create_timer(AFTER_SECONDS).timeout
	var client_done := await _wait_for(func() -> bool: return FileAccess.file_exists(verdict_path), LOAD_LIMIT_SECONDS)
	var kept := Net.roster.has(client_id) and not _left.has(client_id)
	var client_verdict := FileAccess.get_file_as_string(verdict_path) if client_done else "no verdict"
	var client_running := OS.is_process_running(pid)
	OS.kill(pid)
	if FileAccess.file_exists(log_path):
		print("--- client log ---
" + FileAccess.get_file_as_string(log_path).strip_edges())
		DirAccess.remove_absolute(log_path)
	DirAccess.remove_absolute(verdict_path)
	if _control:
		_finish(not kept, "the control run kept the client without any servicing: the test cannot fail") if kept else _finish(true)
	elif _gap_ms > MAX_GAP_MS:
		_finish(false, "the host went %d ms without servicing the peer (limit %d)" % [_gap_ms, MAX_GAP_MS])
	elif not kept:
		_finish(false, "the host dropped the client during the load (left %s)" % [_left])
	elif not client_running:
		_finish(false, "the client ended early (it reports its own failure above)")
	else:
		_finish(client_verdict == "OK", "the client says: " + client_verdict)


func _run_client() -> void:
	if Net.join("127.0.0.1", _port) != OK:
		_finish(false, "cannot join")
		return
	if not await _wait_for(func() -> bool: return Net.roster.has(Net.my_id()), CONNECT_SECONDS):
		_finish(false, "never registered with the host")
		return
	_shorten_timeout(1)
	if not await _wait_for(func() -> bool: return _battle != null and _gap_ms >= 0, LOAD_LIMIT_SECONDS):
		_finish(false, "the match never started (the host dropped us or never began)")
		return
	await get_tree().create_timer(AFTER_SECONDS).timeout
	if _control:
		_finish(true)
	elif _ended[0] or multiplayer.multiplayer_peer == null or not Net.roster.has(Net.my_id()):
		_finish(false, "the session ended during the load")
	elif _gap_ms > MAX_GAP_MS:
		_finish(false, "the client went %d ms without servicing the peer (limit %d)" % [_gap_ms, MAX_GAP_MS])
	else:
		_finish(true)

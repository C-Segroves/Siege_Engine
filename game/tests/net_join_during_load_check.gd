extends Node
## A pilot who joins while the host is busy loading a big map is not dropped for the host's silence. The host starts
## a match alone and builds the battle (Varuna's Fall when the Tribes 2 pack is installed, else a versus match on the
## first map) with its main loop blocked; a client process, waiting for a gate file the host writes just before the
## load, joins at that moment. Only the load code servicing the peer (LoadKeepAlive.pump) lets the ENet handshake
## complete. The match is already starting, so the host answers the registration with its documented refusal
## ("Game already in progress"); that answer, or a registration, is a pass. A lost connection or a closed session
## (no answer at all) is the failure LAN joiners reported as "sometimes kicked" (docs/PLAYTEST, USER_TODO).
##   godot --headless --audio-driver Dummy --path game res://tests/net_join_during_load_check.tscn [-- --map=fallback|varuna]
## There is no --control run: ENet's connect handshake alone survives a 24 s host stall (its connect timeout is
## 30 s), so a host without the servicing still answers once the load ends. The test guards the answer (a lost join
## or a refusal other than the documented one fails it) and the host's servicing gap.
## Prints "net_join_during_load_check: OK" or "FAILED: <why>"; exit code 0 / 1.

const PORT_BASE := 47950
const PORT_SPAN := 40
const BATTLE_SCENE := "res://games/es1/battle.tscn"
const CLIENT_UP_SECONDS := 60.0
const ANSWER_SECONDS := 60.0
const LOAD_LIMIT_SECONDS := 240.0
const REFUSAL_IN_GAME := "Game already in progress"
const NO_ANSWER := "no answer"
const POLL_MS := 50

var _role := "host"
var _map := "auto"
var _port := PORT_BASE + OS.get_process_id() % PORT_SPAN
var _gate_path := ""
var _verdict_path := ""
var _answer := NO_ANSWER
var _gap_ms := -1
var _load_ms := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.substr(7)
		elif a.begins_with("--map="):
			_map = a.substr(6)
		elif a.begins_with("--port="):
			_port = int(a.substr(7))
		elif a.begins_with("--gate="):
			_gate_path = a.substr(7)
		elif a.begins_with("--verdict="):
			_verdict_path = a.substr(10)
	Net.player_name = "Host" if _role == "host" else "Client"
	Net.game_starting.connect(_on_game_starting)
	if _role == "client":
		_run_client.call_deferred()
	else:
		_run_host.call_deferred()


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ------------------------------------------------------------------ host

## The host builds the battle its config describes while the main loop is blocked; the gate is already open.
func _on_game_starting(cfg: Dictionary) -> void:
	_load_ms = Time.get_ticks_msec()
	var battle: Battle = load(BATTLE_SCENE).instantiate()
	battle.config = cfg
	LoadKeepAlive.begin()
	get_tree().root.add_child(battle)
	await get_tree().physics_frame
	await get_tree().process_frame
	_gap_ms = LoadKeepAlive.end()
	_load_ms = Time.get_ticks_msec() - _load_ms
	print("net_join_during_load_check: battle built in %d ms, longest gap %d ms, %d services" % [_load_ms, _gap_ms, LoadKeepAlive.service_count()])


func _make_config() -> Dictionary:
	var world = preload("res://tests/server_bench_world.gd").new()
	return world.make_config(world.make_kind(_map), [1], 8)


func _start_client_process() -> int:
	var cache := OS.get_cache_dir()
	_gate_path = cache.path_join("net_join_during_load_%d.gate" % OS.get_process_id())
	_verdict_path = cache.path_join("net_join_during_load_%d.verdict" % OS.get_process_id())
	for p in [_gate_path, _gate_path + ".up", _verdict_path]:
		DirAccess.remove_absolute(p)
	var args := ["--headless", "--audio-driver", "Dummy", "--path", ProjectSettings.globalize_path("res://"),
		"res://tests/net_join_during_load_check.tscn", "--", "--role=client", "--port=%d" % _port,
		"--gate=" + _gate_path, "--verdict=" + _verdict_path]
	return OS.create_process(OS.get_executable_path(), args)


func _run_host() -> void:
	if Net.host(_port) != OK:
		_finish(false, "cannot host on port %d" % _port)
		return
	var pid := _start_client_process()
	if pid <= 0 or not await _wait_for(func() -> bool: return FileAccess.file_exists(_gate_path + ".up"), CLIENT_UP_SECONDS):
		OS.kill(pid)
		_finish(false, "the client process never came up")
		return
	var cfg := _make_config()
	cfg["extraction_seed"] = 4242
	_write(_gate_path, "go")   # the client joins now; this main loop is blocked from the next line on
	Net.start_game(cfg)
	await _wait_for(func() -> bool: return _gap_ms >= 0, LOAD_LIMIT_SECONDS)
	var done := await _wait_for(func() -> bool: return FileAccess.file_exists(_verdict_path), ANSWER_SECONDS)
	var verdict := FileAccess.get_file_as_string(_verdict_path) if done else "no verdict"
	OS.kill(pid)
	for p in [_gate_path, _gate_path + ".up", _verdict_path]:
		DirAccess.remove_absolute(p)
	if _gap_ms > LoadKeepAlive.INTERVAL_MS * 20:
		_finish(false, "the host went %d ms without servicing the peer" % _gap_ms)
	else:
		_finish(verdict == "OK", "the client says: " + verdict)


# ------------------------------------------------------------------ client

func _run_client() -> void:
	_write(_gate_path + ".up", "up")
	while not FileAccess.file_exists(_gate_path):
		await get_tree().create_timer(POLL_MS / 1000.0).timeout
	var joined_msec := Time.get_ticks_msec()
	Net.session_ended.connect(func(reason: String) -> void: _answer = reason)
	Net.connection_failed.connect(func() -> void: _answer = "connection failed")
	if Net.join("127.0.0.1", _port) != OK:
		_finish(false, "cannot join")
		return
	await _wait_for(func() -> bool: return Net.roster.has(Net.my_id()) or _answer != NO_ANSWER, ANSWER_SECONDS)
	var registered := Net.roster.has(Net.my_id())
	print("net_join_during_load_check client: answer '%s' registered %s after %d ms" % [_answer, registered, Time.get_ticks_msec() - joined_msec])
	if registered or _answer == REFUSAL_IN_GAME:
		_finish(true)
	else:
		_finish(false, "no answer from the host's load: '%s'" % _answer)


func _finish(ok: bool, why := "") -> void:
	var verdict := "OK" if ok else "FAILED: " + why
	print("net_join_during_load_check%s: %s" % ["" if _role == "host" else " client", verdict])
	if _role == "client":
		_write(_verdict_path, verdict)   # stay connected; the host reads this and kills this process
		return
	get_tree().quit(0 if ok else 1)

extends Node
## A client that is slow to load the map (its main loop stalls, so it sends and acks nothing) is not dropped:
## the ENet peer timeouts of Net (PEER_TIMEOUT_*) outlast the stall. One command; the host role starts the
## client as a child process (killed by its pid at the end).
##   godot --headless --audio-driver Dummy --path game res://tests/net_slow_load_check.tscn
## Prints "net_slow_load_check: OK" or "FAILED: <why>"; exit code 0 / 1.

const PORT := 47767
const STALL_SECONDS := 12.0   # well past ENet's default 5 s minimum timeout, within PEER_TIMEOUT_MIN_MS
const CONNECT_SECONDS := 30.0
const AFTER_SECONDS := 3.0

var _role := "host"
var _left: Array[int] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.substr(7)
	if _role == "client":
		Net.player_name = "Slow"
		_run_client.call_deferred()
	else:
		Net.player_name = "Host"
		_run_host.call_deferred()


func _finish(ok: bool, why := "") -> void:
	if _role == "host":
		print("net_slow_load_check: %s" % ("OK" if ok else "FAILED: " + why))
	else:
		print("net_slow_load_check client: %s" % ("OK" if ok else "FAILED: " + why))
	get_tree().quit(0 if ok else 1)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _run_host() -> void:
	if Net.host(PORT) != OK:
		_finish(false, "cannot host on port %d" % PORT)
		return
	Net.player_left.connect(func(id: int) -> void: _left.append(id))
	var args := ["--headless", "--audio-driver", "Dummy", "--path", ProjectSettings.globalize_path("res://"),
		"res://tests/net_slow_load_check.tscn", "--", "--role=client"]
	var pid := OS.create_process(OS.get_executable_path(), args)
	if pid <= 0:
		_finish(false, "cannot start the client process")
		return
	var joined := await _wait_for(func() -> bool: return Net.roster.size() >= 2, CONNECT_SECONDS)
	if not joined:
		OS.kill(pid)
		_finish(false, "the client never joined")
		return
	# the client now stalls; the host keeps running and must keep the peer
	await get_tree().create_timer(STALL_SECONDS + AFTER_SECONDS).timeout
	var kept := Net.roster.size() >= 2 and _left.is_empty()
	var client_running := OS.is_process_running(pid)
	OS.kill(pid)
	if not kept:
		_finish(false, "the host dropped the stalled client (left %s, roster %d)" % [_left, Net.roster.size()])
	elif not client_running:
		_finish(false, "the client ended early (it reports its own failure above)")
	else:
		_finish(true)


func _run_client() -> void:
	if Net.join("127.0.0.1", PORT) != OK:
		_finish(false, "cannot join")
		return
	var dropped := [false]
	Net.session_ended.connect(func(_r: String) -> void: dropped[0] = true)
	if not await _wait_for(func() -> bool: return Net.roster.has(Net.my_id()), CONNECT_SECONDS):
		_finish(false, "never registered with the host")
		return
	OS.delay_msec(int(STALL_SECONDS * 1000.0))   # loading a big map: nothing is polled or acknowledged
	await get_tree().create_timer(AFTER_SECONDS).timeout
	if dropped[0] or not Net.roster.has(Net.my_id()):
		_finish(false, "the host dropped this client after a %.0f s stall" % STALL_SECONDS)
	else:
		_finish(true)

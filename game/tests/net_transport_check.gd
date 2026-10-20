extends Node
## ENet is the dedicated server's default transport and it holds 64 pilots: a dedicated host on loopback accepts 64
## ENet clients, refuses the 65th, and reports 64 as its capacity. Prints "NET TRANSPORT OK" / "NET TRANSPORT FAILED: <why>".
##   godot --headless --audio-driver Dummy --path game res://tests/net_transport_check.tscn
const PORT := 47795
const CONNECT_SECONDS := 20.0
const REFUSE_SECONDS := 3.0

var _clients: Array[ENetMultiplayerPeer] = []


func _ready() -> void:
	_run.call_deferred()


func _done(ok: bool, why := "") -> void:
	print("NET TRANSPORT %s" % ("OK" if ok else "FAILED: " + why))
	for c in _clients:
		c.close()
	Net.leave()
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if ok else 1)


func _count_connected() -> int:
	var n := 0
	for c in _clients:
		c.poll()
		if c.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			n += 1
	return n


func _add_client() -> void:
	var c := ENetMultiplayerPeer.new()
	if c.create_client("127.0.0.1", PORT) != OK:
		return
	_clients.append(c)


func _wait(seconds: float, until: Callable) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if until.call():
			return true
		await get_tree().process_frame
	return false


func _run() -> void:
	if Net.MAX_PLAYERS != 64:
		return _done(false, "Net.MAX_PLAYERS is %d, not 64" % Net.MAX_PLAYERS)
	if ServerConfig.DEFAULTS.transport != Net.TRANSPORT_ENET:
		return _done(false, "the dedicated server's default transport is %s, not enet" % ServerConfig.DEFAULTS.transport)
	Net.max_players = Net.MAX_PLAYERS
	if Net.host(PORT, Net.TRANSPORT_ENET, true) != OK:
		return _done(false, "cannot host on %d" % PORT)
	if int(Net.make_match_info().max) != 64:
		return _done(false, "match info says max %s" % Net.make_match_info().max)
	for i in 64:
		_add_client()
	if not await _wait(CONNECT_SECONDS, func() -> bool: return _count_connected() == 64):
		return _done(false, "%d of 64 clients connected" % _count_connected())
	_add_client()
	await _wait(REFUSE_SECONDS, func() -> bool: return false)
	if _count_connected() != 64:
		return _done(false, "the 65th client was admitted (%d connected)" % _count_connected())
	_done(true)

extends Node
## Server side of the WebSocket end-to-end check: a dedicated server (no local pilot) plays a versus match with one
## AI unit (owned by the server, peer 1) for a client that joins over WebSocket (the e2e driver's lan_join --transport=ws --dedicated --mode=vs).
##   server: godot --headless --audio-driver Dummy --path game res://tests/server_ws_check.tscn -- --port=47790
##           --transport=ws --ai=1 --results_seconds=3 --lobby_seconds=5
##   client: godot --audio-driver Dummy --path game res://tests/e2e_driver.tscn -- --flow=lan_join --transport=ws
##           --dedicated --mode=vs --port=47790 --shots=<dir>
## The pilot must move (host-simulated from the client's input), the server kills the AI unit, ends the match, and
## starts the next match by itself. Prints "SERVER WS OK" / "SERVER WS FAILED: <why>" and quits 0 / 1.

const JOIN_SECONDS := 120.0
const MOVE_SECONDS := 10.0
const PLAY_SECONDS := 24.0
const NEXT_MATCH_SECONDS := 60.0

var _server: DedicatedServer
var _battles := 0


func _ready() -> void:
	_server = DedicatedServer.new()
	add_child(_server)
	Net.game_starting.connect(func(_c: Dictionary) -> void: _battles += 1)
	_run.call_deferred()


func _done(ok: bool, why := "") -> void:
	print("SERVER WS %s" % ("OK" if ok else "FAILED: " + why))
	var tree := get_tree()
	await tree.create_timer(1.0).timeout
	tree.quit(0 if ok else 1)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _remote_pilot(b: Battle) -> Herc:
	for v in b.vehicles.values():
		if is_instance_valid(v) and int(v.owner_peer) > 1:
			return v
	return null


func _run() -> void:
	if not await _wait_for(func() -> bool:
		return _server._battle is Battle and _remote_pilot(_server._battle) != null, JOIN_SECONDS):
		_done(false, "no client in a match")
		return
	var b: Battle = _server._battle
	if b.player != null:
		_done(false, "the dedicated server has a local pilot")
		return
	var pilot := _remote_pilot(b)
	var p0 := pilot.global_position
	if not await _wait_for(func() -> bool: return pilot.global_position.distance_to(p0) > 3.0, MOVE_SECONDS + 20.0):
		_done(false, "the client's pilot never moved")
		return
	print("  pilot moved %.1f m" % pilot.global_position.distance_to(p0))
	await _wait_for(func() -> bool: return b.match_seconds() > PLAY_SECONDS, PLAY_SECONDS)   # the client runs its checks
	var victim: Herc = null
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v != pilot and v.alive and int(v.owner_peer) == 1 and v.team != pilot.team:
			victim = v
			break
	if victim == null:
		var seen := get_tree().get_nodes_in_group("vehicles").map(func(v) -> String: return "%s owner %s team %s alive %s" % [v.name, v.owner_peer, v.team, v.alive])
		_done(false, "no AI unit to kill: %s" % [seen])
		return
	var n := 0
	while victim.alive and n < 50:
		victim.apply_hit(1e6, 1e6, pilot, victim.global_position)
		n += 1
	if victim.alive:
		_done(false, "the AI unit survived")
		return
	await get_tree().create_timer(4.0).timeout
	b.end_match("QA end")
	var first := _battles
	if not await _wait_for(func() -> bool: return _battles > first, NEXT_MATCH_SECONDS):
		_done(false, "no second match after the first one ended")
		return
	_done(true)

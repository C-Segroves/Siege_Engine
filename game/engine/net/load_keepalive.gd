class_name LoadKeepAlive
extends RefCounted
## Keeps the network session alive while the main loop is busy loading a big map (Varuna's Fall builds for seconds,
## and a LAN host or client builds the same battle at once). The load code calls pump() between its steps: it
## services the multiplayer peer (ENet acknowledges, pings, resends; WebSocket answers pings) without dispatching any
## game packet, which stays queued in the peer until the scene tree's own multiplayer poll. Without it the peer on
## the other end sees silence for the whole load and drops us (Net.PEER_TIMEOUT_MIN_MS).
##   LoadKeepAlive.begin() ... LoadKeepAlive.pump() ... LoadKeepAlive.end() -> the longest gap in ms between two services.

## Real time between two services of the peer; far below ENet's 500 ms ping interval.
const INTERVAL_MS := 100

## False only in tests/net_load_keepalive_check --control (shows that the check fails without the servicing).
static var enabled := true
static var _last_service_ms := 0
static var _longest_gap_ms := 0
static var _services := 0


## Starts measuring a load (resets the longest gap and the service count).
static func begin() -> void:
	_last_service_ms = Time.get_ticks_msec()
	_longest_gap_ms = 0
	_services = 0


## Ends the measurement; the longest time the main loop went without servicing the peer during the load.
static func end() -> int:
	_note_gap(Time.get_ticks_msec())
	return _longest_gap_ms


## How many times the peer was serviced since begin().
static func service_count() -> int:
	return _services


## Services the session's peer when INTERVAL_MS have passed since the last service. Cheap enough for loop bodies.
static func pump() -> void:
	if not enabled:
		return
	var now := Time.get_ticks_msec()
	if now - _last_service_ms < INTERVAL_MS:
		return
	_note_gap(now)
	_last_service_ms = now
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var peer := tree.get_multiplayer().multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	peer.poll()
	_services += 1


static func _note_gap(now: int) -> void:
	_longest_gap_ms = maxi(_longest_gap_ms, now - _last_service_ms)

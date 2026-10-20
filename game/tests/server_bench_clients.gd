extends RefCounted
## Loopback ENet "players" for tests/server_load_bench: each one is a raw ENetConnection that connects to the
## server under its own peer id (the connect data is the id, as ENetMultiplayerPeer clients send it), keeps the
## connection serviced and counts the bytes the server sends it. They carry no game scene, so the server's cost
## for them is exactly the network side (ENet send queues, snapshot RPC fan-out); the bench drives their soldiers
## on the server side. A worker thread services them, so a long map load on the main thread (the server and the
## clients share one process) does not make ENet time them out.

const FIRST_PEER_ID := 1000
const HOST_PEER_SLOTS := 1
const SERVICE_PAUSE_MS := 4
## The server's main loop is blocked while it builds the map (tens of seconds); these clients must outlast that,
## which Net's own peer timeouts (15 s minimum) do not (a finding of the bench: see docs).
const TIMEOUT_LIMIT := 256
const TIMEOUT_MIN_MS := 120000
const TIMEOUT_MAX_MS := 300000

var _hosts: Array[ENetConnection] = []
var _peer_ids: Array[int] = []
var _connected := {}   # peer id -> bool
var _received_bytes := 0.0
var _lock := Mutex.new()
var _thread := Thread.new()
var _running := false


## Starts connecting `count` clients to 127.0.0.1:`port` and servicing them.
func open(port: int, count: int) -> void:
	for i in count:
		var host := ENetConnection.new()
		host.create_host(HOST_PEER_SLOTS)
		var id := FIRST_PEER_ID + i
		var peer := host.connect_to_host("127.0.0.1", port, 0, id)
		if peer == null:
			push_error("bench client %d cannot start connecting" % id)
			continue
		peer.set_timeout(TIMEOUT_LIMIT, TIMEOUT_MIN_MS, TIMEOUT_MAX_MS)
		_hosts.append(host)
		_peer_ids.append(id)
		_connected[id] = false
	_running = true
	_thread.start(_service_loop)


func _service_loop() -> void:
	while _running:
		for i in _hosts.size():
			_service_one(_hosts[i], _peer_ids[i])
		OS.delay_msec(SERVICE_PAUSE_MS)


func _service_one(host: ENetConnection, id: int) -> void:
	var event: Array = host.service(0)
	while event[0] != ENetConnection.EVENT_NONE and event[0] != ENetConnection.EVENT_ERROR:
		_lock.lock()
		match event[0]:
			ENetConnection.EVENT_CONNECT:
				_connected[id] = true
			ENetConnection.EVENT_DISCONNECT:
				_connected[id] = false
			ENetConnection.EVENT_RECEIVE:
				_received_bytes += (event[1] as ENetPacketPeer).get_packet().size()
		_lock.unlock()
		event = host.service(0)


## Peer ids of the clients that are connected now.
func make_connected_ids() -> Array[int]:
	var out: Array[int] = []
	_lock.lock()
	for id in _peer_ids:
		if _connected[id]:
			out.append(id)
	_lock.unlock()
	return out


## Bytes the server sent the clients since the last reset_received.
func make_received_bytes() -> float:
	_lock.lock()
	var bytes := _received_bytes
	_lock.unlock()
	return bytes


func reset_received() -> void:
	_lock.lock()
	_received_bytes = 0.0
	_lock.unlock()


func close() -> void:
	_running = false
	if _thread.is_started():
		_thread.wait_to_finish()
	for host in _hosts:
		host.destroy()
	_hosts.clear()

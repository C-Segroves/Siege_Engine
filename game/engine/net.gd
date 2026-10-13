extends Node
## LAN multiplayer session: hosting/joining (ENet), LAN server discovery (UDP broadcast) and the
## lobby roster. The host is authoritative for the whole simulation; clients send inputs.

signal roster_changed
signal servers_changed
signal connected_to_server
signal connection_failed
signal session_ended(reason: String)
signal game_starting(config: Dictionary)

const GAME_PORT := 47700
const DISCOVERY_PORT := 47701
const MAX_PLAYERS := 24
const PROTOCOL := "siege-engine/1"
## The roster team of a pilot of a team match who has no team yet (TeamAssignment.UNASSIGNED).
const NO_TEAM := -1
## Roster entry keys a pilot may set (set_my_info): the PlayerProfile keys carry his soldier's armour, body and
## skins.
const ROSTER_KEYS := ["vehicle", "team", "ready", "loadout", "name", "kit", "infantry_armor", "infantry_body",
	"infantry_skin", "herc_skin"]

## The local player's name (PlayerProfile: saved in the settings, edited in Options and the lobby).
var player_name := "Pilot"
## peer_id -> {name, vehicle, team, ready, loadout, kit (extraction raids: ExtractionProfile.make_kit_dict)}
var roster := {}
## LAN servers seen: "ip:port" -> {name, mode, players, max, ip, port, seen}
var servers := {}
## Session settings chosen by the host (mode, arena/mission, teams, ...)
var settings := {"mode": "vs", "map": "", "teams": false, "ai": 0}

var _udp_broadcast: PacketPeerUDP
var _udp_listen: PacketPeerUDP
var _bcast_t := 0.0
var _in_game := false


func _ready() -> void:
	player_name = PlayerProfile.load_name()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func(): connected_to_server.emit(); _register.rpc_id(1, player_name, PROTOCOL))
	multiplayer.connection_failed.connect(func(): _reset(); connection_failed.emit())
	multiplayer.server_disconnected.connect(func(): _reset(); session_ended.emit("Host closed the session"))


func is_online() -> bool:
	return multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer)


func is_host() -> bool:
	return multiplayer.is_server()


func my_id() -> int:
	return multiplayer.get_unique_id()


# ------------------------------------------------------------------ hosting / joining

func host(port := GAME_PORT) -> Error:
	if WebPlatform.is_active():
		_host_local()
		return OK
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	roster.clear()
	roster[1] = _new_entry(player_name)
	_udp_broadcast = PacketPeerUDP.new()
	_udp_broadcast.set_broadcast_enabled(true)
	_udp_broadcast.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	roster_changed.emit()
	return OK


## Browser build: no sockets (ENet, UDP), so hosting opens a local-only session (peer id 1) and matches
## start locally, exactly as start_game does for an offline host.
func _host_local() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	roster.clear()
	roster[1] = _new_entry(player_name)
	roster_changed.emit()


func join(address: String, port := GAME_PORT) -> Error:
	if WebPlatform.is_active():
		return ERR_UNAVAILABLE
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	return OK


func leave() -> void:
	_reset()
	session_ended.emit("Left session")


func _reset() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	roster.clear()
	_udp_broadcast = null
	_in_game = false
	roster_changed.emit()


func _new_entry(n: String) -> Dictionary:
	return {"name": n, "vehicle": "es1:RAPTOR", "team": 0, "ready": false, "loadout": []}


# ------------------------------------------------------------------ discovery

func start_discovery() -> void:
	if _udp_listen or WebPlatform.is_active():
		return
	_udp_listen = PacketPeerUDP.new()
	if _udp_listen.bind(DISCOVERY_PORT) != OK:
		push_warning("LAN discovery port busy")
		_udp_listen = null


func stop_discovery() -> void:
	if _udp_listen:
		_udp_listen.close()
	_udp_listen = null


func _process(delta: float) -> void:
	if _udp_broadcast and is_host():
		_bcast_t -= delta
		if _bcast_t <= 0.0:
			_bcast_t = 1.0
			var info := {"proto": PROTOCOL, "name": "%s's game" % player_name, "mode": settings.mode,
				"map": settings.map, "players": roster.size(), "max": MAX_PLAYERS, "port": GAME_PORT,
				"in_game": _in_game}
			_udp_broadcast.put_packet(JSON.stringify(info).to_utf8_buffer())
	if _udp_listen:
		var changed := false
		while _udp_listen.get_available_packet_count() > 0:
			var pkt := _udp_listen.get_packet()
			var ip := _udp_listen.get_packet_ip()
			var info = JSON.parse_string(pkt.get_string_from_utf8())
			if info is Dictionary and info.get("proto") == PROTOCOL:
				info["ip"] = ip
				info["seen"] = Time.get_ticks_msec()
				servers["%s:%d" % [ip, int(info.port)]] = info
				changed = true
		var now := Time.get_ticks_msec()
		for k in servers.keys():
			if now - int(servers[k].seen) > 4000:
				servers.erase(k)
				changed = true
		if changed:
			servers_changed.emit()


# ------------------------------------------------------------------ roster

@rpc("any_peer", "reliable")
func _register(n: String, proto: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if proto != PROTOCOL or _in_game or roster.size() >= MAX_PLAYERS:
		_kick.rpc_id(id, "Version mismatch" if proto != PROTOCOL else ("Game already in progress" if _in_game else "Server full"))
		return
	var e := _new_entry(n)
	e.team = make_join_team()
	roster[id] = e
	_push_roster()


## The team a newly joined pilot gets: none yet in a team match (NO_TEAM: he picks one, or the host places
## him), else 0.
func make_join_team() -> int:
	return NO_TEAM if settings.get("teams", false) else 0


## Host: puts pilot `peer` on team `team` (the lobby's team list).
func assign_team(peer: int, team: int) -> void:
	if is_host():
		_apply_info(peer, "team", team)


## Names of the connected pilots (not the host) who are not ready yet; the host starts only when this is empty.
func make_unready_names() -> PackedStringArray:
	var out: PackedStringArray = []
	for id in roster:
		if int(id) != 1 and not bool(roster[id].get("ready", false)):
			out.append(str(roster[id].get("name", "?")))
	return out


@rpc("authority", "reliable")
func _kick(reason: String) -> void:
	_reset()
	session_ended.emit(reason)


## Local player changes their own entry (vehicle, team, ready, loadout, kit).
func set_my_info(key: String, value: Variant) -> void:
	if is_host():
		_apply_info(1, key, value)
	else:
		_request_info.rpc_id(1, key, value)


@rpc("any_peer", "reliable")
func _request_info(key: String, value: Variant) -> void:
	if is_host():
		_apply_info(multiplayer.get_remote_sender_id(), key, value)


func _apply_info(id: int, key: String, value: Variant) -> void:
	if not roster.has(id) or not key in ROSTER_KEYS:
		return
	roster[id][key] = value
	_push_roster()


func set_settings(s: Dictionary) -> void:
	if is_host():
		settings = s
		_push_roster()


func _push_roster() -> void:
	roster_changed.emit()
	if is_online():
		_sync_roster.rpc(roster, settings)


@rpc("authority", "reliable")
func _sync_roster(r: Dictionary, s: Dictionary) -> void:
	roster = r
	settings = s
	roster_changed.emit()


func _on_peer_connected(_id: int) -> void:
	pass


func _on_peer_disconnected(id: int) -> void:
	if roster.has(id):
		roster.erase(id)
		if is_host():
			_push_roster()
		player_left.emit(id)


signal player_left(peer_id: int)


# ------------------------------------------------------------------ game start

## Host starts the match; every peer receives the same config.
func start_game(config: Dictionary) -> void:
	if not is_host():
		return
	_in_game = true
	config["roster"] = roster.duplicate(true)
	if is_online():
		_begin.rpc(config)
	else:
		game_starting.emit(config)


@rpc("authority", "reliable", "call_local")
func _begin(config: Dictionary) -> void:
	_in_game = true
	game_starting.emit(config)


func end_game() -> void:
	_in_game = false
	for id in roster:
		roster[id].ready = false

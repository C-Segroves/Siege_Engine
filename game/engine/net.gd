extends Node
## LAN multiplayer session: hosting/joining (ENet), LAN server discovery (UDP broadcast) and the
## lobby roster. The host is authoritative for the whole simulation; clients send inputs.

signal roster_changed
signal servers_changed
signal connected_to_server
signal connection_failed
signal session_ended(reason: String)
signal game_starting(config: Dictionary)
signal game_ended

## ENet peer timeouts (ms; limit = unanswered resend rounds): well above ENet's 5 s / 30 s so map loading survives.
const PEER_TIMEOUT_LIMIT := 64
const PEER_TIMEOUT_MIN_MS := 15000
const PEER_TIMEOUT_MAX_MS := 60000
const GAME_PORT := 47700
const DISCOVERY_PORT := 47701
## Most pilots a session can hold (ENet peer slots, the lobby list). A dedicated server sets `max_players` lower.
const MAX_PLAYERS := 64
## What a pilot-hosted LAN game holds (the host machine simulates everything).
const LAN_PLAYERS := 24
const PROTOCOL := "siege-engine/2"
## Transports: ENet (UDP, the default for desktop LAN and dedicated servers) or WebSocket (TCP: web clients and
## browsers only; behind nginx/Caddy TLS it is wss://).
const TRANSPORT_ENET := "enet"
const TRANSPORT_WS := "ws"
const WS_PREFIXES := ["ws://", "wss://"]
## The WebSocket path a reverse proxy forwards to the game port (deploy/nginx-server.conf.template).
const WS_PATH := "/ws"
## The roster team of a pilot of a team match who has no team yet (TeamAssignment.UNASSIGNED).
const NO_TEAM := -1
## Roster entry keys a pilot may set (set_my_info): the PlayerProfile keys carry his soldier's armour, body and
## skins.
## "slot" is the compact character slot snapshot (CharacterSlot.make_roster_snapshot), "goals" / "team_goals" the picked
## lobby goals, "wingmen" the campaign wingmen's specs (docs/design/lobby_loadout_economy.md section 7.1).
const ROSTER_KEYS := ["vehicle", "team", "ready", "loadout", "name", "kit", "infantry_armor", "infantry_body",
	"infantry_skin", "herc_skin", "slot", "goals", "team_goals", "wingmen"]
## Roster pushes closer together than this are merged into one (the first goes out at once, the rest as one later).
const ROSTER_PUSH_INTERVAL_S := 0.2

## The local player's name (PlayerProfile: saved in the settings, edited in Options and the lobby).
var player_name := "Pilot"
## peer_id -> {name, vehicle, team, ready, loadout, kit (extraction raids: ExtractionProfile.make_kit_dict)}
var roster := {}
## LAN servers seen: "ip:port" -> {name, mode, players, max, ip, port, seen}
var servers := {}
## Session settings chosen by the host (mode, arena/mission, teams, ...)
var settings := {"mode": "vs", "map": "", "teams": false, "ai": 0}
## Dedicated server (--server): hosts with no local pilot (the roster has no peer 1) and is the authority for all.
var dedicated := false
var transport := TRANSPORT_ENET
## Pilots this session admits (LAN_PLAYERS for a pilot-hosted game; a dedicated server sets its own, <= MAX_PLAYERS).
var max_players := LAN_PLAYERS
## Name shown in match lists (dedicated servers; LAN hosts show "<pilot>'s game").
var server_name := ""
## Host: pilots must send this to join ("" = open). Client: what join() sends.
var password := ""

var _udp_broadcast: PacketPeerUDP
var _udp_listen: PacketPeerUDP
var _bcast_t := 0.0
var _in_game := false
## Client: roster entries announced before the host registered us (the host drops those); sent on registration.
var _pending_info := {}
var _push_wait_s := 0.0
var _push_pending := false
var game_port := GAME_PORT


func _ready() -> void:
	player_name = PlayerProfile.load_name()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func():
		NetLog.write("connected", "to host (%s), sending %s" % [transport, PROTOCOL])
		_apply_peer_timeout(1)
		connected_to_server.emit()
		_register.rpc_id(1, player_name, PROTOCOL, password))
	multiplayer.connection_failed.connect(func():
		NetLog.write("connect_failed", "transport %s" % transport)
		_reset()
		connection_failed.emit())
	multiplayer.server_disconnected.connect(func():
		NetLog.write("host_gone", "server disconnected (closed or timed out)")
		_reset()
		session_ended.emit("Host closed the session"))


func is_online() -> bool:
	return multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer)


func is_host() -> bool:
	return multiplayer.is_server()


func my_id() -> int:
	return multiplayer.get_unique_id()


# ------------------------------------------------------------------ hosting / joining

func host(port := GAME_PORT, p_transport := TRANSPORT_ENET, p_dedicated := false, bind_address := "*") -> Error:
	if WebPlatform.is_active():
		_host_local()
		return OK
	var peer: MultiplayerPeer
	if p_transport == TRANSPORT_WS:
		var ws := WebSocketMultiplayerPeer.new()
		var ws_err := ws.create_server(port, bind_address)
		if ws_err != OK:
			return ws_err
		peer = ws
	else:
		var enet := ENetMultiplayerPeer.new()
		var err := enet.create_server(port, max_players if p_dedicated else max_players - 1)
		if err != OK:
			return err
		peer = enet
	multiplayer.multiplayer_peer = peer
	transport = p_transport
	NetLog.write("host", "port %d transport %s dedicated %s protocol %s" % [port, p_transport, p_dedicated, PROTOCOL])
	dedicated = p_dedicated
	game_port = port
	roster.clear()
	if not dedicated:
		roster[1] = _new_entry(player_name)
	if transport == TRANSPORT_ENET:
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


## An offline session for solo play (skirmish, single-player campaign, solo extraction): a local-only host, peer id 1,
## the roster holds this pilot alone.
func host_offline() -> void:
	_host_local()


## Joins `address`: an ENet host (IP or name) or, for "ws://..." / "wss://..." addresses, a WebSocket server.
## A browser can only use WebSocket.
func join(address: String, port := GAME_PORT) -> Error:
	var peer: MultiplayerPeer
	if is_ws_address(address):
		var ws := WebSocketMultiplayerPeer.new()
		var ws_err := ws.create_client(address)
		if ws_err != OK:
			return ws_err
		peer = ws
		transport = TRANSPORT_WS
	else:
		if WebPlatform.is_active():
			return ERR_UNAVAILABLE
		var enet := ENetMultiplayerPeer.new()
		var err := enet.create_client(address, port)
		if err != OK:
			return err
		peer = enet
		transport = TRANSPORT_ENET
	multiplayer.multiplayer_peer = peer
	NetLog.write("join", "%s port %d transport %s" % [address, port, transport])
	return OK


static func is_ws_address(address: String) -> bool:
	return WS_PREFIXES.any(func(p: String) -> bool: return address.begins_with(p))


## The WebSocket address of the game server behind a web origin ("https://host" -> "wss://host/ws").
static func make_ws_url(origin: String) -> String:
	var base := origin.strip_edges().rstrip("/")
	if is_ws_address(base):
		return base
	if base.begins_with("https://"):
		return "wss://" + base.substr(8) + WS_PATH
	if base.begins_with("http://"):
		return "ws://" + base.substr(7) + WS_PATH
	return "ws://" + base + WS_PATH


## What a match list or a LAN broadcast says about this session.
func make_match_info() -> Dictionary:
	var shown := server_name if server_name != "" else "%s's game" % player_name
	return {"proto": PROTOCOL, "name": shown, "mode": settings.get("mode", ""), "map": settings.get("map", ""),
		"players": roster.size(), "max": max_players, "port": game_port, "in_game": _in_game,
		"password": password != "", "transport": transport}


func leave() -> void:
	NetLog.write("leave", "local player left the session")
	_reset()
	session_ended.emit("Left session")


func _reset() -> void:
	_push_wait_s = 0.0
	_push_pending = false
	dedicated = false
	max_players = LAN_PLAYERS
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	roster.clear()
	_pending_info.clear()
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
	_tick_roster_push(delta)
	if _udp_broadcast and is_host():
		_bcast_t -= delta
		if _bcast_t <= 0.0:
			_bcast_t = 1.0
			var info := {"proto": PROTOCOL, "name": "%s's game" % player_name, "mode": settings.mode,
				"map": settings.map, "players": roster.size(), "max": max_players, "port": GAME_PORT,
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
func _register(n: String, proto: String, pw: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if proto != PROTOCOL or _in_game or roster.size() >= max_players or pw != password:
		var reason := "Version mismatch" if proto != PROTOCOL else ("Wrong password" if pw != password
			else ("Game already in progress" if _in_game else "Server full"))
		NetLog.write("refuse", "peer %d '%s': %s (client protocol %s, host %s; in_game %s, players %d/%d)" % [
			id, n, reason, proto, PROTOCOL, _in_game, roster.size(), max_players])
		_kick.rpc_id(id, reason)
		return
	NetLog.write("register", "peer %d '%s' joined (%d players)" % [id, n, roster.size() + 1])
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
	NetLog.write("kicked", reason)
	_reset()
	session_ended.emit(reason)


## Local player changes their own entry (vehicle, team, ready, loadout, kit).
func set_my_info(key: String, value: Variant) -> void:
	if is_host():
		_apply_info(1, key, value)
	elif roster.has(my_id()):
		_request_info.rpc_id(1, key, value)
	else:
		_pending_info[key] = value   # not registered at the host yet: sent once the roster has us (_flush_pending_info)


## Local player changes several of their own entry's keys at once: one message and one roster push, however many keys.
func set_my_infos(infos: Dictionary) -> void:
	if infos.is_empty():
		return
	if is_host():
		_apply_infos(1, infos)
	elif roster.has(my_id()):
		_request_infos.rpc_id(1, infos)
	else:
		_pending_info.merge(infos, true)


@rpc("any_peer", "reliable")
func _request_infos(infos: Dictionary) -> void:
	if is_host():
		_apply_infos(multiplayer.get_remote_sender_id(), infos)


func _apply_infos(id: int, infos: Dictionary) -> void:
	if not roster.has(id):
		NetLog.write("info_refused", "peer %d (not in roster)" % id)
		return
	for key in infos:
		if key in ROSTER_KEYS:
			roster[id][key] = infos[key]
		else:
			NetLog.write("info_refused", "peer %d key '%s' (not a pilot key)" % [id, key])
	_push_roster()


@rpc("any_peer", "reliable")
func _request_info(key: String, value: Variant) -> void:
	if is_host():
		_apply_info(multiplayer.get_remote_sender_id(), key, value)


func _apply_info(id: int, key: String, value: Variant) -> void:
	if not roster.has(id) or not key in ROSTER_KEYS:
		NetLog.write("info_refused", "peer %d key '%s' (not in roster / not a pilot key)" % [id, key])
		return
	if key == "ready" and is_host():
		NetLog.write("ready", "peer %d '%s' -> %s" % [id, roster[id].get("name", "?"), value])
	roster[id][key] = value
	_push_roster()


func set_settings(s: Dictionary) -> void:
	if is_host():
		settings = s
		_push_roster()


func _push_roster() -> void:
	roster_changed.emit()
	if not is_online():
		return
	if _in_game or _push_wait_s <= 0.0:
		_send_roster()
	else:
		_push_pending = true


func _send_roster() -> void:
	_push_wait_s = ROSTER_PUSH_INTERVAL_S
	_push_pending = false
	_sync_roster.rpc(roster, settings)


## Sends the roster changes that were held back by the push interval, once it is over.
func _tick_roster_push(delta: float) -> void:
	if _push_wait_s <= 0.0:
		return
	_push_wait_s -= delta
	if _push_wait_s <= 0.0 and _push_pending and is_online():
		_send_roster()


@rpc("authority", "reliable")
func _sync_roster(r: Dictionary, s: Dictionary) -> void:
	roster = r
	settings = s
	_flush_pending_info()
	roster_changed.emit()


func _flush_pending_info() -> void:
	if _pending_info.is_empty() or not roster.has(my_id()):
		return
	var pending := _pending_info
	_pending_info = {}
	_request_infos.rpc_id(1, pending)


func _on_peer_connected(id: int) -> void:
	if is_host():
		NetLog.write("peer_connected", "peer %d (%s)" % [id, transport])
		_apply_peer_timeout(id)


## ENet drops a peer that stays silent for its timeout; a client busy loading a big map (or a host starting a match)
## goes silent for seconds, which showed up as "sometimes kicked". Give every peer a generous limit.
func _apply_peer_timeout(id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var p := enet.get_peer(id)
	if p != null:
		p.set_timeout(PEER_TIMEOUT_LIMIT, PEER_TIMEOUT_MIN_MS, PEER_TIMEOUT_MAX_MS)


func _on_peer_disconnected(id: int) -> void:
	var rtt := ""
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	var gone := enet.get_peer(id) if enet != null else null
	if gone != null and gone.is_active():   # the wrapper outlives the closed connection, its statistics do not
		rtt = " last_rtt_ms %d" % int(gone.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
	NetLog.write("peer_gone", "peer %d '%s' (in_game %s)%s" % [id, roster.get(id, {}).get("name", "?"), _in_game, rtt])
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
	NetLog.write("start_game", "mode %s, %d players" % [settings.get("mode", "?"), roster.size()])
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
	NetLog.write("end_game", "match over, lobby ready flags cleared")
	_in_game = false
	for id in roster:
		roster[id].ready = false
	game_ended.emit()

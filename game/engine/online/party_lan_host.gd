class_name PartyLanHost
extends Node
## A party hosted by one pilot's PC for the LAN: the same party service as the master's (PartyRegistry, POST /party/...) on
## its own HTTP port, plus a broadcast every second so the other PCs list it (Net.parties) and join with one click or by
## its code. It holds a single party. The leader's own PartyClient talks to it like everybody else's; it keeps running while
## the leader is in a raid, because it is a node of the scene root (PartySession) and not of a screen.
## Only the party's names and ready flags pass through it; the game itself is played on the game server the party picks.

const PROTOCOL := "siege-engine-party/1"
const DEFAULT_PORT := 47703
const ANNOUNCE_SECONDS := 1.0
const MAX_BODY := 2048

var registry := PartyRegistry.new()
var port := DEFAULT_PORT
var _http := HttpServer.new()
var _udp: PacketPeerUDP
var _wait := 0.0
var _announce_name := ""


func _init() -> void:
	registry.max_parties = 1
	_http.handler = _answer
	_http.max_body = MAX_BODY
	add_child(_http)


## Starts listening on `p_port`; ERR_ALREADY_IN_USE-like errors come from the listen call.
func start(p_port := DEFAULT_PORT, bind_address := "*") -> Error:
	port = p_port
	var err := _http.start(p_port, bind_address)
	if err != OK:
		return err
	_udp = PacketPeerUDP.new()
	_udp.set_broadcast_enabled(true)
	_udp.set_dest_address("255.255.255.255", Net.DISCOVERY_PORT)
	return OK


func stop() -> void:
	_http.stop()
	_udp = null


func is_running() -> bool:
	return _http.is_listening()


func _process(delta: float) -> void:
	_wait -= delta
	if _wait <= 0.0 and _udp != null:
		_wait = ANNOUNCE_SECONDS
		_announce()


## One broadcast packet per party this host holds.
func _announce() -> void:
	registry.purge(Time.get_ticks_msec() / 1000.0)
	for s: Dictionary in registry.make_summaries():
		var info := {"proto": PROTOCOL, "code": s.code, "name": _make_title(s), "members": s.members, "max": s.max, "port": port}
		_udp.put_packet(JSON.stringify(info).to_utf8_buffer())


func _make_title(summary: Dictionary) -> String:
	return "%s's party" % str(summary.leader) if _announce_name == "" else _announce_name


func _answer(req: Dictionary) -> Dictionary:
	if req.method == "OPTIONS":
		return {"code": 204, "type": "text/plain", "body": ""}
	if req.method != "POST" or not PartyRegistry.is_party_path(str(req.path)):
		return _json(404, {"ok": false, "error": "not found"})
	var now := Time.get_ticks_msec() / 1000.0
	if not registry.allow(str(req.ip), now):
		return _json(429, {"ok": false, "error": "slow down"})
	var result := registry.answer(str(req.path), JsonHttp.parse(str(req.body)), str(req.ip), now)
	return _json(int(result.code), result.body)


static func _json(code: int, data: Dictionary) -> Dictionary:
	return {"code": code, "type": "application/json", "body": JSON.stringify(data)}

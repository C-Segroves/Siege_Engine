class_name BattlePilotSync
extends RefCounted
## Both halves of a Battle's pilot input path for a dedicated server (docs/DEDICATED_SERVER_SCALING.md section 2.2),
## used by BattleNetSync (which owns the RPCs).
## Server: offers the handshake to every pilot with a Herc or soldier of his own, keeps one ServerPilotLink per pilot
## once his input frames arrive (the body then steps one frame per tick) and echoes each link's state to its client.
## Client: takes the offer up for the body it flies (Prediction), sends the unacked input frames, and hands the
## server's echoes to the prediction.

var sync: BattleNetSync
var battle: Battle
## Server: peer -> ServerPilotLink.
var links := {}
## Client: the prediction of the local body (null: plain controls) and the body it runs on.
var prediction: Prediction
var predicted_body: Herc
var _echo_tick := 0
var _offer_t := 0.0


func _init(p_sync: BattleNetSync, p_battle: Battle) -> void:
	sync = p_sync
	battle = p_battle


# ------------------------------------------------------------------ server

## Once per physics step: the handshake offers (every OFFER_INTERVAL_S) and the states of the links.
func serve(delta: float) -> void:
	var now := Time.get_ticks_msec()
	_offer_t -= delta
	if _offer_t <= 0.0:
		_offer_t = BattleNetSync.OFFER_INTERVAL_S
		_offer_to_peers(now)
	for peer: int in links.keys():
		var link: ServerPilotLink = links[peer]
		if not is_instance_valid(link.body) or not sync.multiplayer.get_peers().has(peer):
			_drop_link(peer)
		elif link.fresh:
			_send_state(link, now)


## The frames of an input packet from `sender`: they go to the link of the body they name.
func receive_frames(sender: int, packet: PackedByteArray) -> void:
	var decoded := InputFrame.decode_packet(packet)
	if decoded.is_empty():
		return
	var h: Herc = battle.vehicles.get(int(decoded.body))
	if h == null or h.owner_peer != sender or h.has_meta("ai") or not is_eligible(h):
		return
	var now := Time.get_ticks_msec()
	var link: ServerPilotLink = links.get(sender)
	if link == null or link.body != h:
		link = _make_link(sender, h, now)
	link.receive_frames(decoded.frames, int(decoded.echo), now)


## Whether `h` is steered by input frames right now (so plain controls must not touch it); a link that went quiet
## is dropped here and the plain controls take over.
func is_fed_by_frames(h: Herc) -> bool:
	var link: ServerPilotLink = links.get(h.owner_peer)
	if link == null or link.body != h:
		return false
	if link.is_stale(Time.get_ticks_msec()):
		_drop_link(h.owner_peer)
		return false
	return true


## The round-trip time (ms) of `peer`: measured through the pilot states, else ENet's own figure, else 0.
func make_rtt_ms(peer: int) -> float:
	var link: ServerPilotLink = links.get(peer)
	if link != null and link.latency.samples > 0:
		return link.latency.rtt_ms
	var enet := sync.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	var packet_peer := enet.get_peer(peer) if enet != null else null
	return packet_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) if packet_peer != null else 0.0


## Pilots can have their movement predicted in a Herc or a soldier on foot (flyers and riders keep the plain path).
static func is_eligible(h: Herc) -> bool:
	return not (h is Flyer) and not (h is Infantry and (h as Infantry).stowed)


func _offer_to_peers(now: int) -> void:
	if not sync.profile.prediction_enabled:
		return
	for peer in sync.multiplayer.get_peers():
		var body := _find_body_of(peer)
		if body == null or not body.alive:
			continue
		var link: ServerPilotLink = links.get(peer)
		if link != null and link.body == body and not link.is_stale(now):
			continue
		sync._prediction_offer.rpc_id(peer, body.net_id, sync.clock.tick_hz)


func _find_body_of(peer: int) -> Herc:
	for id in battle.vehicles:
		var h: Herc = battle.vehicles[id]
		if h.owner_peer == peer and not h.has_meta("ai") and is_eligible(h):
			return h
	return null


func _make_link(peer: int, h: Herc, now: int) -> ServerPilotLink:
	_drop_link(peer)
	var link := ServerPilotLink.new(peer, h, sync._apply_controls, now)
	links[peer] = link
	h.pilot_link = link
	return link


func _drop_link(peer: int) -> void:
	var link: ServerPilotLink = links.get(peer)
	if link != null and is_instance_valid(link.body) and link.body.pilot_link == link:
		link.body.pilot_link = null
	links.erase(peer)


func _send_state(link: ServerPilotLink, now: int) -> void:
	link.fresh = false
	link.latency.note_sent(sync.clock.tick, now)
	sync._pilot_state.rpc_id(link.peer, link.state.make_packet(link.body.net_id, sync.clock.tick, sync.clock.tick_hz))


# ------------------------------------------------------------------ client

## The server offered prediction of body `body_id`: taken up when it is the body this pilot flies.
func accept_offer(body_id: int, tick_hz: int) -> void:
	var player := battle.player
	if player == null or player.net_id != body_id or not player.is_puppet or not player.alive or not is_eligible(player):
		return
	if prediction != null and predicted_body == player:
		return
	stop_prediction()
	var physics_hz := Engine.physics_ticks_per_second
	prediction = Prediction.new(BattleNetSync.make_controls, 1.0 / float(physics_hz),
		Prediction.make_steps_per_frame(physics_hz, tick_hz), Prediction.make_snap_distance(player))
	sync.profile.apply_to_prediction(prediction, player)
	predicted_body = player
	player.pilot_link = prediction


func stop_prediction() -> void:
	if is_instance_valid(predicted_body) and predicted_body.pilot_link == prediction:
		predicted_body.pilot_link = null
	prediction = null
	predicted_body = null


## Once per physics step on a client with a body: the input frames when predicting, else the plain controls.
func send_input() -> void:
	var player := battle.player
	_follow_player(player)
	if prediction != null and prediction.is_predicting(player):
		if prediction.has_new_frame:
			sync.send_input_frames(InputFrame.make_packet(player.net_id, _echo_tick, prediction.take_outgoing()))
		return
	sync.send_plain_input(BattleNetSync.make_controls(player))


func receive_state(packet: PackedByteArray) -> void:
	var decoded := PilotState.decode_packet(packet)
	if decoded.is_empty() or prediction == null or not is_instance_valid(predicted_body) \
			or int(decoded.body) != predicted_body.net_id:
		return
	_echo_tick = maxi(_echo_tick, int(decoded.tick))
	prediction.receive_state(decoded.state)


func _follow_player(player: Herc) -> void:
	if prediction == null:
		return
	if player != predicted_body or not is_instance_valid(predicted_body):
		stop_prediction()
	elif not prediction.is_predicting(player):
		prediction.reset()

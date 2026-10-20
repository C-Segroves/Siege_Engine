class_name BattleNetSync
extends Node
## LAN state sync for a Battle (child node "NetSync"): the host broadcasts vehicle snapshots every
## `snapshot_interval` ticks of its ServerClock (about SNAPSHOT_HZ), clients send their Herc's controls every
## physics tick. Snapshots are stamped with simulated time (the tick number), never the wall clock.
## A snapshot carries each vehicle's pose, weapon trigger bits and, around a damage change, its damage
## block (HercSnapshots.make_damage_block, ~30 bytes): repeated for DAMAGE_RESEND_MS after each change
## (the channel is unreliable) and every DAMAGE_KEEPALIVE_MS otherwise (late joiners), else empty.
## A dedicated server (or `packed_in_lan`) sends the packed path instead: per-client SnapshotCodec deltas of only the
## entities the InterestGrid marks relevant (BattleSnapshotStream, unreliable `_snapshot_packed`), acknowledged by the
## clients (`_client_ack`) and applied by BattleSnapshotReceiver. LAN keeps the Variant snapshots above by default.
## A dedicated server (or `prediction_in_lan`) also runs the pilots' movement the way the Tribes originals did: the
## client sends sequenced input frames (InputFrame, `_client_input_frames`), the server steps its copy of the body one
## frame per tick (ServerPilotLink) and echoes the state it reached with the frame's sequence number (`_pilot_state`);
## the client predicts its own body and reconciles against that echo (Prediction). The server offers it
## (`_prediction_offer`) and the client takes it up only for a Herc or soldier it flies itself; everything else, and a
## LAN host by default, keeps the plain controls of `_client_input`. With a HitHistory (dedicated, or
## `lag_comp_in_lan`) the hitscan and fast-projectile shots of human pilots are tested against the units as the shooter
## saw them (make_rewind, LagCompensation).

## Snapshot rate of a LAN host (a dedicated server follows its game's NetProfile).
const SNAPSHOT_HZ := 20.0
const MIN_SNAPSHOT_DT := 0.01
const MAX_SNAPSHOT_DT := 0.5
const DAMAGE_RESEND_MS := 1000
const DAMAGE_KEEPALIVE_MS := 3000

## Tests and experiments: a LAN host uses the packed path too (`interest_in_lan`: with the interest grid on).
static var packed_in_lan := false
static var interest_in_lan := false
## Tests and experiments: a LAN host runs the pilots' prediction handshake / rewinds their shots too.
static var prediction_in_lan := false
static var lag_comp_in_lan := false
## Tests and experiments: a client delays everything it sends to the server and everything it receives from it by this
## many milliseconds (half the simulated round trip each way).
static var simulated_one_way_ms := 0

const OFFER_INTERVAL_S := 1.0

signal snapshot_sent(peer: int, tick: int)

var battle: Battle
## The fixed simulation tick (child "ServerClock"); snapshots go out on its ticks.
var clock: ServerClock
## The netcode tuning of this battle's game (tick, snapshot, interest, prediction, lag compensation).
var profile: NetProfile
var snapshot_interval := 1
var _last_snap_ms := 0
var _outgoing_delay: DelayLine
var _incoming_delay: DelayLine
## net id -> {block, changed_ms, sent_ms}: the damage block last seen per vehicle (host).
var _damage := {}
## The packed path (null: the Variant snapshots). The stream is the server half, the receiver the client half.
var stream: BattleSnapshotStream
var receiver: BattleSnapshotReceiver
## The pilots' input frames, prediction and reconciliation (both halves).
var pilots: BattlePilotSync
## Server: the last second of hit capsules (null: shots are not compensated).
var hit_history: HitHistory


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "NetSync"


func _ready() -> void:
	profile = NetProfile.load_for(CommandProviders.make_game_pack(battle))
	clock = ServerClock.make_for_session(profile.tick_hz)
	add_child(clock)
	snapshot_interval = ServerClock.make_interval(clock.tick_hz, profile.snapshot_hz if Net.dedicated else SNAPSHOT_HZ)
	clock.ticked.connect(_on_tick)
	pilots = BattlePilotSync.new(self, battle)
	_outgoing_delay = DelayLine.new(simulated_one_way_ms)
	_incoming_delay = DelayLine.new(simulated_one_way_ms)
	if Net.dedicated or packed_in_lan:
		use_packed_snapshots(Net.dedicated or interest_in_lan)
	if Net.dedicated or lag_comp_in_lan:
		hit_history = HitHistory.new(clock.tick_hz)


## Switches this (host) battle to the packed, interest-scoped snapshots.
func use_packed_snapshots(interest_enabled: bool) -> void:
	stream = BattleSnapshotStream.new(battle, interest_enabled)
	stream.send_packet = func(peer: int, packet: PackedByteArray) -> void: _snapshot_packed.rpc_id(peer, packet)
	stream.snapshot_sent.connect(snapshot_sent.emit)
	profile.apply_to_grid(stream.grid)
	stream.governor.enabled = Net.dedicated
	stream.frame_cost_ms = make_tick_cost_ms


## The server's recent work per tick in ms (its ServerMetrics node; 0 without one, so the governor stays idle).
func make_tick_cost_ms() -> float:
	var metrics := battle.get_node_or_null("ServerMetrics") as ServerMetrics
	return metrics.recent_tick_ms if metrics != null else 0.0


## The client `peer` received snapshot `tick` completely (also what `_client_ack` delivers).
func acknowledge(peer: int, tick: int) -> void:
	if stream:
		stream.acknowledge(peer, tick)


func _physics_process(delta: float) -> void:
	battle.entities.update_from_nodes(Engine.get_physics_frames())
	_outgoing_delay.release(Time.get_ticks_msec())
	_incoming_delay.release(Time.get_ticks_msec())
	if not Net.is_online():
		return
	if multiplayer.is_server():
		if serves_prediction():
			pilots.serve(delta)
		return
	if receiver and receiver.has_acks():
		_client_ack.rpc_id(1, receiver.take_acks())
	if battle.player and not battle.is_over():
		# after the match the host frees its Battle: input sent then would hit a missing node
		pilots.send_input()


func _on_tick(tick: int) -> void:
	if not Net.is_online() or not multiplayer.is_server():
		return
	if hit_history:
		hit_history.record(battle.entities, tick)
	if tick % snapshot_interval != 0:
		return
	if stream:
		stream.send_snapshot(tick, clock.tick_hz, clock.make_time_ms(tick), Array(multiplayer.get_peers()))
	else:
		_send_snapshot(clock.make_time_ms(tick))


func _send_snapshot(now: int) -> void:
	var states := []
	for id in battle.vehicles:
		var s: Array = battle.vehicles[id].snapshot()
		s.append(make_damage_update(battle.vehicles[id], now))
		var infantry := battle.vehicles[id] as Infantry
		s.append(infantry.make_snapshot_extra() if infantry else null)   # Infantry.SNAP_INFANTRY
		s.append(battle.vehicles[id].missile_steering.stick)   # HercSnapshots.SNAP_MISSILE_STEER
		s.append(battle.vehicles[id].cloak.make_flag())        # HercSnapshots.SNAP_CLOAK
		states.append(s)
	_snapshot.rpc(now, states)


## The damage block to send for `h` at time `now_ms`: its current block while it changed recently or
## when the keepalive is due, else an empty one.
func make_damage_update(h: Herc, now_ms: int) -> PackedByteArray:
	var block := HercSnapshots.make_damage_block(h)
	var seen: Dictionary = _damage.get(h.net_id, {})
	if seen.is_empty() or seen.block != block:
		_damage[h.net_id] = {"block": block, "changed_ms": now_ms, "sent_ms": now_ms}
		return block
	if now_ms - int(seen.changed_ms) < DAMAGE_RESEND_MS or now_ms - int(seen.sent_ms) >= DAMAGE_KEEPALIVE_MS:
		seen.sent_ms = now_ms
		return block
	return PackedByteArray()


## Client: sends the input frames packet to the server (through the simulated latency, if any).
func send_input_frames(packet: PackedByteArray) -> void:
	_send_or_hold(_outgoing_delay, func() -> void: _client_input_frames.rpc_id(1, packet))


## Client: sends the plain controls to the server (through the simulated latency, if any).
func send_plain_input(controls: Dictionary) -> void:
	_send_or_hold(_outgoing_delay, func() -> void: _client_input.rpc_id(1, controls))


func _send_or_hold(line: DelayLine, call: Callable) -> void:
	if line.is_active():
		line.hold(Time.get_ticks_msec(), call)
	else:
		call.call()


## The Herc's control state as sent to the host: {throttle, turn, torso, pitch, triggers, target},
## plus "flight": [yaw, pitch, lift] stick input for a Flyer, "infantry": [jet, jump, weapon slot] for a soldier,
## "cloak": whether the pilot wants a vehicle's cloak on, and "missile_steer": the steered EO missile's stick
## (MissileSteering) while there is one.
static func make_controls(h: Herc) -> Dictionary:
	var c := {"throttle": h.throttle, "turn": h.turn, "torso": h.torso_target, "pitch": h.pitch_target,
		"triggers": HercSnapshots.make_trigger_bits(h), "target": h.target.net_id if h.target is Herc else 0}
	if h.missile_steering.is_steering():
		c["missile_steer"] = h.missile_steering.stick
	if h is Flyer:
		var fl := h as Flyer
		c["flight"] = [fl.yaw_input, fl.pitch_input, fl.lift_input]
	if h is Infantry:
		c["infantry"] = (h as Infantry).make_extra_controls()
	elif h.cloak.is_equipped():
		c["cloak"] = h.cloak_input
	return c


## Whether an incoming RPC can be applied: one that arrives while the Battle is leaving the tree
## (match end) has no multiplayer API left and is dropped.
func is_receiving() -> bool:
	return is_inside_tree() and battle != null and is_instance_valid(battle)


@rpc("any_peer", "unreliable_ordered")
func _client_input(controls: Dictionary) -> void:
	if not is_receiving():
		return
	var sender := multiplayer.get_remote_sender_id()
	for id in battle.vehicles:
		var h: Herc = battle.vehicles[id]
		if h.owner_peer == sender and not h.has_meta("ai"):
			if pilots.is_fed_by_frames(h):
				return   # its input arrives as frames; a stray plain packet must not steer it
			_apply_controls(h, controls)
			return
	battle.occupancy.apply_crew_controls(sender, controls)   # a gunner seat (TurretCrew)


func _apply_controls(h: Herc, c: Dictionary) -> void:
	h.throttle = clampf(float(c.get("throttle", 0.0)), -1, 1)
	h.turn = clampf(float(c.get("turn", 0.0)), -1, 1)
	h.torso_target = float(c.get("torso", 0.0))
	h.pitch_target = float(c.get("pitch", 0.0))
	HercSnapshots.apply_trigger_bits(h, int(c.get("triggers", 0)))
	h.target = battle.vehicles.get(int(c.get("target", 0)))
	var steer = c.get("missile_steer", Vector2.ZERO)
	h.missile_steering.stick = (steer as Vector2).clamp(-Vector2.ONE, Vector2.ONE) if steer is Vector2 else Vector2.ZERO
	if h is Infantry:
		(h as Infantry).apply_extra_controls(c.get("infantry", []))
	else:
		h.cloak_input = bool(c.get("cloak", false))
	var stick: Array = c.get("flight", [])
	if h is Flyer and stick.size() == 3:
		var fl := h as Flyer
		fl.yaw_input = clampf(float(stick[0]), -1, 1)
		fl.pitch_input = clampf(float(stick[1]), -1, 1)
		fl.lift_input = clampf(float(stick[2]), -1, 1)


@rpc("authority", "unreliable_ordered")
func _snapshot(sim_ms: int, states: Array) -> void:
	if not is_receiving():
		return
	var dt := 1.0 / SNAPSHOT_HZ
	if _last_snap_ms > 0:
		dt = clampf((sim_ms - _last_snap_ms) / 1000.0, MIN_SNAPSHOT_DT, MAX_SNAPSHOT_DT)
	_last_snap_ms = sim_ms
	for s in states:
		var h: Herc = battle.vehicles.get(int(s[0]))
		if h:
			h.apply_snapshot(s, dt)


## The packed snapshot (SnapshotCodec packet) of the server.
@rpc("authority", "unreliable_ordered")
func _snapshot_packed(packet: PackedByteArray) -> void:
	if not is_receiving():
		return
	_send_or_hold(_incoming_delay, func() -> void: _apply_packed_snapshot(packet))


func _apply_packed_snapshot(packet: PackedByteArray) -> void:
	if not is_receiving():
		return
	if receiver == null:
		receiver = BattleSnapshotReceiver.new(battle)
	receiver.receive(packet)


## A client's acknowledgements of snapshot ticks it received completely (the baseline of its next deltas).
@rpc("any_peer", "unreliable")
func _client_ack(ticks: PackedInt32Array) -> void:
	if not is_receiving() or stream == null:
		return
	var sender := multiplayer.get_remote_sender_id()
	for tick in ticks:
		stream.acknowledge(sender, tick)


# ------------------------------------------------------------------ pilots: input frames, prediction, lag compensation

## Whether this (server) battle runs its pilots from input frames.
func serves_prediction() -> bool:
	return Net.dedicated or prediction_in_lan


## Input frames of a client for the body it pilots (see InputFrame).
@rpc("any_peer", "unreliable_ordered")
func _client_input_frames(packet: PackedByteArray) -> void:
	if is_receiving() and multiplayer.is_server() and serves_prediction():
		pilots.receive_frames(multiplayer.get_remote_sender_id(), packet)


## Server to client: "predict your body `body_id`, input frames are one per `tick_hz` tick".
@rpc("authority", "reliable")
func _prediction_offer(body_id: int, tick_hz: int) -> void:
	if is_receiving():
		pilots.accept_offer(body_id, tick_hz)


## Server to client: the state of the client's body after the last input frame the server processed.
@rpc("authority", "unreliable_ordered")
func _pilot_state(packet: PackedByteArray) -> void:
	if is_receiving():
		_send_or_hold(_incoming_delay, func() -> void: pilots.receive_state(packet))


## How `shooter`'s shot is rewound (LagCompensation): {} when it shoots at the units as they are now (bots, the host's
## own pilot, a battle without hit history, lag compensation off in the profile). "policy" is the NetProfile that decides
## per weapon (LagCompensation.make_beam_rewind_for / is_compensated).
func make_rewind(shooter: Node3D) -> Dictionary:
	var h := shooter as Herc
	if hit_history == null or h == null or h.has_meta("ai") or h.has_meta("bot_id") or h.owner_peer == 1:
		return {}
	if not profile.lag_comp_enabled:
		return {}
	var rewind_ms := LagCompensation.make_rewind_ms(pilots.make_rtt_ms(h.owner_peer), make_interp_delay_ms(), profile.max_rewind_ms)
	return {"history": hit_history, "view_tick": hit_history.make_view_tick(clock.tick, rewind_ms), "ignore_id": h.net_id,
		"policy": profile, "unit_of": func(id: int) -> Node3D: return battle.vehicles.get(id)}


## How far behind the server a client draws the other units: one snapshot interval.
func make_interp_delay_ms() -> float:
	return float(snapshot_interval) * ServerClock.MILLISECONDS / float(clock.tick_hz)

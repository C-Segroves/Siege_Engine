class_name BattleNetSync
extends Node
## LAN state sync for a Battle (child node "NetSync"): the host broadcasts vehicle snapshots at
## SNAPSHOT_HZ, clients send their Herc's controls every physics tick.
## A snapshot carries each vehicle's pose, weapon trigger bits and, around a damage change, its damage
## block (HercSnapshots.make_damage_block, ~30 bytes): repeated for DAMAGE_RESEND_MS after each change
## (the channel is unreliable) and every DAMAGE_KEEPALIVE_MS otherwise (late joiners), else empty.

const SNAPSHOT_HZ := 20.0
const MIN_SNAPSHOT_DT := 0.01
const MAX_SNAPSHOT_DT := 0.5
const DAMAGE_RESEND_MS := 1000
const DAMAGE_KEEPALIVE_MS := 3000

var battle: Battle
var _snap_acc := 0.0
var _last_snap_ms := 0
## net id -> {block, changed_ms, sent_ms}: the damage block last seen per vehicle (host).
var _damage := {}


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "NetSync"


func _physics_process(delta: float) -> void:
	if not Net.is_online():
		return
	if multiplayer.is_server():
		_send_snapshot_when_due(delta)
	elif battle.player and not battle.is_over():
		# after the match the host frees its Battle: input sent then would hit a missing node
		_client_input.rpc_id(1, make_controls(battle.player))


func _send_snapshot_when_due(delta: float) -> void:
	_snap_acc += delta
	if _snap_acc < 1.0 / SNAPSHOT_HZ:
		return
	_snap_acc = 0.0
	var now := Time.get_ticks_msec()
	var states := []
	for id in battle.vehicles:
		var s: Array = battle.vehicles[id].snapshot()
		s.append(make_damage_update(battle.vehicles[id], now))
		var infantry := battle.vehicles[id] as Infantry
		s.append(infantry.make_snapshot_extra() if infantry else null)   # Infantry.SNAP_INFANTRY
		s.append(battle.vehicles[id].missile_steering.stick)   # HercSnapshots.SNAP_MISSILE_STEER
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


## The Herc's control state as sent to the host: {throttle, turn, torso, pitch, triggers, target},
## plus "flight": [yaw, pitch, lift] stick input for a Flyer, "infantry": [jet, jump, weapon slot] for a soldier
## and "missile_steer": the steered EO missile's stick (MissileSteering) while there is one.
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
	var stick: Array = c.get("flight", [])
	if h is Flyer and stick.size() == 3:
		var fl := h as Flyer
		fl.yaw_input = clampf(float(stick[0]), -1, 1)
		fl.pitch_input = clampf(float(stick[1]), -1, 1)
		fl.lift_input = clampf(float(stick[2]), -1, 1)


@rpc("authority", "unreliable_ordered")
func _snapshot(t_ms: int, states: Array) -> void:
	if not is_receiving():
		return
	var dt := 1.0 / SNAPSHOT_HZ
	if _last_snap_ms > 0:
		dt = clampf((t_ms - _last_snap_ms) / 1000.0, MIN_SNAPSHOT_DT, MAX_SNAPSHOT_DT)
	_last_snap_ms = t_ms
	for s in states:
		var h: Herc = battle.vehicles.get(int(s[0]))
		if h:
			h.apply_snapshot(s, dt)

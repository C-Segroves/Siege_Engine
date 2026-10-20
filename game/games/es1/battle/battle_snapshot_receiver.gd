class_name BattleSnapshotReceiver
extends RefCounted
## The client half of the packed snapshot path: decodes SnapshotCodec packets, merges each record's changed groups
## into that unit's last known state and hands the result to Herc.apply_snapshot, so puppets interpolate exactly as
## with the Variant snapshots. A unit that is updated rarely (far tiers) interpolates over the time since its own
## last update. A bot the server sends at the FAR tier loses its node and is drawn as a FarBots proxy; it gets its
## node back (BattleFarUnits.restore) when its tier rises. A bot the server forgot loses its node; any other unit the
## server forgot is hidden, and a record shows it again. A snapshot tick is acknowledged once all its parts arrived
## and every record in it could be applied.

const DEFAULT_DT := 0.05
const MIN_DT := 0.01
const MAX_DT := 0.5
const MS_PER_SECOND := 1000.0
const KEPT_TICKS := 8
const FORGOTTEN_META := "net_forgotten"
const FAR_TIER := 2   # InterestGrid.Tier.FAR on the wire

var battle: Battle
var _states := {}                           # id -> state Array (SnapshotCodec.IDX_*)
var _cells := {}                            # id -> Vector2i
var _last_ms := {}                          # id -> simulated ms of the last applied record
var _tiers := {}                            # id -> the tier the server last announced
var _placeholders := {}                     # id -> true: its state was made up (a bot forgotten while it had no node)
var _damage := {}                           # id -> the newest damage block (a restored node gets it again)
var _tick_parts := {}                       # tick -> {"seen": part bit mask, "ok": bool}
var _pending_acks: Array[int] = []
var _previous_acks: Array[int] = []


func _init(p_battle: Battle) -> void:
	battle = p_battle


## Applies one packet from the server.
func receive(bytes: PackedByteArray) -> void:
	var packet := SnapshotCodec.decode_packet(bytes, _cells)
	if packet.is_empty():
		return
	var ms := roundi(float(packet.tick) * MS_PER_SECOND / float(maxi(packet.tick_hz, 1)))
	var applied_all := true
	for id in packet.forgets:
		_forget(id)
	for record: Dictionary in packet.records:
		applied_all = _apply_record(record, ms) and applied_all
	_note_part(packet, applied_all)


## Ticks to acknowledge now: the new ones plus the previous batch again (the ack channel is unreliable).
func take_acks() -> PackedInt32Array:
	var out := PackedInt32Array(_previous_acks)
	out.append_array(_pending_acks)
	_previous_acks = _pending_acks
	_pending_acks = []
	return out


func has_acks() -> bool:
	return not _pending_acks.is_empty() or not _previous_acks.is_empty()


func _apply_record(record: Dictionary, ms: int) -> bool:
	var id: int = record.id
	if record.tier != SnapshotCodec.NO_TIER:
		_tiers[id] = record.tier
	var units := battle.far_units
	var h: Herc = battle.vehicles.get(id)
	var parked := units != null and units.is_parked(id)
	if not is_instance_valid(h) and not parked:
		return false   # its spawn message has not arrived yet: not acknowledged, so the server sends it again
	_cells[id] = record.cell
	var dt := _make_dt(id, ms)
	if parked:
		return _apply_to_parked(record, dt)
	var state := _make_state_for(id, h)
	_merge(state, record)
	if units != null and _tiers.get(id) == FAR_TIER and units.can_park(h):
		_park(h, state, dt)
		return true
	_show(h)
	h.apply_snapshot(state, dt)
	return true


func _make_dt(id: int, ms: int) -> float:
	var dt := DEFAULT_DT
	if _last_ms.has(id):
		dt = clampf(float(ms - int(_last_ms[id])) / MS_PER_SECOND, MIN_DT, MAX_DT)
	_last_ms[id] = ms
	return dt


## A record for a bot without a node: keeps its proxy moving, or builds the node when it is no longer far.
func _apply_to_parked(record: Dictionary, dt: float) -> bool:
	var id: int = record.id
	var state: Array = _states.get(id, [])
	if state.is_empty():
		state = battle.far_units.make_placeholder_state(id)
		_states[id] = state
		_placeholders[id] = true
	_merge(state, record)
	if _tiers.get(id) == FAR_TIER or not state[SnapshotCodec.IDX_ALIVE]:
		_show_proxy(id, state, dt)
		return true
	_restore(id, state, record, dt)
	return true


## Builds the node again; a state made up while there was no node (after a forget) is replaced by the node's own.
func _restore(id: int, state: Array, record: Dictionary, dt: float) -> void:
	var h := battle.far_units.restore(id)
	if _placeholders.erase(id):
		var fresh := BattleSnapshotStream.make_state(h)
		for index in [SnapshotCodec.IDX_POS, SnapshotCodec.IDX_YAW, SnapshotCodec.IDX_TORSO, SnapshotCodec.IDX_PITCH,
				SnapshotCodec.IDX_SPEED, SnapshotCodec.IDX_ALIVE, SnapshotCodec.IDX_INTEGRITY]:
			fresh[index] = state[index]
		_merge(fresh, record)
		_states[id] = fresh
		state = fresh
	state[SnapshotCodec.IDX_DAMAGE] = _damage.get(id, PackedByteArray())
	h.apply_snapshot(state, dt)
	state[SnapshotCodec.IDX_DAMAGE] = PackedByteArray()


func _park(h: Herc, state: Array, dt: float) -> void:
	var id := h.net_id
	battle.far_units.park(h)
	_show_proxy(id, state, dt)


func _show_proxy(id: int, state: Array, dt: float) -> void:
	var units := battle.far_units
	units.show_proxy(id, state[SnapshotCodec.IDX_POS], float(state[SnapshotCodec.IDX_YAW]), dt)
	units.apply_alive(id, bool(state[SnapshotCodec.IDX_ALIVE]))


func _make_state_for(id: int, h: Herc) -> Array:
	var state: Array = _states.get(id, [])
	if state.is_empty():
		state = BattleSnapshotStream.make_state(h)
		_states[id] = state
	state[SnapshotCodec.IDX_DAMAGE] = PackedByteArray()   # a damage block is applied once, when it arrives
	return state


func _merge(state: Array, record: Dictionary) -> void:
	for index: int in record.fields:
		state[index] = record.fields[index]
	var block: PackedByteArray = record.fields.get(SnapshotCodec.IDX_DAMAGE, PackedByteArray())
	if not block.is_empty():
		_damage[record.id] = block
	if state[SnapshotCodec.IDX_EXTRA] is Array:
		_merge_extra(state[SnapshotCodec.IDX_EXTRA], record)


static func _merge_extra(extra: Array, record: Dictionary) -> void:
	var patch: Dictionary = record.extra
	if not patch.is_empty():
		extra[0] = patch.jetting
		extra[1] = patch.slot
		extra[2] = patch.stowed
		extra[3] = patch.rounds
	if record.kit is Array:
		extra[4] = record.kit


func _forget(id: int) -> void:
	_states.erase(id)
	_cells.erase(id)
	_last_ms.erase(id)
	_tiers.erase(id)
	_damage.erase(id)
	_placeholders.erase(id)
	var units := battle.far_units
	if units != null and units.is_parked(id):
		units.hide_proxy(id)
		return
	var h: Herc = battle.vehicles.get(id)
	if units != null and is_instance_valid(h) and units.can_park(h):
		units.park(h)
		return
	if is_instance_valid(h) and not h.is_local_player():
		h.set_meta(FORGOTTEN_META, true)
		h.visible = false


static func _show(h: Herc) -> void:
	if h.has_meta(FORGOTTEN_META):
		h.remove_meta(FORGOTTEN_META)
		h.visible = true


func _note_part(packet: Dictionary, applied_all: bool) -> void:
	var tick: int = packet.tick
	var entry: Dictionary = _tick_parts.get(tick, {"seen": 0, "ok": true})
	entry.seen |= 1 << int(packet.part)
	entry.ok = entry.ok and applied_all
	_tick_parts[tick] = entry
	if entry.ok and entry.seen == (1 << int(packet.parts)) - 1:
		_pending_acks.append(tick)
		_tick_parts.erase(tick)
	_drop_old_ticks(tick)


func _drop_old_ticks(newest: int) -> void:
	for tick: int in _tick_parts.keys():
		if tick < newest - KEPT_TICKS * 8:
			_tick_parts.erase(tick)

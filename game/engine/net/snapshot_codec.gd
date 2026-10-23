class_name SnapshotCodec
extends RefCounted
## Bit-packed, quantized snapshot wire format (docs/DEDICATED_SERVER_SCALING.md section 3.2).
##
## An entity's state (the Array of Herc.snapshot() + damage block + soldier extra + missile stick) is cut into
## GROUPS, each a small fixed byte layout. The server encodes every group once per snapshot (encode_groups);
## per client it sends only the groups whose bytes differ from what that client last acknowledged, so an unchanged
## group costs nothing. A packet is `header, forgotten ids, records`; a record is `id u16, mask u16, group bytes`.
## Positions are centimetres relative to a 128 m cell (the cell index rides along only when it changed), angles are
## 16 bit, flags are bits and health is a byte. make_packets splits a client's records so every packet stays under
## the MTU; decode_packet reads one back into field patches for the receiving Battle.
##
## The state indices below mirror Herc.snapshot() / HercSnapshots.SNAP_* (engine code must not depend on a game).

const GROUP_POSE := 1
const GROUP_STATUS := 2
const GROUP_RESOURCES := 4
const GROUP_TRIGGERS := 8
const GROUP_DAMAGE := 16
const GROUP_EXTRA := 32
const GROUP_KIT := 64
const GROUP_STEER := 128
const ALL_GROUPS := 255
## The tier the client sees the unit at (u8, see InterestGrid.Tier): a per-client group, sent when it changes, so a
## unit that drops to the far tier is drawn as a cheap proxy (FarBots) and promoted back when it comes close.
const GROUP_TIER := 512
## Record flag: the pose group came without its cell (unchanged since the acknowledged baseline).
const FLAG_SAME_CELL := 256
const GROUP_BITS: Array[int] = [GROUP_POSE, GROUP_STATUS, GROUP_RESOURCES, GROUP_TRIGGERS, GROUP_DAMAGE,
	GROUP_EXTRA, GROUP_KIT, GROUP_STEER, GROUP_TIER]
const NO_TIER := -1

const IDX_ID := 0
const IDX_POS := 1
const IDX_YAW := 2
const IDX_TORSO := 3
const IDX_PITCH := 4
const IDX_SPEED := 5
const IDX_ALIVE := 6
const IDX_SHIELD_FRONT := 7
const IDX_SHIELD_REAR := 8
const IDX_INTEGRITY := 9
const IDX_CAPACITOR := 10
const IDX_KILLS := 11
const IDX_DEATHS := 12
const IDX_TRIGGERS := 13
const IDX_DAMAGE := 14
const IDX_EXTRA := 15
const IDX_STEER := 16
## Whether the unit is cloaked in effect (CloakState.make_flag): rides in bit 1 of the status flags byte.
const IDX_CLOAKED := 17
const STATE_SIZE := 18

const CELL_M := 128.0
const CM_PER_M := 100.0
const HEIGHT_STEP_M := 0.05
const HEIGHT_OFFSET_M := 500.0
const SPEED_STEP := 100.0
const ANGLE_STEPS := 65536.0
const BYTE_MAX := 255.0
const STICK_STEPS := 127.0
const U16_MAX := 65535
const CELL_BYTES := 4
const MAX_ID := 65535
const FLAG_ALIVE_BIT := 1
const FLAG_CLOAKED_BIT := 2

## Bytes a packet may carry (the RPC wrapper adds a few tens); Godot's ENet MTU is 1392.
const MTU_BYTES := 1392
const MAX_PAYLOAD_BYTES := 1280
const HEADER_BYTES := 9
const ID_BYTES := 2
const RECORD_HEADER_BYTES := 4
const MAX_COUNT := 255

const POSE_BYTES := 18
const RESOURCES_BYTES := 10


# ------------------------------------------------------------------ encoding (server)

## The state's groups as {group bit: PackedByteArray}. A vehicle has no EXTRA / KIT group.
static func encode_groups(s: Array) -> Dictionary:
	var groups := {
		GROUP_POSE: _encode_pose(s),
		GROUP_STATUS: _encode_status(s),
		GROUP_RESOURCES: _encode_resources(s),
		GROUP_TRIGGERS: _encode_triggers(s),
		GROUP_DAMAGE: _encode_damage(s),
		GROUP_STEER: _encode_steer(s),
	}
	if s[IDX_EXTRA] is Array:
		var extra: Array = s[IDX_EXTRA]
		groups[GROUP_EXTRA] = _encode_extra(extra)
		groups[GROUP_KIT] = _encode_kit(extra)
	return groups


## The one-byte tier group.
static func encode_tier(tier: int) -> PackedByteArray:
	return PackedByteArray([clampi(tier, 0, 255)])


static func make_cell_of(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL_M), floori(position.z / CELL_M))


static func _encode_pose(s: Array) -> PackedByteArray:
	var at: Vector3 = s[IDX_POS]
	var cell := make_cell_of(at)
	var out := PackedByteArray()
	out.resize(POSE_BYTES)
	out.encode_s16(0, clampi(cell.x, -32768, 32767))
	out.encode_s16(2, clampi(cell.y, -32768, 32767))
	out.encode_u16(4, clampi(roundi((at.x - float(cell.x) * CELL_M) * CM_PER_M), 0, U16_MAX))
	out.encode_u16(6, clampi(roundi((at.z - float(cell.y) * CELL_M) * CM_PER_M), 0, U16_MAX))
	out.encode_u16(8, clampi(roundi((at.y + HEIGHT_OFFSET_M) / HEIGHT_STEP_M), 0, U16_MAX))
	out.encode_u16(10, make_angle_code(float(s[IDX_YAW])))
	out.encode_u16(12, make_angle_code(float(s[IDX_TORSO])))
	out.encode_u16(14, make_angle_code(float(s[IDX_PITCH])))
	out.encode_s16(16, clampi(roundi(float(s[IDX_SPEED]) * SPEED_STEP), -32768, 32767))
	return out


static func _encode_status(s: Array) -> PackedByteArray:
	var flags := FLAG_ALIVE_BIT if bool(s[IDX_ALIVE]) else 0
	if s.size() > IDX_CLOAKED and bool(s[IDX_CLOAKED]):
		flags |= FLAG_CLOAKED_BIT
	return PackedByteArray([flags, clampi(roundi(float(s[IDX_INTEGRITY]) * BYTE_MAX), 0, 255)])


static func _encode_resources(s: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(RESOURCES_BYTES)
	out.encode_half(0, float(s[IDX_SHIELD_FRONT]))
	out.encode_half(2, float(s[IDX_SHIELD_REAR]))
	out.encode_half(4, float(s[IDX_CAPACITOR]))
	out.encode_u16(6, clampi(int(s[IDX_KILLS]), 0, U16_MAX))
	out.encode_u16(8, clampi(int(s[IDX_DEATHS]), 0, U16_MAX))
	return out


static func _encode_triggers(s: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, int(s[IDX_TRIGGERS]) & 0xFFFFFFFF)
	return out


## Length-prefixed block; an empty block (nothing to apply) is a two byte group.
static func _encode_damage(s: Array) -> PackedByteArray:
	var block: PackedByteArray = s[IDX_DAMAGE]
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, block.size())
	out.append_array(block)
	return out


static func _encode_steer(s: Array) -> PackedByteArray:
	var stick: Vector2 = s[IDX_STEER] if s[IDX_STEER] is Vector2 else Vector2.ZERO
	var out := PackedByteArray()
	out.resize(2)
	out.encode_s8(0, clampi(roundi(stick.x * STICK_STEPS), -127, 127))
	out.encode_s8(1, clampi(roundi(stick.y * STICK_STEPS), -127, 127))
	return out


## Soldier extra [jetting, weapon slot, stowed, rounds per weapon, kit]: bits, slot, rounds (the kit is its own group).
static func _encode_extra(extra: Array) -> PackedByteArray:
	var rounds: PackedInt32Array = extra[3] if extra.size() > 3 else PackedInt32Array()
	var count := mini(rounds.size(), 255)
	var out := PackedByteArray()
	out.resize(3 + count * 2)
	out.encode_u8(0, (1 if bool(extra[0]) else 0) | (2 if bool(extra[2]) else 0))
	out.encode_u8(1, clampi(int(extra[1]), 0, 255))
	out.encode_u8(2, count)
	for i in count:
		out.encode_u16(3 + i * 2, clampi(rounds[i], 0, U16_MAX))
	return out


static func _encode_kit(extra: Array) -> PackedByteArray:
	var kit: Array = extra[4] if extra.size() > 4 and extra[4] is Array else []
	var blob := var_to_bytes(kit)
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, blob.size())
	out.append_array(blob)
	return out


static func make_angle_code(radians: float) -> int:
	return roundi(fposmod(radians, TAU) / TAU * ANGLE_STEPS) & U16_MAX


static func make_angle(code: int) -> float:
	return float(code) / ANGLE_STEPS * TAU


# ------------------------------------------------------------------ records and packets

## One record: `id`, then the groups of `mask` taken from `groups`. With FLAG_SAME_CELL set the pose group's cell
## bytes are left out.
static func make_record(id: int, mask: int, groups: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(RECORD_HEADER_BYTES)
	out.encode_u16(0, id)
	out.encode_u16(2, mask)
	for bit in GROUP_BITS:
		if mask & bit == 0:
			continue
		var bytes: PackedByteArray = groups[bit]
		if bit == GROUP_POSE and mask & FLAG_SAME_CELL != 0:
			bytes = bytes.slice(CELL_BYTES)
		out.append_array(bytes)
	return out


## Splits `forgets` (entity ids) and `records` (make_record bytes) into packets of at most MAX_PAYLOAD_BYTES:
## `tick u32, tick rate u8, part u8, parts u8, forget count u8, record count u8, forget ids, records`.
## Nothing to say, no packet.
static func make_packets(tick: int, tick_hz: int, forgets: PackedInt32Array, records: Array) -> Array[PackedByteArray]:
	var parts: Array[Dictionary] = []
	for id in forgets:
		_part_with_room(parts, ID_BYTES, "forgets").forgets.append(id)
		parts.back().size += ID_BYTES
	for record: PackedByteArray in records:
		_part_with_room(parts, record.size(), "records").records.append(record)
		parts.back().size += record.size()
	var packets: Array[PackedByteArray] = []
	for i in parts.size():
		packets.append(_write_part(tick, tick_hz, i, parts.size(), parts[i]))
	return packets


static func _part_with_room(parts: Array[Dictionary], bytes: int, list_key: String) -> Dictionary:
	if not parts.is_empty():
		var last: Dictionary = parts.back()
		if last.size + bytes <= MAX_PAYLOAD_BYTES and last[list_key].size() < MAX_COUNT:
			return last
	parts.append({"forgets": PackedInt32Array(), "records": [], "size": HEADER_BYTES})
	return parts.back()


static func _write_part(tick: int, tick_hz: int, index: int, count: int, part: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(HEADER_BYTES + part.forgets.size() * ID_BYTES)
	out.encode_u32(0, tick)
	out.encode_u8(4, tick_hz)
	out.encode_u8(5, index)
	out.encode_u8(6, count)
	out.encode_u8(7, part.forgets.size())
	out.encode_u8(8, part.records.size())
	var at := HEADER_BYTES
	for id in part.forgets:
		out.encode_u16(at, id)
		at += ID_BYTES
	for record: PackedByteArray in part.records:
		out.append_array(record)
	return out


# ------------------------------------------------------------------ decoding (client)

## {tick, tick_hz, part, parts, forgets: PackedInt32Array, records: Array[Dictionary]} or {} for a malformed packet.
## A record is {id, mask, cell: Vector2i, fields: {state index: value}, extra: {...}, kit: Array, tier: int (NO_TIER
## when the record does not carry one)}.
## `cells` maps entity id -> the cell its last full pose carried (needed for FLAG_SAME_CELL records).
static func decode_packet(bytes: PackedByteArray, cells: Dictionary) -> Dictionary:
	if bytes.size() < HEADER_BYTES:
		return {}
	var r := StreamPeerBuffer.new()
	r.data_array = bytes
	var packet := {"tick": r.get_u32(), "tick_hz": r.get_u8(), "part": r.get_u8(), "parts": r.get_u8(), "forgets": PackedInt32Array(),
		"records": []}
	var forget_count := r.get_u8()
	var record_count := r.get_u8()
	for i in forget_count:
		packet.forgets.append(r.get_u16())
	var known_cells := cells.duplicate()
	for i in record_count:
		var record := _decode_record(r, known_cells)
		if record.is_empty() or r.get_position() > bytes.size():
			return {}
		known_cells[record.id] = record.cell
		packet.records.append(record)
	return packet if r.get_position() == bytes.size() else {}


static func _decode_record(r: StreamPeerBuffer, cells: Dictionary) -> Dictionary:
	if r.get_available_bytes() < RECORD_HEADER_BYTES:
		return {}
	var record := {"id": r.get_u16(), "mask": r.get_u16(), "fields": {}, "extra": {}, "kit": null, "tier": NO_TIER}
	var mask: int = record.mask
	if mask & GROUP_POSE != 0:
		if mask & FLAG_SAME_CELL != 0:
			if not cells.has(record.id):
				return {}
			record.cell = cells[record.id]
		else:
			record.cell = Vector2i(r.get_16(), r.get_16())
		_decode_pose(r, record)
	else:
		record.cell = cells.get(record.id, Vector2i.ZERO)
	if mask & GROUP_STATUS != 0:
		_decode_status(r, record.fields)
	if mask & GROUP_RESOURCES != 0:
		_decode_resources(r, record.fields)
	if mask & GROUP_TRIGGERS != 0:
		record.fields[IDX_TRIGGERS] = r.get_u32()
	if mask & GROUP_DAMAGE != 0:
		record.fields[IDX_DAMAGE] = _read_block(r)
	if mask & GROUP_EXTRA != 0:
		_decode_extra(r, record.extra)
	if mask & GROUP_KIT != 0:
		record.kit = bytes_to_var(_read_block(r))
	if mask & GROUP_STEER != 0:
		record.fields[IDX_STEER] = Vector2(r.get_8(), r.get_8()) / STICK_STEPS
	if mask & GROUP_TIER != 0:
		record.tier = r.get_u8()
	return record


static func _decode_pose(r: StreamPeerBuffer, record: Dictionary) -> void:
	var cell: Vector2i = record.cell
	var f: Dictionary = record.fields
	var x := float(cell.x) * CELL_M + r.get_u16() / CM_PER_M
	var z := float(cell.y) * CELL_M + r.get_u16() / CM_PER_M
	f[IDX_POS] = Vector3(x, r.get_u16() * HEIGHT_STEP_M - HEIGHT_OFFSET_M, z)
	f[IDX_YAW] = make_angle(r.get_u16())
	f[IDX_TORSO] = make_angle(r.get_u16())
	f[IDX_PITCH] = make_angle(r.get_u16())
	f[IDX_SPEED] = r.get_16() / SPEED_STEP


static func _decode_status(r: StreamPeerBuffer, fields: Dictionary) -> void:
	var flags := r.get_u8()
	fields[IDX_ALIVE] = flags & FLAG_ALIVE_BIT != 0
	fields[IDX_CLOAKED] = flags & FLAG_CLOAKED_BIT != 0
	fields[IDX_INTEGRITY] = r.get_u8() / BYTE_MAX


static func _decode_resources(r: StreamPeerBuffer, fields: Dictionary) -> void:
	fields[IDX_SHIELD_FRONT] = r.get_half()
	fields[IDX_SHIELD_REAR] = r.get_half()
	fields[IDX_CAPACITOR] = r.get_half()
	fields[IDX_KILLS] = r.get_u16()
	fields[IDX_DEATHS] = r.get_u16()


static func _decode_extra(r: StreamPeerBuffer, extra: Dictionary) -> void:
	var bits := r.get_u8()
	extra["jetting"] = bits & 1 != 0
	extra["stowed"] = bits & 2 != 0
	extra["slot"] = r.get_u8()
	var rounds := PackedInt32Array()
	for i in r.get_u8():
		rounds.append(r.get_u16())
	extra["rounds"] = rounds


static func _read_block(r: StreamPeerBuffer) -> PackedByteArray:
	var size := r.get_u16()
	if r.get_available_bytes() < size:
		return PackedByteArray()
	return r.get_data(size)[1]

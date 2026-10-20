class_name InputFrame
extends RefCounted
## One sequenced input frame of a pilot (docs/DEDICATED_SERVER_SCALING.md section 2.2): the controls dictionary of
## BattleNetSync.make_controls plus a sequence number, packed into about 22 bytes. A client sends the last few
## frames it has not seen acknowledged in every packet (redundancy beats resending on UDP).
## Packet: body net id u16, echo tick u32, frame count u8, then per frame: seq u32, throttle / turn / torso / pitch
## as i16, trigger bits u16, target id u16, flags u8, weapon slot u8, missile stick 2 x i8.
## The sender runs its own prediction on the quantized values (make_quantized), so both ends step the same input.

const REDUNDANCY := 3
const MAX_FRAMES := 8
const HEADER_BYTES := 7
const FRAME_BYTES := 4 + 4 * 2 + 2 + 2 + 1 + 1 + 2
const ANALOG_STEPS := 32767.0
const STICK_STEPS := 127.0
const FLAG_JET := 1
const FLAG_JUMP := 2
const FLAG_STEER := 4
const FLAG_CLOAK := 8


## The packet carrying `frames` (controls dictionaries with a "seq" key) for the body `body_id`.
static func make_packet(body_id: int, echo_tick: int, frames: Array) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	var count := mini(frames.size(), MAX_FRAMES)
	buffer.put_u16(body_id)
	buffer.put_u32(echo_tick)
	buffer.put_u8(count)
	for i in count:
		_put_frame(buffer, frames[i])
	return buffer.data_array


## {body, echo, frames: Array of controls dictionaries with "seq"}; empty when the packet is malformed.
static func decode_packet(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < HEADER_BYTES:
		return {}
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	var out := {"body": buffer.get_u16(), "echo": buffer.get_u32(), "frames": []}
	var count := buffer.get_u8()
	if count > MAX_FRAMES or buffer.get_available_bytes() < count * FRAME_BYTES:
		return {}
	for i in count:
		out.frames.append(_get_frame(buffer))
	return out


## `controls` as the receiver of a packet sees them (quantized), keeping its "seq".
static func make_quantized(controls: Dictionary) -> Dictionary:
	var buffer := StreamPeerBuffer.new()
	_put_frame(buffer, controls)
	buffer.seek(0)
	return _get_frame(buffer)


## Puts the movement part of `frame` on the body: the analog controls, aim and a soldier's jet and jump.
## Weapons, triggers and target stay the pilot's own.
static func apply_movement(h: Herc, frame: Dictionary) -> void:
	h.throttle = float(frame.throttle)
	h.turn = float(frame.turn)
	h.torso_target = float(frame.torso)
	h.pitch_target = float(frame.pitch)
	if not (h is Infantry):
		h.cloak_input = bool(frame.get("cloak", false))
	if h is Infantry:
		var extra: Array = frame.get("infantry", [])
		if extra.size() >= 2:
			(h as Infantry).jet_input = bool(extra[0])
			(h as Infantry).jump_input = bool(extra[1])


## `frame` with the movement of a pilot who lets go of everything: aim and weapons stay.
static func make_neutral(frame: Dictionary) -> Dictionary:
	var out := frame.duplicate(true)
	out.throttle = 0.0
	out.turn = 0.0
	if out.has("infantry"):
		var extra: Array = out.infantry
		extra[0] = false
		extra[1] = false
	return out


static func _put_frame(buffer: StreamPeerBuffer, c: Dictionary) -> void:
	var extra: Array = c.get("infantry", [])
	var steer: Variant = c.get("missile_steer")
	var flags := 0
	if extra.size() >= 1 and bool(extra[0]):
		flags |= FLAG_JET
	if extra.size() >= 2 and bool(extra[1]):
		flags |= FLAG_JUMP
	if steer is Vector2:
		flags |= FLAG_STEER
	if bool(c.get("cloak", false)):
		flags |= FLAG_CLOAK
	buffer.put_u32(int(c.get("seq", 0)))
	buffer.put_16(_pack_unit(float(c.get("throttle", 0.0))))
	buffer.put_16(_pack_unit(float(c.get("turn", 0.0))))
	buffer.put_16(_pack_angle(float(c.get("torso", 0.0))))
	buffer.put_16(_pack_angle(float(c.get("pitch", 0.0))))
	buffer.put_u16(int(c.get("triggers", 0)) & 0xFFFF)
	buffer.put_u16(int(c.get("target", 0)) & 0xFFFF)
	buffer.put_u8(flags)
	buffer.put_u8(int(extra[2]) if extra.size() >= 3 else 0)
	var stick: Vector2 = (steer as Vector2).clamp(-Vector2.ONE, Vector2.ONE) if steer is Vector2 else Vector2.ZERO
	buffer.put_8(roundi(stick.x * STICK_STEPS))
	buffer.put_8(roundi(stick.y * STICK_STEPS))


static func _get_frame(buffer: StreamPeerBuffer) -> Dictionary:
	var c := {"seq": buffer.get_u32()}
	c["throttle"] = _unpack_unit(buffer.get_16())
	c["turn"] = _unpack_unit(buffer.get_16())
	c["torso"] = _unpack_angle(buffer.get_16())
	c["pitch"] = _unpack_angle(buffer.get_16())
	c["triggers"] = buffer.get_u16()
	c["target"] = buffer.get_u16()
	var flags := buffer.get_u8()
	var slot := buffer.get_u8()
	var stick := Vector2(buffer.get_8() / STICK_STEPS, buffer.get_8() / STICK_STEPS)
	c["infantry"] = [flags & FLAG_JET != 0, flags & FLAG_JUMP != 0, slot]
	if flags & FLAG_STEER != 0:
		c["missile_steer"] = stick
	c["cloak"] = flags & FLAG_CLOAK != 0
	return c


static func _pack_unit(v: float) -> int:
	return roundi(clampf(v, -1.0, 1.0) * ANALOG_STEPS)


static func _unpack_unit(q: int) -> float:
	return q / ANALOG_STEPS


static func _pack_angle(radians: float) -> int:
	return roundi(wrapf(radians, -PI, PI) / PI * ANALOG_STEPS)


static func _unpack_angle(q: int) -> float:
	return q / ANALOG_STEPS * PI

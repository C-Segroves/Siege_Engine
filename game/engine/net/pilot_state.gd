class_name PilotState
extends RefCounted
## The part of a pilot's body that movement depends on: what the server echoes with the last input sequence it
## processed and what the client's prediction stores per frame (position, velocity, heading, speed, capacitor,
## floor contact). Packet: body u16, seq u32, server tick u32, tick rate u8, 9 x f32, flags u8.

const FLAG_ON_FLOOR := 1
const FLAG_ALIVE := 2
const PACKET_BYTES := 2 + 4 + 4 + 1 + 4 * 9 + 1

var seq := 0
var position := Vector3.ZERO
var velocity := Vector3.ZERO
var yaw := 0.0
var speed := 0.0
var capacitor := 0.0
var on_floor := false
var alive := true


static func make_from(h: Herc) -> PilotState:
	var s := PilotState.new()
	s.position = h.global_position
	s.velocity = h.velocity
	s.yaw = h.rotation.y
	s.speed = h.speed
	s.capacitor = h.capacitor
	s.on_floor = h.is_on_floor()
	s.alive = h.alive
	return s


## Puts the state on the body (no physics step); the floor contact is found again by snapping onto the ground.
func apply_to(h: Herc) -> void:
	h.global_position = position
	h.velocity = velocity
	h.rotation.y = yaw
	h.speed = speed
	h.capacitor = capacitor
	if on_floor:
		h.apply_floor_snap()


## Distance (m) between the positions of two states.
func make_error(other: PilotState) -> float:
	return position.distance_to(other.position)


func make_packet(body_id: int, tick: int, tick_hz: int) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.put_u16(body_id)
	buffer.put_u32(seq)
	buffer.put_u32(tick)
	buffer.put_u8(tick_hz)
	for v: float in [position.x, position.y, position.z, velocity.x, velocity.y, velocity.z, yaw, speed, capacitor]:
		buffer.put_float(v)
	buffer.put_u8((FLAG_ON_FLOOR if on_floor else 0) | (FLAG_ALIVE if alive else 0))
	return buffer.data_array


## {body, tick, tick_hz, state}; empty when the packet is malformed.
static func decode_packet(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() != PACKET_BYTES:
		return {}
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	var out := {"body": buffer.get_u16()}
	var s := PilotState.new()
	s.seq = buffer.get_u32()
	out["tick"] = buffer.get_u32()
	out["tick_hz"] = buffer.get_u8()
	s.position = Vector3(buffer.get_float(), buffer.get_float(), buffer.get_float())
	s.velocity = Vector3(buffer.get_float(), buffer.get_float(), buffer.get_float())
	s.yaw = buffer.get_float()
	s.speed = buffer.get_float()
	s.capacitor = buffer.get_float()
	var flags := buffer.get_u8()
	s.on_floor = flags & FLAG_ON_FLOOR != 0
	s.alive = flags & FLAG_ALIVE != 0
	out["state"] = s
	return out

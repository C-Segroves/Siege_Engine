class_name FarBots
extends Node3D
## Cheap client drawing of far units (docs/DEDICATED_SERVER_SCALING.md chunk L): one MultiMesh per body kind, one
## instance per unit, no scene node, no collision, no animation. A unit gets a new pose every few hundred
## milliseconds (far tier snapshot rate); `_process` interpolates from the previous pose to the newest one over the
## time that separated them, as the full nodes do. The caller promotes a unit to a full node by calling `remove`
## and building it (BattleFarUnits); `make_pose` hands over where the proxy was drawn.

enum Kind { SOLDIER, VEHICLE }

const MIN_DURATION := 0.05
const MAX_DURATION := 2.0
const INITIAL_CAPACITY := 64
const TRANSFORM_FLOATS := 12
const COLOR_FLOATS := 4
const INSTANCE_FLOATS := TRANSFORM_FLOATS + COLOR_FLOATS
## Proxy sizes in metres (an armoured soldier / a Herc-class vehicle).
const SOLDIER_RADIUS := 0.45
const SOLDIER_HEIGHT := 2.1
const VEHICLE_SIZE := Vector3(4.0, 5.0, 7.0)
const DEAD_SCALE := 0.0

var _slot_of := {}                          # unit id -> slot
var _ids: PackedInt32Array = []
var _kinds: PackedInt32Array = []
var _from_pos: PackedVector3Array = []
var _to_pos: PackedVector3Array = []
var _from_yaw: PackedFloat32Array = []
var _to_yaw: PackedFloat32Array = []
var _elapsed: PackedFloat32Array = []
var _duration: PackedFloat32Array = []
var _alive: PackedByteArray = []
var _colors: PackedColorArray = []
var _multimeshes: Array[MultiMesh] = []
var _buffers: Array[PackedFloat32Array] = []


func _ready() -> void:
	for kind in Kind.values():
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = _make_mesh(kind)
		multimesh.instance_count = INITIAL_CAPACITY
		multimesh.visible_instance_count = 0
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = multimesh
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.extra_cull_margin = 16384.0   # the instances are spread over the map; the node's own bounds are the origin
		add_child(instance)
		_multimeshes.append(multimesh)
		_buffers.append(PackedFloat32Array())


func count() -> int:
	return _ids.size()


func has(id: int) -> bool:
	return _slot_of.has(id)


## Gives unit `id` a new pose that the proxy reaches `seconds` from now (the time since the unit's previous pose).
func apply_pose(id: int, kind: Kind, pos: Vector3, yaw: float, seconds: float) -> void:
	if not _slot_of.has(id):
		_add(id, kind, pos, yaw)
		return
	var slot: int = _slot_of[id]
	_from_pos[slot] = make_position(slot)
	_from_yaw[slot] = make_yaw(slot)
	_to_pos[slot] = pos
	_to_yaw[slot] = yaw
	_elapsed[slot] = 0.0
	_duration[slot] = clampf(seconds, MIN_DURATION, MAX_DURATION)


func apply_alive(id: int, alive: bool) -> void:
	if _slot_of.has(id):
		_alive[_slot_of[id]] = 1 if alive else 0


func apply_color(id: int, color: Color) -> void:
	if _slot_of.has(id):
		_colors[_slot_of[id]] = color


## Drops the proxy of `id` (no-op when it has none): the unit is promoted to a full node, or gone.
func remove(id: int) -> void:
	if not _slot_of.has(id):
		return
	var slot: int = _slot_of[id]
	var last := _ids.size() - 1
	if slot != last:
		_move_slot(last, slot)
	_slot_of.erase(id)
	_resize(last)


## Where the proxy in `slot` is drawn right now.
func make_position(slot: int) -> Vector3:
	return _from_pos[slot].lerp(_to_pos[slot], _make_fraction(slot))


func make_yaw(slot: int) -> float:
	return lerp_angle(_from_yaw[slot], _to_yaw[slot], _make_fraction(slot))


## {pos, yaw, alive} where the proxy of `id` is drawn now, {} when it has none.
func make_pose(id: int) -> Dictionary:
	if not _slot_of.has(id):
		return {}
	var slot: int = _slot_of[id]
	return {"pos": make_position(slot), "yaw": make_yaw(slot), "alive": _alive[slot] == 1}


func make_ids() -> PackedInt32Array:
	return _ids.duplicate()


## Advances every proxy by `delta` and rewrites the instance buffers.
func advance(delta: float) -> void:
	for slot in _ids.size():
		_elapsed[slot] += delta
	_write_instances()


func _process(delta: float) -> void:
	advance(delta)


# ------------------------------------------------------------------ slots

func _add(id: int, kind: Kind, pos: Vector3, yaw: float) -> void:
	_slot_of[id] = _ids.size()
	_ids.append(id)
	_kinds.append(kind)
	_from_pos.append(pos)
	_to_pos.append(pos)
	_from_yaw.append(yaw)
	_to_yaw.append(yaw)
	_elapsed.append(0.0)
	_duration.append(MIN_DURATION)
	_alive.append(1)
	_colors.append(Color.WHITE)


func _move_slot(from: int, to: int) -> void:
	_slot_of[_ids[from]] = to
	_ids[to] = _ids[from]
	_kinds[to] = _kinds[from]
	_from_pos[to] = _from_pos[from]
	_to_pos[to] = _to_pos[from]
	_from_yaw[to] = _from_yaw[from]
	_to_yaw[to] = _to_yaw[from]
	_elapsed[to] = _elapsed[from]
	_duration[to] = _duration[from]
	_alive[to] = _alive[from]
	_colors[to] = _colors[from]


func _resize(size: int) -> void:
	_ids.resize(size)
	_kinds.resize(size)
	_from_pos.resize(size)
	_to_pos.resize(size)
	_from_yaw.resize(size)
	_to_yaw.resize(size)
	_elapsed.resize(size)
	_duration.resize(size)
	_alive.resize(size)
	_colors.resize(size)


func _make_fraction(slot: int) -> float:
	return clampf(_elapsed[slot] / _duration[slot], 0.0, 1.0)


# ------------------------------------------------------------------ drawing

func _write_instances() -> void:
	if _multimeshes.is_empty():
		return
	var written: Array[int] = [0, 0]
	for kind in _multimeshes.size():
		_ensure_capacity(kind)
	for slot in _ids.size():
		var kind: int = _kinds[slot]
		_write_instance(_buffers[kind], written[kind], slot)
		written[kind] += 1
	for kind in _multimeshes.size():
		_multimeshes[kind].visible_instance_count = written[kind]
		if written[kind] > 0:
			_multimeshes[kind].buffer = _buffers[kind]


func _ensure_capacity(kind: int) -> void:
	var needed := 0
	for k: int in _kinds:
		needed += 1 if k == kind else 0
	var multimesh := _multimeshes[kind]
	if needed > multimesh.instance_count:
		multimesh.instance_count = maxi(needed, multimesh.instance_count * 2)
	if _buffers[kind].size() != multimesh.instance_count * INSTANCE_FLOATS:
		_buffers[kind].resize(multimesh.instance_count * INSTANCE_FLOATS)


func _write_instance(buffer: PackedFloat32Array, index: int, slot: int) -> void:
	var at := index * INSTANCE_FLOATS
	var pos := make_position(slot) + Vector3.UP * _make_lift(_kinds[slot])
	var basis := Basis(Vector3.UP, make_yaw(slot))
	if _alive[slot] == 0:
		basis = basis.scaled(Vector3.ONE * DEAD_SCALE)
	buffer[at + 0] = basis.x.x
	buffer[at + 1] = basis.y.x
	buffer[at + 2] = basis.z.x
	buffer[at + 3] = pos.x
	buffer[at + 4] = basis.x.y
	buffer[at + 5] = basis.y.y
	buffer[at + 6] = basis.z.y
	buffer[at + 7] = pos.y
	buffer[at + 8] = basis.x.z
	buffer[at + 9] = basis.y.z
	buffer[at + 10] = basis.z.z
	buffer[at + 11] = pos.z
	var color := _colors[slot]
	buffer[at + 12] = color.r
	buffer[at + 13] = color.g
	buffer[at + 14] = color.b
	buffer[at + 15] = color.a


## Height of the mesh centre above the unit's feet.
static func _make_lift(kind: int) -> float:
	return SOLDIER_HEIGHT * 0.5 if kind == Kind.SOLDIER else VEHICLE_SIZE.y * 0.5


static func _make_mesh(kind: int) -> Mesh:
	var mesh: PrimitiveMesh
	if kind == Kind.SOLDIER:
		var capsule := CapsuleMesh.new()
		capsule.radius = SOLDIER_RADIUS
		capsule.height = SOLDIER_HEIGHT
		capsule.radial_segments = 6
		capsule.rings = 2
		mesh = capsule
	else:
		var box := BoxMesh.new()
		box.size = VEHICLE_SIZE
		mesh = box
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	mesh.material = material
	return mesh

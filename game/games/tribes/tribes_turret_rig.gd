class_name TribesTurretRig
extends RefCounted
## How a Tribes turret looks while it works (TribesTurret): the shape's own sequences, posed the way the engines
## drive them (docs/TRIBES_BASE_EQUIPMENT.md section 2):
##   turn      one full revolution over the cycle (Tribes 1 "turn", Tribes 2 "Turn"): the heading;
##   elevate   the barrel's elevation from one end of its range to the other ("elevate" / "Elevate");
##   activate  Tribes 1 "power" (Turret::onActivate plays it, onDeactivate stops it), Tribes 2 the base's
##             "Activate" and the barrel's "Deploy" (the barrel image's activate state), over activationMS;
##   fire      "fire" / "Fire" once per shot.
## Overlapping sequences are applied in the order of their priority (higher wins on shared nodes, as the Darkstar
## threads do). A Tribes 2 barrel is a second shape whose "Mountpoint" node sits on the base's mount node.
## How a sequence's phase maps to an angle is measured from the shape itself (calibrate): the turning node's
## heading at two phases, the elevating node's pitch at both ends.

const TURN_NAMES := ["turn"]
const ELEVATE_NAMES := ["elevate"]
const ACTIVATE_NAMES := ["power", "activate", "deploy"]
const FIRE_NAMES := ["fire", "fire1"]
const BARREL_MOUNT_NODE := "mountpoint"
## Phase where the turn calibration samples the heading (a quarter turn: unambiguous direction).
const TURN_PROBE_PHASE := 0.25
const FORWARD := Vector3(0, 0, -1)

var base: ShapeInstance
var barrel: ShapeInstance
var _turn := -1
var _elevate := -1
var _activate := -1
var _fire := -1
var _barrel_activate := -1
var _barrel_fire := -1
var _order: Array[int] = []
var _yaw_zero := 0.0
var _yaw_sign := 1.0
var _pitch_low := 0.0
var _pitch_high := 0.0
var _mount_node: Node3D
var _barrel_offset := Transform3D.IDENTITY
var _fire_phase := 1.0
var _fire_seconds := 0.0


## The rig of `shape` (and of the Tribes 2 `barrel_shape_id` mounted on node `mount_name`, "" = none).
static func make(shape: ShapeInstance, barrel_shape_id: String, mount_name: String, pal: String) -> TribesTurretRig:
	var rig := TribesTurretRig.new()
	rig.base = shape
	rig._turn = find_sequence(shape, TURN_NAMES)
	rig._elevate = find_sequence(shape, ELEVATE_NAMES)
	rig._activate = find_sequence(shape, ACTIVATE_NAMES)
	rig._fire = find_sequence(shape, FIRE_NAMES)
	rig._order = rig._make_order()
	rig._calibrate()
	if barrel_shape_id != "" and not Assets.shape(barrel_shape_id).is_empty():
		rig._build_barrel(barrel_shape_id, mount_name, pal)
	return rig


## Index of the first Darkstar sequence named one of `names` (case-insensitive); -1 when none.
static func find_sequence(shape: ShapeInstance, names: Array) -> int:
	return ShapeCycles.find_named(shape, names)


static func find_node(shape: ShapeInstance, node_name: String) -> Node3D:
	var list: Array = shape.shape.get("nodes", [])
	for i in list.size():
		if str(list[i].get("name", "")).to_lower() == node_name.to_lower() and i < shape.nodes.size():
			return shape.nodes[i]
	return null


func can_aim() -> bool:
	return _turn >= 0


func _make_order() -> Array[int]:
	var seqs: Array = base.shape.get("ds_sequences", [])
	var keyed := []
	var slot := 0
	for i in [_activate, _turn, _elevate, _fire]:
		if i >= 0:
			keyed.append([int(seqs[i].get("priority", 0)), slot, i])
		slot += 1
	keyed.sort()
	var out: Array[int] = []
	for k in keyed:
		out.append(int(k[2]))
	return out


## The node a sequence moves most (its first track whose keys change).
func _moving_node(index: int) -> Node3D:
	for track in base.shape.ds_sequences[index].tracks:
		var keys: Array = track.keys
		if keys.size() > 1 and keys.any(func(k: Array) -> bool: return int(k[1]) != int(keys[0][1])):
			if int(track.node) < base.nodes.size():
				return base.nodes[int(track.node)]
	return null


func _calibrate() -> void:
	if _turn >= 0:
		var node := _moving_node(_turn)
		if node:
			ShapeCycles.pose(base, _turn, 0.0)
			_yaw_zero = _heading_of(node)
			ShapeCycles.pose(base, _turn, TURN_PROBE_PHASE)
			_yaw_sign = 1.0 if wrapf(_heading_of(node) - _yaw_zero, -PI, PI) >= 0.0 else -1.0
	if _elevate >= 0:
		var enode := _moving_node(_elevate)
		if enode:
			ShapeCycles.pose(base, _elevate, 0.0, false)
			_pitch_low = _pitch_of(enode)
			ShapeCycles.pose(base, _elevate, 1.0, false)
			_pitch_high = _pitch_of(enode)
	base.reset_pose()


func _heading_of(node: Node3D) -> float:
	var f := (base.global_transform.affine_inverse() * node.global_transform).basis * FORWARD
	return atan2(-f.x, -f.z)


func _pitch_of(node: Node3D) -> float:
	var f := ((base.global_transform.affine_inverse() * node.global_transform).basis * FORWARD).normalized()
	return asin(clampf(f.y, -1.0, 1.0))


func _build_barrel(shape_id: String, mount_name: String, pal: String) -> void:
	_mount_node = find_node(base, mount_name)
	if _mount_node == null:
		return
	barrel = ShapeInstance.new()
	barrel.build(Assets.shape(shape_id), 0, pal)
	_mount_node.add_child(barrel)
	var point := find_node(barrel, BARREL_MOUNT_NODE)
	_barrel_offset = (barrel.global_transform.affine_inverse() * point.global_transform).affine_inverse() if point else Transform3D.IDENTITY
	barrel.transform = _barrel_offset
	_barrel_activate = find_sequence(barrel, ACTIVATE_NAMES)
	_barrel_fire = find_sequence(barrel, FIRE_NAMES)


## Starts the fire sequence (one per shot).
func play_fire() -> void:
	var seq := _fire if _fire >= 0 else _barrel_fire
	if seq < 0:
		return
	var shape := base if _fire >= 0 else barrel
	_fire_seconds = maxf(ShapeCycles.cycle_seconds(shape, seq, 0.0), 0.01)
	_fire_phase = 0.0


## Poses the turret: heading `yaw` and elevation `pitch` (radians, in the turret's own frame), activation
## `active` (0 = folded, 1 = deployed), advancing the fire sequence by `delta`.
func apply(yaw: float, pitch: float, active: float, delta: float) -> void:
	_fire_phase = minf(1.0, _fire_phase + delta / maxf(_fire_seconds, 0.01))
	for i in _order:
		ShapeCycles.pose(base, i, _phase_of(i, yaw, pitch, active), i == _turn)
	if barrel:
		if _barrel_activate >= 0:
			ShapeCycles.pose(barrel, _barrel_activate, active, false)
		if _barrel_fire >= 0 and _fire < 0:
			ShapeCycles.pose(barrel, _barrel_fire, _fire_phase, false)


func _phase_of(index: int, yaw: float, pitch: float, active: float) -> float:
	if index == _turn:
		return fposmod(_yaw_sign * wrapf(yaw - _yaw_zero, -PI, PI) / TAU, 1.0)
	if index == _elevate:
		var span := _pitch_high - _pitch_low
		return clampf((pitch - _pitch_low) / span, 0.0, 1.0) if absf(span) > 0.0001 else 0.0
	if index == _activate:
		return active
	return _fire_phase

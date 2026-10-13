extends RefCounted
## Torso twist / turret yaw and pitch of a vehicle model, posed on top of the leg pose every frame.
##
## Vehicle def keys (docs/formats/animation.md "Torso and turret"):
##   torso_node        node turned by the torso yaw (3Space torso, Starsiege "head0" Herc torso / tank turret);
##                     -1 = none
##   cockpit_node      node turned by the pitch (the view node); the same node as torso_node = one node turns
##                     and pitches (Starsiege head); -1 = none (the aim alone carries the pitch)
##   lower_body_nodes  children of torso_node that carry the legs / hips (Starsiege Basilisk, Minotaur ...):
##                     counter-rotated so the twist turns the upper body only and the feet stay planted
##   pitch_mounts      true = the weapon mount markers pitch on their own (Starsiege tank hardpoints,
##                     newHardPoint X_rot_rnge): the barrels pitch, the turret only yaws

const DEFAULT_TORSO_NODE := 4
const DEFAULT_PITCH_NODE := 11
const NO_NODE := -1

var shape: ShapeInstance
var torso_node := NO_NODE
var pitch_node := NO_NODE
var lower_body_nodes: Array[int] = []
var pitch_mounts: Array[Node3D] = []


## `mounts` = the weapon mount markers built for the model (HercModel.build_mounts values: one hardpoint frame per gun).
func _init(def: Dictionary, inst: ShapeInstance, mounts: Array) -> void:
	shape = inst
	torso_node = _valid_node(int(def.get("torso_node", DEFAULT_TORSO_NODE)))
	pitch_node = _valid_node(int(def.get("cockpit_node", DEFAULT_PITCH_NODE)))
	for i in def.get("lower_body_nodes", []):
		if _valid_node(int(i)) != NO_NODE and torso_node != NO_NODE:
			lower_body_nodes.append(int(i))
	if bool(def.get("pitch_mounts", false)):
		for m in mounts:
			if m is Marker3D:
				pitch_mounts.append(m)


## Poses the torso for this frame: `yaw` (rad, + = left) and `pitch` (rad, + = up). `animated` tells
## whether this frame's leg pose wrote a node (a Callable(int) -> bool, HercAnimator.animates); the turn
## builds on that pose, else on the node's default.
func apply(yaw: float, pitch: float, animated: Callable) -> void:
	var twist := Basis(Vector3.UP, yaw)
	var tilt := Basis(Vector3.RIGHT, pitch)
	if torso_node != NO_NODE and torso_node == pitch_node:
		_apply_upper_body(twist * tilt, animated)
	else:
		if torso_node != NO_NODE:
			_apply_upper_body(twist, animated)
		if pitch_node != NO_NODE:
			_turn_node(pitch_node, tilt, animated)
	for m in pitch_mounts:
		m.basis = tilt


## Turns the torso node by `turn`; the legs hanging below it keep their world pose.
func _apply_upper_body(turn: Basis, animated: Callable) -> void:
	var before := _base_transform(torso_node, animated)
	_turn_node(torso_node, turn, animated)
	var undo := shape.nodes[torso_node].transform.affine_inverse() * before
	for i in lower_body_nodes:
		shape.nodes[i].transform = undo * _base_transform(i, animated)


func _turn_node(i: int, turn: Basis, animated: Callable) -> void:
	var base := _base_transform(i, animated)
	shape.nodes[i].transform = Transform3D(turn * base.basis, base.origin)


func _base_transform(i: int, animated: Callable) -> Transform3D:
	if animated.call(i):
		return shape.nodes[i].transform
	return ShapeInstance.tf_to_transform(shape.shape.transforms[int(shape.shape.nodes[i].default)])


func _valid_node(i: int) -> int:
	return i if i >= 0 and i < shape.nodes.size() else NO_NODE

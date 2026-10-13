class_name Tribes2Transforms
extends RefCounted
## Tribes 2's transform strings for the mission's objects (Tribes2MissionRuntime.transforms):
## "x y z ax ay az angle" in the original frame (x east, y north, z up), the angle in radians as getTransform
## gives it; a `.mis` "rotation" field is "ax ay az degrees". Torque turns an object by -angle about the axis
## (m_quatF_set_matF writes the transposed matrix, tools/export_tribes2_maps.py): engine yaw = -angle for an
## upright axis. Positions convert with TribesSimObjects.to_engine / to_original.

## getWorldBoxCenter: this far above an object's origin (metres; about half a soldier's or an item's box).
const BOX_CENTER_HEIGHT := 1.0
const AXIS_UPRIGHT := 0.5

var sim: TribesSimObjects
var actors: TribesActors
var battle: Node3D


func _init(runtime: TribesMissionRuntime) -> void:
	sim = runtime.sim
	actors = runtime.actors
	battle = runtime.battle


## "x y z ax ay az angle" -> engine transform on the ground there (soldiers settle onto floors above it).
func make_transform(s: String) -> Transform3D:
	var p := DarkstarStdLib.make_parts(s, " ")
	var pos := TribesSimObjects.to_engine(DarkstarStdLib.make_vector(s))
	var yaw := 0.0
	if p.size() >= 7 and absf(float(p[5])) > AXIS_UPRIGHT:
		yaw = -float(p[6]) * signf(float(p[5]))
	return Transform3D(Basis(Vector3.UP, yaw), battle.infantry.make_on_ground(pos))


func make_object_transform(id: int) -> Transform3D:
	return make_transform(make_transform_string(id))


## getTransform: a node's place and heading, else the record's position and rotation (degrees -> radians).
func make_transform_string(id: int) -> String:
	var rec := sim.get_record(id)
	var node = rec.get("node")
	var pos := make_position_string(id)
	if node is Node3D and is_instance_valid(node):
		return "%s 0 0 1 %s" % [pos, DarkstarStdLib.make_number_string(-(node as Node3D).rotation.y)]
	var rot := DarkstarStdLib.make_parts(DarkstarScript.to_str(rec.get("fields", {}).get("rotation", "1 0 0 0")), " ")
	if rot.size() < 4:
		return pos + " 1 0 0 0"
	return "%s %s %s %s %s" % [pos, rot[0], rot[1], rot[2], DarkstarStdLib.make_number_string(deg_to_rad(float(rot[3])))]


func make_position_string(id: int) -> String:
	return DarkstarStdLib.make_vector_string(TribesSimObjects.to_original(sim.position_of(id)))


func make_box_center_string(id: int) -> String:
	return DarkstarStdLib.make_vector_string(TribesSimObjects.to_original(sim.position_of(id)) + Vector3(0, 0, BOX_CENTER_HEIGHT))


func make_forward_string(id: int) -> String:
	var node = sim.get_record(id).get("node")
	var f := -(node as Node3D).global_basis.z if node is Node3D and is_instance_valid(node) else Vector3.FORWARD
	return DarkstarStdLib.make_vector_string(TribesSimObjects.to_original(f))


## setTransform: a soldier or vehicle moves and turns there, another object's record does.
func apply_transform(id: int, s: String) -> void:
	var xf := make_transform(s)
	xf.origin = TribesSimObjects.to_engine(DarkstarStdLib.make_vector(s))
	var node = sim.get_record(id).get("node")
	if node is Infantry and is_instance_valid(node):
		var soldier := node as Infantry
		soldier.global_position = xf.origin
		soldier.velocity = Vector3.ZERO
		soldier.torso_target = xf.basis.get_euler().y
	elif node is Node3D and is_instance_valid(node):
		(node as Node3D).global_transform = xf
	elif sim.exists(id):
		_apply_record_transform(id, s)


func _apply_record_transform(id: int, s: String) -> void:
	var p := DarkstarStdLib.make_parts(s, " ")
	sim.objects[id].fields["position"] = DarkstarStdLib.make_vector_string(DarkstarStdLib.make_vector(s))
	if p.size() >= 7:
		sim.objects[id].fields["rotation"] = "%s %s %s %s" % [p[3], p[4], p[5],
			DarkstarStdLib.make_number_string(rad_to_deg(float(p[6])))]


func make_velocity_string(id: int) -> String:
	var s := actors.soldier_of(id)
	return DarkstarStdLib.make_vector_string(TribesSimObjects.to_original(s.velocity)) if s else "0 0 0"


func apply_velocity(id: int, v: Vector3) -> void:
	var s := actors.soldier_of(id)
	if s:
		s.velocity = TribesSimObjects.to_engine(v)

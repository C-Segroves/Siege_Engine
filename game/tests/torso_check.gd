extends Node
## Headless check of the torso twist / turret yaw and pitch (engine/torso_rig.gd, docs/formats/animation.md
## "Torso and turret"), standing and mid-stride:
##   1. every Starsiege Herc and tank turns its head node (no Herc without a visual twist);
##   2. the twist turns the upper body and its weapon muzzles (and their pods) about the torso node;
##   3. the legs (every node outside the turned upper body) keep their world pose, also under pitch;
##   4. tanks: the turret yaws, the barrels (weapon mounts) pitch, the view stays with the chase camera;
##   5. Battledrome pods hang off their torso node and turn with it.
##   godot --headless --audio-driver Dummy --path game res://tests/torso_check.tscn

## Torso twist / turret rig (engine/torso_rig.gd, preloaded: no global class to register).
const TorsoRig := preload("res://engine/torso_rig.gd")
const TWIST := 0.6
const PITCH := 0.3
const FRAME := 1.0 / 30.0
## Leg nodes may not move (m) when the torso turns.
const LEG_TOLERANCE := 0.001
## Upper-body points must land where the twist about the torso node puts them (m).
const TWIST_TOLERANCE := 0.01
## A muzzle this far (m) from the torso axis must visibly move.
const MIN_ARM := 0.2
const ANGLE_TOLERANCE := 0.01
const PACKS := ["starsiege", "bd"]

var _failures := 0
var _checked := {}


func _ready() -> void:
	for id in Packs.vehicles:
		var v: Dictionary = Packs.vehicles[id]
		if str(v.get("pack", "")) in PACKS and _is_ground_vehicle(v):
			_check_vehicle(v)
	for kind in _checked:
		print("  %s: %d checked" % [kind, _checked[kind]])
	_expect(_checked.get("starsiege herc", 0) >= 30, "Starsiege Hercs checked")
	_expect(_checked.get("starsiege tank", 0) >= 15, "Starsiege tanks checked")
	_expect(_checked.get("bd herc", 0) > 0, "Battledrome Hercs checked")
	print("torso_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
		_failures += 1


static func _is_ground_vehicle(v: Dictionary) -> bool:
	return not bool(v.get("flyer", false)) and str(v.get("kind", "herc")) in ["herc", "tank"] \
		and str(v.get("category", "")) == "herc"


func _check_vehicle(v: Dictionary) -> void:
	var rig := _build(v)
	var kind := "%s %s" % [v.pack, v.get("kind", "herc")]
	_checked[kind] = _checked.get(kind, 0) + 1
	if str(v.pack) == "starsiege":
		_expect(rig.torso.torso_node >= 0, "%s turns its head node" % v.id)
		for m in rig.muzzles:
			_expect(rig.torso.torso_node >= 0 and m.get_parent() == rig.shape.nodes[rig.torso.torso_node],
				"%s hardpoint hangs off the head node" % v.id)
	if rig.torso.torso_node >= 0:
		_check_twist(v, rig, 0.0)
		if rig.animator.has_gait():
			_check_twist(v, rig, float(v.max_speed) * 0.5)
	if str(v.get("kind", "")) == "tank":
		_check_tank(v, rig)
	rig.shape.free()


## Model, mounts, legs and torso exactly as Herc._build_model builds them.
func _build(v: Dictionary) -> Dictionary:
	var inst := ShapeInstance.new()
	add_child(inst)
	inst.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
	var muzzles := HercModel.build_mounts(v, inst)
	var animator := HercAnimator.new(v, inst, float(v.max_speed))
	animator.transition_seconds = 0.0   # every _pose is one sequence pose, not a cross-fade
	return {"shape": inst, "muzzles": muzzles.values(), "animator": animator,
		"torso": TorsoRig.new(v, inst, muzzles.values())}


## Pose for one frame at `speed` (m/s) with the torso at yaw / pitch, from the same gait phase every call.
func _pose(rig: Dictionary, speed: float, yaw: float, pitch: float) -> void:
	var animator: HercAnimator = rig.animator
	animator.gait_phase = 0.25
	if speed > 0.0:
		animator.update(speed, 0.0, FRAME)
	else:
		animator.apply_stand()
	rig.torso.apply(yaw, pitch, animator.animates)


func _check_twist(v: Dictionary, rig: Dictionary, speed: float) -> void:
	var s: ShapeInstance = rig.shape
	var torso: TorsoRig = rig.torso
	var upper := _upper_body(s, torso)
	_pose(rig, speed, 0.0, 0.0)
	var rest := _world(s, rig.muzzles)
	var pivot: Transform3D = s.nodes[torso.torso_node].global_transform
	var axis := s.nodes[torso.torso_node].get_parent_node_3d().global_basis.y.normalized()
	_pose(rig, speed, TWIST, 0.0)
	var turned := _world(s, rig.muzzles)
	var where := "%s (%s)" % [v.id, "walking" if speed > 0.0 else "standing"]
	for n in rest:
		var p: Vector3 = rest[n]
		if _turns(n, upper):
			var want := pivot.origin + (p - pivot.origin).rotated(axis, TWIST)
			_expect(turned[n].distance_to(want) < TWIST_TOLERANCE, "%s %s turns with the torso" % [where, n.name])
			var arm := (p - pivot.origin).slide(axis).length()
			if n is Marker3D and arm > MIN_ARM:
				_expect(turned[n].distance_to(p) > arm * TWIST * 0.5, "%s muzzle %s moves with the twist" % [where, n.name])
		else:
			_expect(turned[n].distance_to(p) < LEG_TOLERANCE, "%s leg node %s stays put under the twist" % [where, n.name])
	_pose(rig, speed, TWIST, PITCH)
	var pitched := _world(s, rig.muzzles)
	for n in rest:
		if not _turns(n, upper):
			_expect(pitched[n].distance_to(rest[n]) < LEG_TOLERANCE, "%s leg node %s stays put under pitch" % [where, n.name])


func _check_tank(v: Dictionary, rig: Dictionary) -> void:
	var s: ShapeInstance = rig.shape
	var torso: TorsoRig = rig.torso
	_expect(int(v.get("cockpit_node", 0)) == -1, "%s: the view rides the chase camera / turret" % v.id)
	_expect(torso.pitch_node == TorsoRig.NO_NODE, "%s: the turret does not pitch" % v.id)
	_pose(rig, 0.0, 0.0, 0.0)
	var rest_fwd: Vector3 = -s.nodes[torso.torso_node].global_basis.z
	_pose(rig, 0.0, TWIST, PITCH)
	var fwd: Vector3 = -s.nodes[torso.torso_node].global_basis.z
	_expect(absf(rest_fwd.signed_angle_to(fwd, Vector3.UP) - TWIST) < ANGLE_TOLERANCE, "%s turret yaws by the aim" % v.id)
	for m in rig.muzzles:
		var barrel: Vector3 = -(m as Node3D).global_basis.z.normalized()
		var elevation := asin(clampf(barrel.y, -1.0, 1.0))
		_expect(absf(elevation - PITCH) < ANGLE_TOLERANCE, "%s barrel pitches (%.3f rad, %s)" % [v.id, elevation, barrel])


## A node or muzzle on the turned upper body (Battledrome mine pods sit on the hips and stay put).
static func _turns(n: Node3D, upper: Dictionary) -> bool:
	return upper.has(n.get_parent() if n is Marker3D else n)


## Nodes turned by the twist: the torso node's subtree without the counter-rotated lower body.
func _upper_body(s: ShapeInstance, torso: TorsoRig) -> Dictionary:
	var out := {}
	var todo: Array[Node3D] = [s.nodes[torso.torso_node]]
	while not todo.is_empty():
		var n: Node3D = todo.pop_back()
		if torso.lower_body_nodes.has(s.nodes.find(n)):
			continue
		out[n] = true
		for c in n.get_children():
			if c is Node3D and s.nodes.has(c):
				todo.append(c)
	return out


## World positions of every shape node and of the muzzle markers.
func _world(s: ShapeInstance, muzzles: Array) -> Dictionary:
	var out := {}
	for n in s.nodes:
		out[n] = n.global_position
	for m in muzzles:
		out[m] = (m as Node3D).global_position
	return out

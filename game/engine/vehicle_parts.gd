class_name VehicleParts
extends RefCounted
## The moving parts of a vehicle's model, driven by what the vehicle does (movement read from its replicated position and heading, so the
## host, a client and an AI vehicle all show the same). A catalog record's "parts" block says which nodes and sequences take part
## (docs/formats/tribes_vengeance.md "Drivable vehicles"; tools/tv_vehicle_parts.py):
##   wheels   {radius_m, list: [{node, steer}]}  spin by the distance driven; the steering ones turn with the heading change;
##   gear     {down, up, start_alt_m, full_alt_m} landing gear retracts as the flyer climbs from full_alt_m to start_alt_m;
##   wings    {open, closed, left, right}        the wings close while the gear is down and bank with the turn;
##   treads   {left, right: {forward, backward}, stride_m, left_node, right_node}  each track's cycle runs by its own speed;
##   idle     a looping sequence played all the time; thrust {forward, back, thrust, dive, strafe_left, strafe_right}  engine poses;
##   turret   {node}  the mesh part that carries the gun's housing: it yaws with the gun's aim about the turret node's axis;
##   suspension  {compress_m, droop_m, wheels: [{wheel, shock}]}  each wheel rises and falls with the ground under it (a ray down from
##            the hub), its shock strut stretching or shortening with it.
## Every sequence is a pose relative to the shape's rest pose (Vengeance's single-frame GearDown / WingsOpen are the rest pose itself),
## so layers are blended by weight and stacked on the rest pose node by node.

## Rate (per second) the steered wheels follow the steering demand.
const STEER_FOLLOW := 8.0
## The heading change that turns the wheels fully (rad/s) and the wings fully into a bank.
const FULL_STEER_YAW_RATE := 1.5
const FULL_BANK_YAW_RATE := 1.0
const NO_NODE := -1
## Rate (per second) a wheel follows the ground under it.
const SUSPENSION_FOLLOW := 14.0
## A wheel's ray starts this far above the hub (m, more than the compression) so a bump over the hub is still found.
const SUSPENSION_PROBE_LEAD_M := 0.3

var herc: Herc
var shape: ShapeInstance
var parts: Dictionary
## node index -> rest Transform3D (local)
var _rest := {}
var _wheels: Array = []
## The steered wheels' angle (rad, + = left), the wheels' turn about their axle (rad, 0..TAU) and the distance they rolled (m, signed).
var steer := 0.0
var spin := 0.0
var rolled_m := 0.0
var _gear_up := 0.0
var _idle_seq := -1
var _idle_t := 0.0
## Cycle position (0..1) of each track.
var tread_phase := {"left": 0.0, "right": 0.0}
var _seq := {}                         # sequence name -> index
var _last_position := Vector3.ZERO
var _last_yaw := 0.0
var _have_last := false
var _left_track := NO_NODE
var _right_track := NO_NODE
var _half_track := 0.0
## The mesh node that yaws with the gun (-1 = none).
var turret_node := NO_NODE
## The wheels that have a suspension: [{wheel, shock (node indexes), up, hub, lift}].
var suspension_wheels: Array = []
## Suspension: wheel node index -> the metres it is pushed up (+) or hangs down (-) from its rest height, as posed last frame.
var wheel_lift := {}
## Weight of each layer applied last frame: sequence name -> weight (for the checks).
var layers := {}


## The parts of `p_herc`'s model, or null when its catalog record has none.
static func make(p_herc: Herc) -> VehicleParts:
	var spec = p_herc.def.get("parts")
	if not (spec is Dictionary) or (spec as Dictionary).is_empty() or p_herc.shape == null:
		return null
	var p := VehicleParts.new()
	p.herc = p_herc
	p.shape = p_herc.shape
	p.parts = spec
	p._read_rest()
	p._read_sequences()
	p._read_wheels()
	p._read_treads()
	p._read_turret()
	p._read_suspension()
	return p


func _read_rest() -> void:
	for i in shape.nodes.size():
		_rest[i] = shape.nodes[i].transform


func _read_sequences() -> void:
	var list: Array = shape.shape.get("ds_sequences", [])
	for i in list.size():
		_seq[str(list[i].name).to_lower()] = i
	if parts.has("idle"):
		_idle_seq = int(_seq.get(str(parts.idle), -1))


func _index_of_node(node_name: String) -> int:
	var list: Array = shape.shape.get("nodes", [])
	for i in list.size():
		if str(list[i].get("name", "")).to_lower() == node_name.to_lower():
			return i
	return NO_NODE


## The transform of node `i` relative to the shape root in its rest pose.
func _make_root_transform(i: int) -> Transform3D:
	var list: Array = shape.shape.nodes
	var t := Transform3D.IDENTITY
	var n := i
	while n >= 0 and n < list.size():
		t = (_rest[n] as Transform3D) * t
		n = int(list[n].parent)
	return t


func _read_wheels() -> void:
	var spec: Dictionary = parts.get("wheels", {})
	for w in spec.get("list", []):
		var i := _index_of_node(str(w.node))
		if i == NO_NODE:
			continue
		var parent: int = int(shape.shape.nodes[i].parent)
		var parent_root := _make_root_transform(parent) if parent >= 0 else Transform3D.IDENTITY
		_wheels.append({"node": i, "steer": bool(w.get("steer", false)),
			"axle": _make_root_transform(i).basis.inverse() * Vector3.RIGHT,        # the lateral axis, in the wheel's own frame
			"up": parent_root.basis.inverse() * Vector3.UP})                          # the vertical axis, in its parent's frame


func _read_treads() -> void:
	var spec: Dictionary = parts.get("treads", {})
	if spec.is_empty():
		return
	_left_track = _index_of_node(str(spec.get("left_node", "")))
	_right_track = _index_of_node(str(spec.get("right_node", "")))
	if _left_track != NO_NODE and _right_track != NO_NODE:
		_half_track = absf(_make_root_transform(_left_track).origin.x - _make_root_transform(_right_track).origin.x) * 0.5


func _read_turret() -> void:
	var spec: Dictionary = parts.get("turret", {})
	turret_node = _index_of_node(str(spec.get("node", "")))


## The shock of each wheel is a strut whose far end sits at the chassis: its node frame's y axis runs along it.
func _read_suspension() -> void:
	var spec: Dictionary = parts.get("suspension", {})
	for w in spec.get("wheels", []):
		var wheel := _index_of_node(str(w.wheel))
		var shock := _index_of_node(str(w.shock))
		if wheel == NO_NODE or shock == NO_NODE:
			continue
		var parent: int = int(shape.shape.nodes[wheel].parent)
		var parent_root := _make_root_transform(parent) if parent >= 0 else Transform3D.IDENTITY
		suspension_wheels.append({"wheel": wheel, "shock": shock, "up": parent_root.basis.inverse() * Vector3.UP,
			"hub": _make_root_transform(wheel).origin, "lift": 0.0})


## One frame: pose the parts for what the vehicle did in `delta` seconds.
func update(delta: float) -> void:
	if delta <= 0.0 or not herc.alive:
		return
	var move := _measure_motion(delta)
	var pose := {}
	for i in _rest:
		pose[i] = _rest[i]
	layers.clear()
	_apply_wheels(move, delta)
	_stack_layers(pose, _make_layers(move, delta))
	_pose_wheels(pose)
	_pose_turret(pose)
	_pose_suspension(pose, delta)
	for i in pose:
		if i != herc.torso.torso_node and i != herc.torso.pitch_node:       # the torso rig poses its own nodes
			shape.nodes[i].transform = pose[i]


## Forward speed (m/s, signed), sideways speed (m/s, + right), climb rate (m/s) and heading change rate (rad/s, + left).
func _measure_motion(delta: float) -> Dictionary:
	var at := herc.global_position
	var yaw := herc.rotation.y
	var out := {"forward": 0.0, "side": 0.0, "climb": 0.0, "yaw_rate": 0.0}
	if _have_last:
		var step := (at - _last_position) / delta
		var basis := Basis(Vector3.UP, yaw)
		out.forward = step.dot(-basis.z)
		out.side = step.dot(basis.x)
		out.climb = step.y
		out.yaw_rate = wrapf(yaw - _last_yaw, -PI, PI) / delta
	_last_position = at
	_last_yaw = yaw
	_have_last = true
	return out


func _apply_wheels(move: Dictionary, delta: float) -> void:
	if _wheels.is_empty():
		return
	var radius := maxf(float(parts.wheels.get("radius_m", 0.0)), 0.1)
	rolled_m += float(move.forward) * delta
	spin = fposmod(spin - float(move.forward) * delta / radius, TAU)
	var demand := clampf(float(move.yaw_rate) / FULL_STEER_YAW_RATE, -1.0, 1.0) * float(parts.get("steer_max_rad", 0.0))
	steer = lerpf(steer, demand, clampf(STEER_FOLLOW * delta, 0.0, 1.0))


func _make_layers(move: Dictionary, delta: float) -> Array:
	var out := []
	_add_gear_layers(out)
	_add_wing_layers(out, move)
	_add_tread_layers(out, move, delta)
	_add_thrust_layers(out, move)
	if _idle_seq >= 0:
		_idle_t += delta
		var cycle := ShapeCycles.cycle_seconds(shape, _idle_seq, 0.0)
		out.append({"seq": _idle_seq, "weight": 1.0, "phase": fposmod(_idle_t / maxf(cycle, 0.01), 1.0)})
		layers[str(parts.idle)] = 1.0
	return out


func _add_gear_layers(out: Array) -> void:
	if not parts.has("gear") or not (herc is Flyer):
		return
	var g: Dictionary = parts.gear
	var start := float(g.get("start_alt_m", 0.0))
	var full := float(g.get("full_alt_m", 0.0))
	var altitude := (herc as Flyer).make_altitude()
	_gear_up = clampf((altitude - full) / maxf(start - full, 0.01), 0.0, 1.0)
	_add_layer(out, str(g.up), _gear_up)


func _add_wing_layers(out: Array, move: Dictionary) -> void:
	if not parts.has("wings"):
		return
	var w: Dictionary = parts.wings
	_add_layer(out, str(w.closed), 1.0 - _gear_up)
	var bank := clampf(float(move.yaw_rate) / FULL_BANK_YAW_RATE, -1.0, 1.0)
	_add_layer(out, str(w.left), maxf(bank, 0.0) * _gear_up)
	_add_layer(out, str(w.right), maxf(-bank, 0.0) * _gear_up)


func _add_tread_layers(out: Array, move: Dictionary, delta: float) -> void:
	if not parts.has("treads"):
		return
	var spec: Dictionary = parts.treads
	var stride := maxf(float(spec.get("stride_m", 1.0)), 0.05)
	var yaw_speed := float(move.yaw_rate) * _half_track
	var speeds := {"left": float(move.forward) - yaw_speed, "right": float(move.forward) + yaw_speed}
	for side in ["left", "right"]:
		var speed: float = speeds[side]
		var names: Dictionary = spec[side]
		tread_phase[side] = fposmod(float(tread_phase[side]) + absf(speed) * delta / stride, 1.0)
		var seq := str(names.forward if speed >= 0.0 else names.backward)
		if _seq.has(seq):
			out.append({"seq": int(_seq[seq]), "weight": 1.0, "phase": tread_phase[side]})
			layers[seq] = 1.0


func _add_thrust_layers(out: Array, move: Dictionary) -> void:
	if not parts.has("thrust"):
		return
	var t: Dictionary = parts.thrust
	var top := maxf(herc.max_speed, 1.0)
	var forward := clampf(float(move.forward) / top, -1.0, 1.0)
	_add_layer(out, str(t.forward), maxf(forward, 0.0))
	_add_layer(out, str(t.back), maxf(-forward, 0.0))
	var climb := clampf(float(move.climb) / maxf(top * 0.2, 1.0), -1.0, 1.0)
	_add_layer(out, str(t.thrust), maxf(climb, 0.0))
	_add_layer(out, str(t.dive), maxf(-climb, 0.0))
	var side := clampf(float(move.side) / maxf(top * 0.2, 1.0), -1.0, 1.0)
	_add_layer(out, str(t.strafe_left), maxf(-side, 0.0))
	_add_layer(out, str(t.strafe_right), maxf(side, 0.0))


func _add_layer(out: Array, seq_name: String, weight: float) -> void:
	var i := int(_seq.get(seq_name, -1))
	layers[seq_name] = weight
	if i >= 0 and weight > 0.001:
		out.append({"seq": i, "weight": weight, "phase": 0.0})


## Stacks the layers on the rest pose: a layer moves a node from its rest transform part of the way to the sequence's, by its weight.
func _stack_layers(pose: Dictionary, stack: Array) -> void:
	for layer in stack:
		var keys := ShapeCycles.make_node_transforms(shape, int(layer.seq), float(layer.phase))
		for ni in keys:
			var rest: Transform3D = _rest[ni]
			var delta_tf := rest.affine_inverse() * (keys[ni] as Transform3D)
			pose[ni] = (pose[ni] as Transform3D) * Transform3D.IDENTITY.interpolate_with(delta_tf, clampf(float(layer.weight), 0.0, 1.0))


## The wheels turn about their axle by the distance driven, the steering ones about the vertical by the steering angle.
func _pose_wheels(pose: Dictionary) -> void:
	for w in _wheels:
		var ni: int = w.node
		var spun: Transform3D = pose[ni]
		spun.basis = spun.basis * Basis(w.axle, spin)
		if bool(w.steer):
			spun.basis = Basis(w.up, steer) * spun.basis
		pose[ni] = spun


## The turret mesh turns about the vertical through the turret node (where the gun hangs) by the gun's yaw.
func _pose_turret(pose: Dictionary) -> void:
	if turret_node == NO_NODE or herc.torso.torso_node == NO_NODE:
		return
	var axis_at := _make_root_transform(herc.torso.torso_node).origin
	var turn := Transform3D(Basis(Vector3.UP, herc.torso_yaw), axis_at - Basis(Vector3.UP, herc.torso_yaw) * axis_at)
	var parent: int = int(shape.shape.nodes[turret_node].parent)
	var parent_root := _make_root_transform(parent) if parent >= 0 else Transform3D.IDENTITY
	pose[turret_node] = parent_root.affine_inverse() * turn * parent_root * (pose[turret_node] as Transform3D)


## Each wheel rises with the ground under it and hangs down where there is none (the hull itself is one rigid body): the lift is
## the wheel's height of ground above its rest contact, less the average of the wheels that touch (the body rides at the mean).
func _pose_suspension(pose: Dictionary, delta: float) -> void:
	if suspension_wheels.is_empty() or ServerProfile.is_collision_only():
		return
	var targets := _measure_wheel_lifts()
	for i in suspension_wheels.size():
		var w: Dictionary = suspension_wheels[i]
		w.lift = lerpf(float(w.lift), float(targets[i]), clampf(SUSPENSION_FOLLOW * delta, 0.0, 1.0))
		wheel_lift[int(w.wheel)] = w.lift
		var wheel_pose: Transform3D = pose[int(w.wheel)]
		wheel_pose.origin += (w.up as Vector3) * float(w.lift) / shape.scale.x          # node transforms are in the shape's own units
		pose[int(w.wheel)] = wheel_pose
		_pose_shock(pose, w)


## The lift each wheel is pulled to: ground contact by a ray from above the hub down to a wheel radius plus the droop below it.
func _measure_wheel_lifts() -> Array:
	var spec: Dictionary = parts.suspension
	var radius := float(parts.wheels.get("radius_m", 0.0))
	var compress := float(spec.compress_m)
	var droop := float(spec.droop_m)
	var up := herc.global_basis.y
	var raw := []
	var touching := 0.0
	var sum := 0.0
	for w in suspension_wheels:
		var hub: Vector3 = shape.global_transform * (w.hub as Vector3)
		var reach := _measure_ground_distance(hub + up * SUSPENSION_PROBE_LEAD_M, up, SUSPENSION_PROBE_LEAD_M + radius + droop)
		var lift := NAN if reach < 0.0 else clampf(radius - (reach - SUSPENSION_PROBE_LEAD_M), -droop, compress)
		raw.append(lift)
		if not is_nan(lift):
			touching += 1.0
			sum += lift
	var ride := sum / touching if touching > 0.0 else 0.0
	return raw.map(func(l: float) -> float: return -droop if is_nan(l) else clampf(l - ride, -droop, compress))


## Metres from `from` straight down (against `up`) to the ground, -1 when there is none within `reach`; vehicles and soldiers are not ground.
func _measure_ground_distance(from: Vector3, up: Vector3, reach: float) -> float:
	if not herc.is_inside_tree():
		return -1.0
	var q := PhysicsRayQueryParameters3D.create(from, from - up * reach)
	q.exclude = [herc.get_rid()]
	var space := herc.get_world_3d().direct_space_state
	for _i in 4:
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return -1.0
		if not (hit.collider is CharacterBody3D):
			return from.distance_to(hit.position)
		q.exclude.append((hit.collider as CollisionObject3D).get_rid())
	return -1.0


## The shock strut follows its wheel: its far end stays at the chassis, so the strut is stretched along its own axis by the lift.
func _pose_shock(pose: Dictionary, w: Dictionary) -> void:
	var shock: Transform3D = pose[int(w.shock)]
	var length := maxf(float(parts.suspension.get("shock_length_m", 1.0)), 0.1)
	shock.basis = shock.basis * Basis.from_scale(Vector3(1.0, maxf(1.0 + float(w.lift) / length, 0.1), 1.0))
	pose[int(w.shock)] = shock

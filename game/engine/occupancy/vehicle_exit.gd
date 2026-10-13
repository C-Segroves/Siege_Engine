class_name VehicleExit
extends RefCounted
## Where a soldier gets out of a vehicle (tribes_vehicles.md section 6): on the ground beside the hull, at the
## first free spot round it (right side first), else on the roof; out of a flying jet into the air.

## Exit positions are tried round the hull, this far out from it (metres), at these angles from the right side.
const EXIT_GAP := 1.5
const EXIT_ANGLES_DEG := [0.0, 180.0, 90.0, -90.0, 45.0, 135.0, -45.0, -135.0]
## Free room a soldier needs where he gets out (capsule: radius, height).
const EXIT_CLEAR_RADIUS := 0.7
const EXIT_CLEAR_HEIGHT := 2.4
const EXIT_PROBE_HEIGHT := 50.0
const EXIT_PROBE_START := 0.1
## Rider ejected from a vehicle that has no free room round it: above its roof.
const EJECT_ABOVE := 2.0


## The transform a soldier leaving `vehicle` gets.
static func make_transform(battle: Battle, vehicle: Herc) -> Transform3D:
	var yaw := vehicle.global_rotation.y
	var reach := BoardingRules.make_hull_radius(vehicle) + EXIT_GAP
	for deg in EXIT_ANGLES_DEG:
		var dir := Basis(Vector3.UP, yaw + deg_to_rad(deg)) * Vector3.RIGHT
		var p := _make_ground_point(battle, vehicle, vehicle.global_position + dir * reach)
		if _is_free(vehicle, p):
			return Transform3D(Basis(Vector3.UP, yaw), p)
	var roof := vehicle.global_position + Vector3.UP * (BoardingRules.make_hull_height(vehicle) + EJECT_ABOVE)
	return Transform3D(Basis(Vector3.UP, yaw), roof)


## The floor under `p` (terrain, a building, a deck), from up to EXIT_PROBE_HEIGHT above the vehicle.
static func _make_ground_point(battle: Battle, vehicle: Herc, p: Vector3) -> Vector3:
	var top := Vector3(p.x, vehicle.global_position.y + EXIT_PROBE_HEIGHT * EXIT_PROBE_START + BoardingRules.make_hull_height(vehicle), p.z)
	var q := PhysicsRayQueryParameters3D.create(top, top + Vector3.DOWN * EXIT_PROBE_HEIGHT)
	q.exclude = _make_body_rids(battle)
	var hit := vehicle.get_world_3d().direct_space_state.intersect_ray(q)
	var ground := MapBuilder.ground_height(battle, p)
	var y: float = maxf(float(hit.position.y) if hit else ground, ground)
	if vehicle is Flyer and vehicle.global_position.y - y > BoardingRules.HATCH_MIN_HEIGHT:
		return Vector3(p.x, vehicle.global_position.y, p.z)   # in flight: out into the air (jetpack)
	return Vector3(p.x, y + BattleInfantry.GROUND_CLEARANCE, p.z)


static func _is_free(vehicle: Herc, p: Vector3) -> bool:
	var cap := CapsuleShape3D.new()
	cap.radius = EXIT_CLEAR_RADIUS
	cap.height = EXIT_CLEAR_HEIGHT
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = Transform3D(Basis(), p + Vector3.UP * (EXIT_CLEAR_HEIGHT * 0.5 + 0.05))
	q.exclude = [vehicle.get_rid()]
	return vehicle.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


## Vehicles and soldiers (ignored by the floor probe: a soldier gets out beside them, not on them).
static func _make_body_rids(battle: Battle) -> Array[RID]:
	var out: Array[RID] = []
	for h in battle.vehicles.values():
		if is_instance_valid(h):
			out.append((h as Herc).get_rid())
	return out

class_name CallinAim
extends RefCounted
## Where a line of sight first meets the world: the Targeting Laser's spot. Physics geometry (buildings, rocks, props) and the
## terrain height field both count (a map's terrain may have no collider); units are looked through, so the spot is the ground
## behind a soldier. Result: {hit, point, normal, distance}; with no hit `point` is the end of the line and `normal` is up.

## Metres between the samples of the terrain march.
const MARCH_STEP_M := 4.0
const REFINE_STEPS := 8
## A point this far below the terrain surface is under it (the height field answers p.y where it has no terrain).
const UNDER_M := 0.05


static func make_point(battle: Battle, origin: Vector3, direction: Vector3, reach: float) -> Dictionary:
	var dir := direction.normalized()
	var best := {"hit": false, "point": origin + dir * reach, "normal": Vector3.UP, "distance": reach}
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * reach)
	q.exclude = ExitSafety.make_unit_rids(battle)
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		var at: Vector3 = hit.position
		best = {"hit": true, "point": at, "normal": hit.normal, "distance": origin.distance_to(at)}
	var ground := _make_terrain_hit(battle, origin, dir, float(best.distance))
	return ground if not ground.is_empty() else best


## The first crossing of the terrain surface within `reach` metres ({} when the line stays above it).
static func _make_terrain_hit(battle: Battle, origin: Vector3, dir: Vector3, reach: float) -> Dictionary:
	var prev := 0.0
	var d := MARCH_STEP_M
	while prev < reach:
		d = minf(d, reach)
		if _is_under(battle, origin + dir * d):
			return _refine(battle, origin, dir, prev, d)
		prev = d
		d += MARCH_STEP_M
	return {}


static func _refine(battle: Battle, origin: Vector3, dir: Vector3, above: float, under: float) -> Dictionary:
	for i in REFINE_STEPS:
		var mid := (above + under) * 0.5
		if _is_under(battle, origin + dir * mid):
			under = mid
		else:
			above = mid
	var at := origin + dir * under
	return {"hit": true, "point": at, "normal": Vector3.UP, "distance": under}


static func _is_under(battle: Battle, p: Vector3) -> bool:
	return MapBuilder.ground_height(battle, p) - p.y > UNDER_M

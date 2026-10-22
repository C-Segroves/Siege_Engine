class_name LootDropPlacement
extends RefCounted
## Where a drop lies (death bags, thrown items, wrecks, flags, caches): always on a surface a soldier can stand on,
## within pickup reach of where it fell, never inside or under static geometry (a vehicle pad's deck, a building's
## wall, a floor with a slab over it).
##   1  the floor below the body's head (a body inside a slab lands on its top, a body in the open on the ground);
##   2  else the same all round the body, out to MAX_SHIFT_M (pushed out of a wall or a block);
##   3  else (a body in the air) the first standable surface straight below, however far;
##   4  else the terrain under it.
## A floor is standable when it faces up, has STAND_HEADROOM_M of air above it and nothing solid within the ring of
## a bag. Units (soldiers, vehicles) are no floor. The world is queried through `space`, so the checks run on any
## physics space (tests/loot_drop_check.gd).

## The probe for a floor starts this far above the body's feet (a soldier's head).
const HEAD_LIFT_M := 1.7
## A floor needs this much air above it for a soldier to stand there (a bag lying under a slab is out of reach).
const STAND_HEADROOM_M := 1.4
## A drop may be pushed this far sideways out of geometry; it stays under the pickup reach.
const MAX_SHIFT_M := 2.0
const SHIFT_RINGS: Array[float] = [0.7, 1.4, MAX_SHIFT_M]
const SHIFT_DIRECTIONS := 8
## A surface this flat can be stood on (normal.y).
const WALKABLE_NORMAL_Y := 0.6
const FLOOR_STEP_M := 0.02
const MAX_SURFACES := 16
const CLEAR_RADIUS_M := 0.3
const CLEAR_LIFT_M := 0.45
## The reach is kept this far inside the pickup reach, so a soldier standing where the drop fell can take it.
const REACH_MARGIN_M := 0.5
const BELOW_GROUND_M := 1.0
const ALL_LAYERS := 0xFFFFFFFF


## The drop point for something falling from `p` (a body's feet). `reach` is the pickup reach (m), `ground_y` the
## terrain height under `p`, `exclude` the units' bodies.
static func make_point(space: PhysicsDirectSpaceState3D, exclude: Array[RID], p: Vector3, ground_y: float, reach: float) -> Vector3:
	var band := maxf(reach - REACH_MARGIN_M, 0.5)
	var spot := find_near(space, exclude, p, band, ground_y)
	if is_finite(spot.y):
		return spot
	spot = find_floor(space, exclude, p, p.y + HEAD_LIFT_M, ground_y - BELOW_GROUND_M)
	return spot if is_finite(spot.y) else Vector3(p.x, ground_y, p.z)


## A standable floor within `band` metres above and below `p`, under the body or pushed sideways to MAX_SHIFT_M;
## INF in y when there is none.
static func find_near(space: PhysicsDirectSpaceState3D, exclude: Array[RID], p: Vector3, band: float, ground_y: float) -> Vector3:
	var lowest := maxf(p.y - band, ground_y - BELOW_GROUND_M)
	var top := p.y + HEAD_LIFT_M
	var spot := find_floor(space, exclude, p, top, lowest)
	if is_finite(spot.y):
		return spot
	for ring in SHIFT_RINGS:
		var best := Vector3(p.x, INF, p.z)
		for k in SHIFT_DIRECTIONS:
			var a := TAU * float(k) / SHIFT_DIRECTIONS
			var q := p + Vector3(cos(a), 0.0, sin(a)) * ring
			var found := find_floor(space, exclude, q, top, lowest)
			if is_finite(found.y) and (not is_finite(best.y) or absf(found.y - p.y) < absf(best.y - p.y)):
				best = found
		if is_finite(best.y):
			return best
	return Vector3(p.x, INF, p.z)


## A cache's place (a map point): the topmost surface over `p` (a roof, a deck, else the terrain; under open sky, so
## nothing covers it), pushed sideways to MAX_SHIFT_M when that surface cannot be stood on (a rock's slope); the
## topmost surface itself when none can, the terrain when nothing is hit.
static func make_top_point(space: PhysicsDirectSpaceState3D, exclude: Array[RID], p: Vector3, top_y: float, ground_y: float) -> Vector3:
	var rings: Array[float] = [0.0]
	rings.append_array(SHIFT_RINGS)
	for ring in rings:
		for k in (1 if ring == 0.0 else SHIFT_DIRECTIONS):
			var a := TAU * float(k) / SHIFT_DIRECTIONS
			var q := p + Vector3(cos(a), 0.0, sin(a)) * ring
			var hit := _first_hit(space, exclude, Vector3(q.x, top_y, q.z), ground_y - BELOW_GROUND_M)
			if not hit.is_empty() and float(hit.normal.y) >= WALKABLE_NORMAL_Y and is_standable(space, exclude, hit.position):
				return hit.position
	var top := _first_hit(space, exclude, Vector3(p.x, top_y, p.z), ground_y - BELOW_GROUND_M)
	return Vector3(p.x, maxf(float(top.position.y), ground_y) if not top.is_empty() else ground_y, p.z)


static func _first_hit(space: PhysicsDirectSpaceState3D, exclude: Array[RID], from: Vector3, lowest_y: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, Vector3(from.x, lowest_y, from.z), ALL_LAYERS)
	q.exclude = exclude
	return space.intersect_ray(q)


## The first standable floor straight below (`at`.x, `top_y`, `at`.z), not lower than `lowest_y`; INF in y when none.
static func find_floor(space: PhysicsDirectSpaceState3D, exclude: Array[RID], at: Vector3, top_y: float, lowest_y: float) -> Vector3:
	var from_y := top_y
	for i in MAX_SURFACES:
		if from_y <= lowest_y:
			break
		var q := PhysicsRayQueryParameters3D.create(Vector3(at.x, from_y, at.z), Vector3(at.x, lowest_y, at.z), ALL_LAYERS)
		q.exclude = exclude
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		from_y = float(hit.position.y) - FLOOR_STEP_M
		if float(hit.normal.y) >= WALKABLE_NORMAL_Y and is_standable(space, exclude, hit.position):
			return hit.position
	return Vector3(at.x, INF, at.z)


## True when a soldier can stand on the floor point `spot`: air above it and no solid within a bag's ring.
static func is_standable(space: PhysicsDirectSpaceState3D, exclude: Array[RID], spot: Vector3) -> bool:
	var up := PhysicsRayQueryParameters3D.create(spot + Vector3.UP * FLOOR_STEP_M, spot + Vector3.UP * STAND_HEADROOM_M, ALL_LAYERS)
	up.exclude = exclude
	if not space.intersect_ray(up).is_empty():
		return false
	var ball := SphereShape3D.new()
	ball.radius = CLEAR_RADIUS_M
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = ball
	q.transform = Transform3D(Basis(), spot + Vector3.UP * CLEAR_LIFT_M)
	q.exclude = exclude
	return space.intersect_shape(q, 1).is_empty()

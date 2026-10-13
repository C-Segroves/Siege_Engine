class_name SpawnClearance
extends RefCounted
## Keeps map spawn points out of buildings and props. A spawn that lies inside or just under a solid
## (a Tribes 2 vehicle pad's deck sits a few metres above the pad station's origin) is raised onto
## the top of it, so a vehicle never starts trapped in collision geometry.
##
## Works on the built static bodies' trimesh faces (not physics queries: bodies added this frame are
## not in the physics space yet when the map's spawns are computed).

## Free height a vehicle needs above its spawn point (Tribes 2 creates vehicles 4 m above the pad,
## serverCmdBuyVehicle in scripts/vehicles/serverVehicleHud.cs).
const VEHICLE_HEADROOM := 4.0
## Surfaces this close above the spawn point are the floor it stands on, not an obstruction.
const FLOOR_TOLERANCE := 0.25
## Probe columns round the spawn point (a vehicle's footprint radius), metres.
const FOOTPRINT_RADIUS := 2.5
const FOOTPRINT_OFFSETS: Array[Vector3] = [Vector3.ZERO, Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
## Lift attempts before giving up on a stack of surfaces (logs an error).
const MAX_LIFTS := 6
## Gap kept between a raised spawn and the surface it stands on.
const STANDING_GAP := 0.5
## A face whose normal has at least this upward component can be stood on.
const WALKABLE_NORMAL_Y := 0.5

## A point with any surface less than this far above its footprint is under cover (inside a base,
## under a bridge): no place for a Herc to start.
const OPEN_SKY_HEIGHT := 40.0
## Footprint radius of the open-sky test: a Herc's widest collision capsule (Herc.CAPSULE_MAX_RADIUS).
const OPEN_FOOTPRINT_RADIUS := 4.0
## Search for open ground round a covered point: rings this far apart, out to OPEN_SEARCH_RADIUS.
const OPEN_SEARCH_STEP := 10.0
const OPEN_SEARCH_RADIUS := 80.0
const OPEN_SEARCH_DIRECTIONS := 8
## A vehicle start looks out at least this far before a building (else it is turned to the most open way,
## FACING_DIRECTIONS tried, ties toward the map centre); probes at these heights above its origin.
const FACING_CLEAR_M := 40.0
const FACING_DIRECTIONS := 16
const FACING_PROBE_HEIGHTS: Array[float] = [2.0, 6.0]
const FACING_CENTRE_WEIGHT := 5.0

## [{"mesh": TriangleMesh, "to_local": Transform3D, "aabb": AABB (world)}]
var _solids: Array[Dictionary] = []
var _parent: Node3D


## A clearance checker for the trimesh static bodies directly under `parent`.
static func make(parent: Node3D) -> SpawnClearance:
	var c := SpawnClearance.new()
	c._parent = parent
	for body in parent.get_children():
		if body is StaticBody3D:
			c._add_body(body)
	return c


func _add_body(body: StaticBody3D) -> void:
	for col in body.get_children():
		if col is CollisionShape3D and col.shape is ConcavePolygonShape3D:
			var faces: PackedVector3Array = (col.shape as ConcavePolygonShape3D).get_faces()
			if faces.size() < 3:
				continue
			var mesh := TriangleMesh.new()
			if not mesh.create_from_faces(faces):
				continue
			var xf: Transform3D = body.global_transform * col.transform
			_solids.append({"mesh": mesh, "to_local": xf.affine_inverse(), "aabb": xf * _faces_aabb(faces)})


static func _faces_aabb(faces: PackedVector3Array) -> AABB:
	var box := AABB(faces[0], Vector3.ZERO)
	for v in faces:
		box = box.expand(v)
	return box


## `origin`, raised onto the top of whatever solid would trap a vehicle standing there.
func make_clear_origin(origin: Vector3) -> Vector3:
	var out := origin
	for i in MAX_LIFTS:
		var hits := _surfaces_in_columns(out, FOOTPRINT_RADIUS, VEHICLE_HEADROOM)
		if hits.is_empty():
			return out
		out.y = _make_landing_height(hits) + STANDING_GAP
	push_error("SpawnClearance: no free space above the spawn at %s" % origin)
	return out


## `xf` turned so the vehicle does not start facing a wall: kept when FACING_CLEAR_M ahead are free of buildings,
## else the direction with the most room (up to FACING_CLEAR_M), preferring the way to `centre`.
func make_open_facing(xf: Transform3D, centre: Vector3) -> Transform3D:
	var forward := -xf.basis.z
	forward.y = 0.0
	if forward.length() < 0.01 or make_clear_distance(xf.origin, forward.normalized()) >= FACING_CLEAR_M:
		return xf
	var to_centre := Vector3(centre.x - xf.origin.x, 0.0, centre.z - xf.origin.z).normalized()
	var best_dir := forward.normalized()
	var best_score := -INF
	for i in FACING_DIRECTIONS:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / FACING_DIRECTIONS)
		var score_now := make_clear_distance(xf.origin, dir) + FACING_CENTRE_WEIGHT * dir.dot(to_centre)
		if score_now > best_score:
			best_score = score_now
			best_dir = dir
	return Transform3D(Basis(Vector3.UP, atan2(-best_dir.x, -best_dir.z)), xf.origin)


## Metres from `origin` along the flat `dir` to the first building face (FACING_CLEAR_M when none that near).
func make_clear_distance(origin: Vector3, dir: Vector3) -> float:
	var best := FACING_CLEAR_M
	for h in FACING_PROBE_HEIGHTS:
		var from := origin + Vector3.UP * h
		var to := from + dir * FACING_CLEAR_M
		for s in _solids:
			if not (s.aabb as AABB).intersects_segment(from, to):
				continue
			var to_local: Transform3D = s.to_local
			var hit: Dictionary = (s.mesh as TriangleMesh).intersect_segment(to_local * from, to_local * to)
			if not hit.is_empty():
				best = minf(best, from.distance_to(to_local.affine_inverse() * Vector3(hit.position)))
	return best


## `origin` when it is under open sky, else the nearest terrain point round it that is (an
## infantry drop point inside a base: the Herc starts on the ground next to the base).
func make_open_ground_origin(origin: Vector3) -> Vector3:
	if not is_under_cover(origin):
		return origin
	var lift := origin.y - MapTerrain.ground_height(_parent, origin)
	for ring in range(1, int(OPEN_SEARCH_RADIUS / OPEN_SEARCH_STEP) + 1):
		for k in OPEN_SEARCH_DIRECTIONS:
			var angle := TAU * k / OPEN_SEARCH_DIRECTIONS
			var p := origin + Vector3(cos(angle), 0.0, sin(angle)) * OPEN_SEARCH_STEP * ring
			p.y = MapTerrain.ground_height(_parent, p) + lift
			if not is_under_cover(p):
				return p
	return origin


## Whether a surface lies above the Herc footprint at `origin` (within OPEN_SKY_HEIGHT).
func is_under_cover(origin: Vector3) -> bool:
	return not _surfaces_in_columns(origin, OPEN_FOOTPRINT_RADIUS, OPEN_SKY_HEIGHT).is_empty()


## The highest walkable surface among `hits` (any surface when none is walkable).
static func _make_landing_height(hits: Array[Dictionary]) -> float:
	var top := -INF
	var any_top := -INF
	for h in hits:
		any_top = maxf(any_top, h.y)
		if h.walkable:
			top = maxf(top, h.y)
	return top if top > -INF else any_top


## Every surface crossing the footprint columns (`radius` round `origin`) from just above the floor
## up to `height`: [{"y": float, "walkable": bool}].
func _surfaces_in_columns(origin: Vector3, radius: float, height: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for offset in FOOTPRINT_OFFSETS:
		var base := origin + offset * radius
		var bottom := base + Vector3.UP * FLOOR_TOLERANCE
		var top := base + Vector3.UP * height
		for s in _solids:
			if (s.aabb as AABB).intersects_segment(bottom, top):
				out.append_array(_column_hits(s, bottom, top))
	return out


## All faces of one solid crossing the vertical segment bottom..top (world space).
static func _column_hits(solid: Dictionary, bottom: Vector3, top: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var to_local: Transform3D = solid.to_local
	var to_world := to_local.affine_inverse()
	var from := to_local * bottom
	var to := to_local * top
	var step := (to - from).normalized() * 0.001
	while true:
		var hit: Dictionary = (solid.mesh as TriangleMesh).intersect_segment(from, to)
		if hit.is_empty():
			break
		var normal: Vector3 = (to_world.basis * Vector3(hit.normal)).normalized()
		out.append({"y": (to_world * Vector3(hit.position)).y, "walkable": absf(normal.y) >= WALKABLE_NORMAL_Y})
		from = Vector3(hit.position) + step
		if from.distance_squared_to(to) < step.length_squared():
			break
	return out

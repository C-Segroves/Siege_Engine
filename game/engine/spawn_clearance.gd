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
## A spawn kept at its file height stands on a floor at most this far below it, else it hangs in the air.
const SUPPORT_REACH := 3.0
## Under the terrain a spawn is inside a base while a building's floor lies at most this far below it.
const BASE_FLOOR_REACH := 10.0
## Gap kept between a raised spawn and the surface it stands on.
const STANDING_GAP := 0.5
## A face whose normal has at least this upward component can be stood on.
const WALKABLE_NORMAL_Y := 0.5

## A point with any surface less than this far above its footprint is under cover (inside a base,
## under a bridge): no place for a Herc to start.
const OPEN_SKY_HEIGHT := 40.0
## Footprint radius of the open-sky test: a Herc's widest collision capsule (Herc.CAPSULE_MAX_RADIUS).
const OPEN_FOOTPRINT_RADIUS := 4.0
## Level ground: the terrain rises by at most this much per metre within OPEN_FOOTPRINT_RADIUS of the point (a Herc slides
## off steeper ground; about 31 degrees).
const OPEN_MAX_RISE := 0.6
## Terrain squares larger than this are coarse (make_terrain_rise).
const COARSE_SQUARE_M := 16.0
## make_floor_rise looks for a floor from this far above the one under the spawn down FLOOR_SCAN_REACH.
const FLOOR_SCAN_ABOVE := 1.0
const FLOOR_SCAN_REACH := 8.0
## is_walled_in: faces nearer than WALL_CLEAR_M (a Herc's widest capsule radius plus a margin) at these heights above the spawn,
## in WALL_PROBE_DIRECTIONS directions. High enough to clear a gentle slope of the floor itself.
const WALL_CLEAR_M := 3.2
const WALL_PROBE_HEIGHTS: Array[float] = [3.0, 6.0]
const WALL_PROBE_DIRECTIONS := 8
## Search for open ground round a covered or steep point: rings this far apart, out to OPEN_SEARCH_RADIUS.
const OPEN_SEARCH_STEP := 10.0
const OPEN_SEARCH_RADIUS := 80.0
const OPEN_SEARCH_DIRECTIONS := 8
## A vehicle start looks out at least this far before a building (else it is turned to the most open way,
## FACING_DIRECTIONS tried, ties toward the map centre); probes at these heights above its origin.
const FACING_CLEAR_M := 40.0
const FACING_DIRECTIONS := 16
const FACING_PROBE_HEIGHTS: Array[float] = [2.0, 6.0]
const FACING_CENTRE_WEIGHT := 5.0

## [{"mesh": TriangleMesh, "to_local": Transform3D, "aabb": AABB (world), "terrain": bool}]
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
		if col is CollisionShape3D and not col.is_queued_for_deletion() and col.shape is ConcavePolygonShape3D:   # (a prop built without collision frees its shapes at the end of the frame)
			var faces: PackedVector3Array = (col.shape as ConcavePolygonShape3D).get_faces()
			if faces.size() < 3:
				continue
			var mesh := TriangleMesh.new()
			if not mesh.create_from_faces(faces):
				continue
			var xf: Transform3D = body.global_transform * col.transform
			_solids.append({"mesh": mesh, "to_local": xf.affine_inverse(), "aabb": xf * _faces_aabb(faces), "terrain": body.is_in_group("terrain")})


static func _faces_aabb(faces: PackedVector3Array) -> AABB:
	var box := AABB(faces[0], Vector3.ZERO)
	for v in faces:
		box = box.expand(v)
	return box


## `origin`, raised onto the top of whatever solid would trap a vehicle standing there. The terrain only counts over the
## spawn point itself: its slope rising beside a vehicle on a hillside traps nothing (lifting onto it climbed the hill).
func make_clear_origin(origin: Vector3) -> Vector3:
	var out := origin
	for i in MAX_LIFTS:
		var hits := _surfaces_in_columns(out, FOOTPRINT_RADIUS, VEHICLE_HEADROOM, false)
		if hits.is_empty():
			return out
		out.y = _make_landing_height(hits) + STANDING_GAP
	push_error("SpawnClearance: no free space above the spawn at %s" % origin)
	return out


## `origin` raised onto the top of a walkable surface (a deck, a roof) lying less than `headroom` above it: a soldier set down in
## a gap lower than his body (an infantry drop point under a platform) stands on the platform instead. Only the column over
## the point counts; `origin` when the headroom is free.
func make_headroom_origin(origin: Vector3, headroom: float) -> Vector3:
	var out := origin
	for i in MAX_LIFTS:
		var hits := _surfaces_in_columns(out, 0.0, headroom)
		hits = hits.filter(func(h: Dictionary) -> bool: return h.walkable)
		if hits.is_empty():
			return out
		out.y = _make_landing_height(hits) + STANDING_GAP
	return out


## Where a spawn kept at its file height (a raised pad, the inside of a base) really stands: `origin` itself when a
## walkable surface lies within SUPPORT_REACH below it, else the top of the highest surface below it - a building's roof
## or floor, else the terrain (the nearest solid ground over a hole) - so a drop point the file puts in the air (a Tribes 2
## spawn sphere high above its terrain) lands on the ground it belongs to. Under the terrain surface the point is inside a
## base only while a building's floor lies within BASE_FLOOR_REACH below it; with none it is buried in the heightfield
## (the file's height and ours differ) and comes up onto the terrain.
func make_supported_origin(origin: Vector3) -> Vector3:
	var surface := MapTerrain.make_surface_height(_parent, origin)
	if surface == INF:
		return origin
	if origin.y <= surface:
		var base_floor := make_floor_height_below(origin, BASE_FLOOR_REACH)
		if base_floor > -INF:
			return origin if origin.y - base_floor <= SUPPORT_REACH else Vector3(origin.x, base_floor, origin.z)
		return _make_terrain_origin(origin, surface)
	var floor_y := make_floor_height_below(origin, origin.y - surface + SUPPORT_REACH)
	if floor_y >= origin.y - SUPPORT_REACH:
		return origin
	if floor_y > -INF:
		return Vector3(origin.x, floor_y, origin.z)
	return _make_terrain_origin(origin, surface)


## The point on the terrain's collision at `origin`'s x/z (the nearest solid ground over a hole; `origin` when there is none).
func _make_terrain_origin(origin: Vector3, surface: float) -> Vector3:
	if MapTerrain.ground_height(_parent, Vector3(origin.x, -INF, origin.z)) > -INF:
		return Vector3(origin.x, MapTerrain.make_collision_height(_parent, origin), origin.z)
	var solid := MapTerrain.make_nearest_solid_ground(_parent, origin)
	return solid if solid != Vector3.INF else origin


## The height of the highest walkable building surface up to `reach` below `origin` (-INF when there is none; the terrain
## is not one of them unless it is a trimesh).
func make_floor_height_below(origin: Vector3, reach: float) -> float:
	return _make_surface_height_below(origin, reach, true, true)


## make_floor_height_below counting steep faces too when `walkable_only` is false (the slope a spawn stands on), and
## leaving the terrain's own trimesh out when `with_terrain` is false (make_terrain_rise judges that).
func _make_surface_height_below(origin: Vector3, reach: float, walkable_only: bool, with_terrain: bool) -> float:
	var bottom := origin + Vector3.DOWN * reach
	var top := origin + Vector3.UP * FLOOR_TOLERANCE
	var best := -INF
	for s in _solids:
		if (with_terrain or not s.terrain) and (s.aabb as AABB).intersects_segment(bottom, top):
			for hit in _column_hits(s, bottom, top):
				if hit.walkable or not walkable_only:
					best = maxf(best, hit.y)
	return best


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


## `origin` when it is under open sky, else the nearest terrain point round it that is (an infantry drop point inside a
## base: the Herc starts on the ground next to the base).
func make_open_ground_origin(origin: Vector3) -> Vector3:
	return _find_ground(origin, func(p: Vector3) -> bool: return not is_under_cover(p))


## make_open_ground_origin on level ground as well (a Herc slides off a steeper slope; is_open_ground).
func make_level_ground_origin(origin: Vector3) -> Vector3:
	return _find_ground(origin, is_open_ground)


## `origin` when `accepts` it, else the nearest terrain point round it (rings of OPEN_SEARCH_STEP out to OPEN_SEARCH_RADIUS,
## at the height above the terrain `origin` has, at most STANDING_GAP: a start on a raised platform lands on the ground) that
## it accepts; `origin` when there is none.
func _find_ground(origin: Vector3, accepts: Callable) -> Vector3:
	if accepts.call(origin):
		return origin
	var surface := MapTerrain.make_surface_height(_parent, origin)   # (the heightfield's height over a hole too)
	var above := origin.y - (MapTerrain.ground_height(_parent, origin) if surface == INF else surface)
	var lift := clampf(above, 0.0, STANDING_GAP) if above >= 0.0 else STANDING_GAP   # (below the surface: inside a base)
	for ring in range(1, int(OPEN_SEARCH_RADIUS / OPEN_SEARCH_STEP) + 1):
		for k in OPEN_SEARCH_DIRECTIONS:
			var angle := TAU * k / OPEN_SEARCH_DIRECTIONS
			var p := origin + Vector3(cos(angle), 0.0, sin(angle)) * OPEN_SEARCH_STEP * ring
			if _is_over_hole(p):
				continue   # (no ground here: the point would hang at the height of `origin`)
			p.y = MapTerrain.ground_height(_parent, p) + lift
			if accepts.call(p):
				return p
	return origin


## Whether `p` lies over a hole in the terrain (a base's cut-out): the heightfield is there but has no ground.
func _is_over_hole(p: Vector3) -> bool:
	return MapTerrain.make_surface_height(_parent, p) != INF and MapTerrain.ground_height(_parent, Vector3(p.x, -INF, p.z)) == -INF


## Whether `origin` is under open sky (not is_under_cover) on level ground (the terrain and the building floor under it rise
## by at most OPEN_MAX_RISE).
func is_open_ground(origin: Vector3) -> bool:
	return not is_under_cover(origin) and make_terrain_rise(origin) <= OPEN_MAX_RISE and make_floor_rise(origin) <= OPEN_MAX_RISE 			and not is_walled_in(origin)


## Whether a building face stands within WALL_CLEAR_M of `origin` at the heights a Herc's body fills (a wall, a pillar or a
## bunker's side: the Herc would start inside it). The terrain is not a building.
func is_walled_in(origin: Vector3) -> bool:
	for h in WALL_PROBE_HEIGHTS:
		var from := origin + Vector3.UP * h
		for k in WALL_PROBE_DIRECTIONS:
			var to := from + Vector3.FORWARD.rotated(Vector3.UP, TAU * k / WALL_PROBE_DIRECTIONS) * WALL_CLEAR_M
			for s in _solids:
				if s.terrain or not (s.aabb as AABB).intersects_segment(from, to):
					continue
				var to_local: Transform3D = s.to_local
				if not (s.mesh as TriangleMesh).intersect_segment(to_local * from, to_local * to).is_empty():
					return true
	return false


## The steepest rise per metre of the building floor `origin` stands on (within FLOOR_SCAN_REACH) towards the four points
## OPEN_FOOTPRINT_RADIUS round it; an edge with neither a floor nor terrain within FLOOR_SCAN_REACH below is a drop (INF).
## 0 when `origin` stands on no building floor (make_terrain_rise judges the terrain). A ramp or a platform's rim beside a
## terrain hole, where the heightfield sees nothing.
func make_floor_rise(origin: Vector3) -> float:
	var here := _make_surface_height_below(origin, FLOOR_SCAN_REACH, false, false)
	if here == -INF:
		return 0.0
	var steepest := 0.0
	for offset in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var side: Vector3 = origin + offset * OPEN_FOOTPRINT_RADIUS
		side.y = here + FLOOR_SCAN_ABOVE
		var h := _make_surface_height_below(side, FLOOR_SCAN_REACH, false, false)
		var terrain := MapTerrain.make_collision_height(_parent, side)
		if terrain != side.y and terrain <= side.y:
			h = maxf(h, terrain)
		steepest = maxf(steepest, INF if h == -INF else absf(h - here) / OPEN_FOOTPRINT_RADIUS)
	return steepest


## The steepest rise per metre of the terrain between `origin` and the four points round it: OPEN_FOOTPRINT_RADIUS away, or
## half a grid square on a coarse heightfield (Earthsiege 2's squares hold cliffs a bilinear height at 4 m does not show).
func make_terrain_rise(origin: Vector3) -> float:
	var radius := OPEN_FOOTPRINT_RADIUS
	var square := MapTerrain.make_square_size(_parent, origin)
	if square > COARSE_SQUARE_M:
		radius = square * 0.5
	return MapTerrain.make_rise(_parent, origin, radius)


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
## up to `height`: [{"y": float, "walkable": bool}]. With `terrain_beside` false the terrain is left out of the columns
## round the middle one.
func _surfaces_in_columns(origin: Vector3, radius: float, height: float, terrain_beside := true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for offset in FOOTPRINT_OFFSETS:
		var base := origin + offset * radius
		var bottom := base + Vector3.UP * FLOOR_TOLERANCE
		var top := base + Vector3.UP * height
		for s in _solids:
			if s.terrain and not terrain_beside and offset != Vector3.ZERO:
				continue
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

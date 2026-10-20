class_name MapBounds
extends RefCounted
## The playable area of a battlefield and the floor below which a body has fallen out of the world.
##
## Area (engine x/z), first that applies:
##   an engine-schema map's "bounds" (Tribes MissionCenterPos / Tribes 2 MissionArea, Starsiege the mission's
##     area; map_schema.md),
##   a heightfield's extent (Earthsiege 2 worlds: the ground ends there),
##   an Earthsiege world's ground plane (WorldBuilder.GROUND_PLANE_SIZE round the origin; the original ends the
##     mission when the player leaves the map, end code 8 after the out-of-bounds warning 7, mission.md section 5),
##   none (Battledrome arenas: their wall keeps everyone in).
## Floor (remake rule): FELL_THROUGH_DEPTH below the lowest solid of the battlefield, terrain sample or building
## (underground Tribes / Tribes 2 bases, Starsiege tunnels and interiors reach far below the terrain), and at a
## point FELL_THROUGH_DEPTH below the lower of the terrain there and the bottoms of the buildings over it that reach
## below that terrain (an underground base lowers the floor; a bridge or a floating base never raises it).

const FELL_THROUGH_DEPTH := 100.0

var area := Rect2()
var has_area := false
var floor_y := -FELL_THROUGH_DEPTH
## World boxes of the buildings and props (static bodies other than the terrain) when the bounds were made.
var solids: Array[AABB] = []
## Height of the flat ground plane where the map has no terrain (INF without one).
var ground_plane_y := INF


## Bounds of the battlefield built under `parent`: `built` is the builder's result (MapBuilder / ArenaBuilder /
## WorldBuilder), its "map" the engine-schema map when there is one.
static func make_for(parent: Node3D, built: Dictionary) -> MapBounds:
	var b := MapBounds.new()
	var terrain := make_terrain_extent(parent)
	b.solids = make_solid_boxes(parent)
	b.ground_plane_y = make_lowest_ground_plane_height(parent)
	b.floor_y = make_lowest_solid_height(parent, b.solids) - FELL_THROUGH_DEPTH
	var m: Dictionary = built.get("map", {}) if built.get("map") is Dictionary else {}
	if m.get("bounds") is Dictionary:
		var rect := make_rect_of(m.bounds)
		if terrain.has_area():
			rect = rect.intersection(terrain)   # a mission area running past the heightfield has no ground there
		b.apply_area(rect if rect.has_area() else make_rect_of(m.bounds))
	elif terrain.has_area():
		b.apply_area(terrain)
	elif built.has("world"):
		b.apply_area(Rect2(-WorldBuilder.GROUND_PLANE_SIZE * 0.5, WorldBuilder.GROUND_PLANE_SIZE))
	return b


func apply_area(rect: Rect2) -> void:
	area = rect
	has_area = rect.has_area()


## True when `p` is outside the playable area (never when there is none).
func is_outside(p: Vector3) -> bool:
	return has_area and not area.has_point(Vector2(p.x, p.z))


## True when `p` has fallen out of the world under `parent`.
func is_below_floor(parent: Node3D, p: Vector3) -> bool:
	return p.y < floor_y or p.y < make_local_floor(parent, p)


## The floor at `p`'s x/z: FELL_THROUGH_DEPTH below the terrain there or the lowest bottom of a building over it
## that reaches below the terrain, whichever is lower. Without terrain under `p` only such buildings count
## (-INF: no local floor).
func make_local_floor(parent: Node3D, p: Vector3) -> float:
	var ground := MapTerrain.make_surface_height(parent, p)
	if ground == INF:
		ground = ground_plane_y   # off the terrain (or none at all): the flat ground, a building reaching below it lowers the floor
	var lowest := ground
	for box in solids:
		if p.x >= box.position.x and p.x <= box.end.x and p.z >= box.position.z and p.z <= box.end.z 				and box.position.y < ground:
			lowest = minf(lowest, box.position.y)
	return lowest - FELL_THROUGH_DEPTH if lowest < INF else -INF


## World boxes of the static bodies under `parent` (buildings, props, structures), the terrain left out.
static func make_solid_boxes(parent: Node3D) -> Array[AABB]:
	var out: Array[AABB] = []
	for body in parent.find_children("*", "StaticBody3D", true, false):
		if body.is_in_group("terrain"):
			continue
		var box := _make_mesh_box(body)
		if box.size != Vector3.ZERO:
			out.append(box)
	return out


static func _make_mesh_box(body: Node3D) -> AABB:
	var box := AABB()
	var found := false
	for mi in body.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).mesh == null or mi.mesh is PlaneMesh:
			continue   # the Earthsiege ground plane is no building
		var b: AABB = mi.global_transform * (mi as MeshInstance3D).get_aabb()
		box = b if not found else box.merge(b)
		found = true
	# Collision shapes count too: brush shells and null-surface hulls collide without a drawn mesh.
	for cs in body.find_children("*", "CollisionShape3D", true, false):
		var shape: Shape3D = (cs as CollisionShape3D).shape
		if shape == null or shape is WorldBoundaryShape3D or shape is SeparationRayShape3D:
			continue   # an infinite plane is no building
		var dbg := shape.get_debug_mesh()
		if dbg == null:
			continue
		var b2: AABB = (cs as Node3D).global_transform * dbg.get_aabb()
		box = b2 if not found else box.merge(b2)
		found = true
	return box


## The lowest point of the terrain and the solids (0 without either).
static func make_lowest_solid_height(parent: Node3D, boxes: Array[AABB]) -> float:
	var lowest := make_lowest_terrain_height(parent)
	var plane := make_lowest_ground_plane_height(parent)
	if plane < INF:
		lowest = minf(lowest, plane) if make_terrain_extent(parent).has_area() else plane   # no terrain: the plane is the ground
	for box in boxes:
		lowest = minf(lowest, box.position.y)
	return lowest


## The lowest flat ground plane (WorldBoundaryShape3D body) under `parent`, INF without one.
static func make_lowest_ground_plane_height(parent: Node3D) -> float:
	var lowest := INF
	for cs in parent.find_children("*", "CollisionShape3D", true, false):
		if (cs as CollisionShape3D).shape is WorldBoundaryShape3D and (cs.get_parent() as Node3D) != null:
			var plane: WorldBoundaryShape3D = cs.shape
			lowest = minf(lowest, (cs as Node3D).global_position.y + plane.plane.d)
	return lowest


## Map schema bounds {"min": [x, z], "max": [x, z]} as a Rect2 (x, z).
static func make_rect_of(bounds: Dictionary) -> Rect2:
	var lo: Array = bounds.get("min", [0, 0])
	var hi: Array = bounds.get("max", [0, 0])
	var a := Vector2(float(lo[0]), float(lo[1]))
	return Rect2(a, Vector2(float(hi[0]), float(hi[1])) - a).abs()


## The union of the heightfields' extents under `parent` (empty without terrain).
static func make_terrain_extent(parent: Node3D) -> Rect2:
	var out := Rect2()
	for t in _terrains(parent):
		var d: Dictionary = t.get_meta("terrain")
		var r := Rect2(float(d.x0), float(d.z0), (int(d.w) - 1) * float(d.sq), (int(d.h) - 1) * float(d.sq))
		out = r if not out.has_area() else out.merge(r)
	return out


## The lowest terrain sample under `parent` (0 without terrain).
static func make_lowest_terrain_height(parent: Node3D) -> float:
	var lowest := INF
	for t in _terrains(parent):
		var heights: PackedFloat32Array = t.get_meta("terrain").heights
		for h in heights:
			lowest = minf(lowest, h)
	return lowest if lowest < INF else 0.0


static func _terrains(parent: Node3D) -> Array:
	return MapTerrain.make_live_terrains(parent)

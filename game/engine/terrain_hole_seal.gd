class_name TerrainHoleSeal
extends RefCounted
## Closes the parts of terrain holes (MapTerrain HOLE squares: Tribes / Tribes 2 emptySquares, cut from the terrain
## mesh and collision for the entrances of underground bases) that no base lies under. A hole square is 8 m wide
## and the base under it often covers only part of it; the terrain also repeats its holes on every copy of the
## tile, where no base stands. Through such an open part a soldier or vehicle fell out of the world (playtest:
## Katabatic). Each hole square is checked in SUBDIVISIONS x SUBDIVISIONS cells: a cell with no building face below
## its opening gets an invisible collision patch on the terrain surface (remake rule; the original's holes sit
## over the bases and the players never reach their uncovered edges or the far tile copies).

const SUBDIVISIONS := 4
## A building face this far above the terrain surface still counts as under the opening (a hole's rim is uneven).
const OPENING_TOLERANCE := 2.0
## Faces steeper than this (|normal.y| below it) are walls: they don't stop a fall.
const FLOOR_NORMAL_Y := 0.1


## Seals the open hole cells of the terrain under `parent` against the buildings in `building_group`; returns the
## number of cells sealed.
static func apply(parent: Node3D, building_group: StringName) -> int:
	var terrains := MapTerrain.make_live_terrains(parent).filter(func(t: Node) -> bool: return parent.is_ancestor_of(t))
	if terrains.is_empty():
		return 0
	var terrain: StaticBody3D = terrains[0]
	var d: Dictionary = terrain.get_meta("terrain")
	var holes: PackedByteArray = d.get("holes", PackedByteArray())
	if holes.is_empty():
		return 0
	var buckets := _make_face_buckets(parent, building_group, d)
	var patch := PackedVector3Array()
	var sealed := 0
	var w := int(d.w)
	for row in int(d.h) - 1:
		for col in w - 1:
			if holes[row * (w - 1) + col] == MapTerrain.HOLE:
				sealed += _seal_square(d, Vector2i(col, row), buckets.get(Vector2i(col, row), []), patch)
	if not patch.is_empty():
		_add_patch(terrain, patch)
	return sealed


## Non-vertical faces of the buildings (world space), by the terrain squares their x/z box touches.
static func _make_face_buckets(parent: Node3D, building_group: StringName, d: Dictionary) -> Dictionary:
	var buckets := {}
	for body in parent.get_tree().get_nodes_in_group(building_group):
		if not parent.is_ancestor_of(body):
			continue
		for col in body.find_children("*", "CollisionShape3D", true, false):
			var shape := (col as CollisionShape3D).shape as ConcavePolygonShape3D
			if shape == null:
				continue
			var xf: Transform3D = (col as Node3D).global_transform
			var faces := shape.get_faces()
			for i in range(0, faces.size(), 3):
				_add_face(buckets, d, [xf * faces[i], xf * faces[i + 1], xf * faces[i + 2]])
	return buckets


static func _add_face(buckets: Dictionary, d: Dictionary, tri: Array) -> void:
	var n: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0])
	if n.length_squared() < 1e-8 or absf(n.normalized().y) < FLOOR_NORMAL_Y:
		return
	var sq := float(d.sq)
	var lo := Vector2i(int(floorf((minf(minf(tri[0].x, tri[1].x), tri[2].x) - float(d.x0)) / sq)),
		int(floorf((minf(minf(tri[0].z, tri[1].z), tri[2].z) - float(d.z0)) / sq)))
	var hi := Vector2i(int(floorf((maxf(maxf(tri[0].x, tri[1].x), tri[2].x) - float(d.x0)) / sq)),
		int(floorf((maxf(maxf(tri[0].z, tri[1].z), tri[2].z) - float(d.z0)) / sq)))
	for col in range(maxi(lo.x, 0), mini(hi.x, int(d.w) - 2) + 1):
		for row in range(maxi(lo.y, 0), mini(hi.y, int(d.h) - 2) + 1):
			var key := Vector2i(col, row)
			if not buckets.has(key):
				buckets[key] = []
			buckets[key].append(tri)


## Adds the patch triangles of the open cells of hole square `cell` to `patch`; returns how many were open.
static func _seal_square(d: Dictionary, cell: Vector2i, faces: Array, patch: PackedVector3Array) -> int:
	var open := 0
	var step := 1.0 / SUBDIVISIONS
	for a in SUBDIVISIONS:
		for b in SUBDIVISIONS:
			var fx := cell.x + (a + 0.5) * step
			var fz := cell.y + (b + 0.5) * step
			var centre := _make_point(d, fx, fz)
			if _is_covered(faces, centre):
				continue
			open += 1
			var c00 := _make_point(d, cell.x + a * step, cell.y + b * step)
			var c10 := _make_point(d, cell.x + (a + 1) * step, cell.y + b * step)
			var c01 := _make_point(d, cell.x + a * step, cell.y + (b + 1) * step)
			var c11 := _make_point(d, cell.x + (a + 1) * step, cell.y + (b + 1) * step)
			patch.append_array([c00, c10, c11, c00, c11, c01])
	return open


## The terrain surface point at grid position fx / fz (holes ignored).
static func _make_point(d: Dictionary, fx: float, fz: float) -> Vector3:
	return Vector3(float(d.x0) + fx * float(d.sq), MapTerrain.make_grid_height(d, fx, fz), float(d.z0) + fz * float(d.sq))


## True when a building face lies under (or just above) the opening at `p`.
static func _is_covered(faces: Array, p: Vector3) -> bool:
	var q := Vector2(p.x, p.z)
	for tri in faces:
		var a := Vector2(tri[0].x, tri[0].z)
		var b := Vector2(tri[1].x, tri[1].z)
		var c := Vector2(tri[2].x, tri[2].z)
		if not Geometry2D.point_is_inside_triangle(q, a, b, c):
			continue
		var plane := Plane(tri[0], tri[1], tri[2])
		var y = plane.intersects_ray(Vector3(p.x, p.y + 1000.0, p.z), Vector3.DOWN)
		if y != null and (y as Vector3).y <= p.y + OPENING_TOLERANCE:
			return true
	return false


static func _add_patch(terrain: StaticBody3D, patch: PackedVector3Array) -> void:
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(patch)
	var col := CollisionShape3D.new()
	col.name = "HoleSeal"
	col.shape = shape
	terrain.add_child(col)
	col.global_transform = Transform3D.IDENTITY

class_name MapTerrain
extends RefCounted
## Heightfield terrain of the engine map schema (docs/formats/map_schema.md "terrain"): render mesh
## in chunks plus collision (HeightMapShape3D, or per-chunk trimeshes when the terrain has holes),
## and the bilinear ground height lookup used to place things on it.

## Render chunk size in squares.
const CHUNK := 64
## Hole mask value (L8, one pixel per square): entrances to underground bases.
const HOLE := 255
const DEFAULT_COLOUR := Color(0.45, 0.42, 0.36)
const DEFAULT_SIZE := [256, 256]
const DEFAULT_SQUARE := 8.0
const TERRAIN_SHADER := preload("res://engine/shaders/terrain.gdshader")
const NOISE_SIZE := 256
## Strengths of the world-space variation (terrain.gdshader uniforms); a map overrides them with terrain "detail".
const DETAIL_DEFAULTS := {"warp": 0.0, "macro_amount": 0.14, "mid_amount": 0.08, "fine_amount": 0.06, "grit_amount": 0.08,
	"warm_amount": 0.05}

static var _noise_texture: ImageTexture


## Builds the terrain body under `parent`. t: the map's terrain dict; dir: the map folder.
static func build(parent: Node3D, t: Dictionary, dir: String) -> void:
	var size: Array = t.get("size", DEFAULT_SIZE)
	var grid := {"w": int(size[0]), "h": int(size[1]), "sq": float(t.get("square", DEFAULT_SQUARE)),
		"org": t.get("origin", [0.0, 0.0]), "rep": float(t.get("albedo_repeat", 1.0))}
	var heights := _load_heights(t, dir)
	if heights.size() < grid.w * grid.h:
		push_error("terrain heights missing/short")
		return
	grid["heights"] = heights
	grid["holes"] = _load_holes(t, dir, grid.w, grid.h)
	var body := StaticBody3D.new()
	body.name = "Terrain"
	body.add_to_group("terrain")
	body.set_meta("terrain", {"w": grid.w, "h": grid.h, "sq": grid.sq, "x0": float(grid.org[0]), "z0": float(grid.org[1]),
		"heights": heights, "holes": grid.holes})
	parent.add_child(body)
	var mat: Material = null if ServerProfile.is_collision_only() else _material(t, dir)
	var has_holes: bool = not grid.holes.is_empty()
	if not has_holes:
		_add_heightmap_collision(body, grid)
	_build_chunks(body, grid, mat, has_holes)


## Heights (scaled by height_scale): in memory (e.g. WorldBuilder's padded ES2 grid) or a .r32 file.
static func _load_heights(t: Dictionary, dir: String) -> PackedFloat32Array:
	var heights := PackedFloat32Array()
	if t.get("heights_data") is PackedFloat32Array:
		heights = PackedFloat32Array(t.heights_data)
	else:
		heights = FileAccess.get_file_as_bytes(dir.path_join(String(t.get("heights", "height.r32")))).to_float32_array()
	var hs := float(t.get("height_scale", 1.0))
	if hs != 1.0:
		for i in heights.size():
			heights[i] *= hs
	return heights


## Hole mask, one byte per square ((w-1) x (h-1)); empty when there are no holes. "holes" is a mask image or a
## list of [column, row] squares (Tribes 2 emptySquares, tools/export_tribes2_maps.py).
static func _load_holes(t: Dictionary, dir: String, w: int, h: int) -> PackedByteArray:
	if t.get("holes") is Array:
		return _make_hole_mask(t.holes, w, h)
	var hp := dir.path_join(String(t.get("holes", ""))) if t.get("holes") is String else ""
	if hp == "" or not FileAccess.file_exists(hp):
		return PackedByteArray()
	var himg := Image.load_from_file(hp)
	if not himg:
		return PackedByteArray()
	himg.convert(Image.FORMAT_L8)
	if himg.get_width() != w - 1 or himg.get_height() != h - 1:
		himg.resize(w - 1, h - 1, Image.INTERPOLATE_NEAREST)
	var holes := himg.get_data()
	return holes if holes.count(HOLE) > 0 else PackedByteArray()


## The hole mask of a list of [column, row] squares (squares outside the grid are ignored).
static func _make_hole_mask(squares: Array, w: int, h: int) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize((w - 1) * (h - 1))
	for sq in squares:
		var col := int(sq[0])
		var row := int(sq[1])
		if col >= 0 and row >= 0 and col < w - 1 and row < h - 1:
			mask[row * (w - 1) + col] = HOLE
	return mask if mask.count(HOLE) > 0 else PackedByteArray()


## The terrain material: the map's colour map under the world-space variation of terrain.gdshader (the map's "detail"
## record overrides DETAIL_DEFAULTS), so repeated or coarse colour maps show no grid or tiling from the air.
static func _material(t: Dictionary, dir: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = TERRAIN_SHADER
	mat.set_shader_parameter("noise_tex", _make_noise_texture())
	var ap := dir.path_join(String(t.get("albedo", "albedo.png")))
	var img: Image = null
	if t.get("albedo_data") is Image:   # baked in memory (the generated extraction map, VarunaMap)
		img = t.albedo_data
	elif FileAccess.file_exists(ap):
		img = Image.load_from_file(ap)
	if img != null:
		img.generate_mipmaps()
		mat.set_shader_parameter("albedo_tex", ImageTexture.create_from_image(img))
		mat.set_shader_parameter("has_albedo", 1.0)
	else:
		mat.set_shader_parameter("has_albedo", 0.0)
		mat.set_shader_parameter("base_color", DEFAULT_COLOUR)
	var detail: Dictionary = DETAIL_DEFAULTS.duplicate()
	if t.get("detail") is Dictionary:   # (a Tribes 2 map's "detail" is its detail texture file name)
		detail.merge(t.detail, true)
	for k in detail:
		mat.set_shader_parameter(k, float(detail[k]))
	return mat


## Four seamless noise fields (one per channel, normalised to the full 0..1 range) that terrain.gdshader samples at
## its scales; made once.
static func _make_noise_texture() -> ImageTexture:
	if _noise_texture != null:
		return _noise_texture
	var channels: Array[Image] = []
	for c in 4:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = 4
		n.frequency = 0.02
		n.seed = 7101 + c * 977
		var ch := n.get_seamless_image(NOISE_SIZE, NOISE_SIZE)
		ch.convert(Image.FORMAT_L8)
		channels.append(ch)
	var bytes := PackedByteArray()
	bytes.resize(NOISE_SIZE * NOISE_SIZE * 4)
	for c in 4:
		var src := channels[c].get_data()
		var lo := 255
		var hi := 0
		for v in src:
			lo = mini(lo, v)
			hi = maxi(hi, v)
		var span := float(maxi(hi - lo, 1))
		for i in src.size():
			bytes[i * 4 + c] = int(float(src[i] - lo) / span * 255.0)
	var img := Image.create_from_data(NOISE_SIZE, NOISE_SIZE, false, Image.FORMAT_RGBA8, bytes)
	img.generate_mipmaps()
	_noise_texture = ImageTexture.create_from_image(img)
	return _noise_texture


## HeightMapShape3D is centred on its node and spaced 1 unit -> scaled by the square size.
static func _add_heightmap_collision(body: StaticBody3D, grid: Dictionary) -> void:
	var w: int = grid.w
	var h: int = grid.h
	var sq: float = grid.sq
	var hm := HeightMapShape3D.new()
	hm.map_width = w
	hm.map_depth = h
	var scaled := PackedFloat32Array(grid.heights)
	for i in scaled.size():
		scaled[i] /= sq
	hm.map_data = scaled
	var col := CollisionShape3D.new()
	col.shape = hm
	col.scale = Vector3(sq, sq, sq)
	col.position = Vector3(float(grid.org[0]) + (w - 1) * sq * 0.5, 0.0, float(grid.org[1]) + (h - 1) * sq * 0.5)
	body.add_child(col)


## Render mesh in chunks of CHUNK x CHUNK squares; hole squares are skipped. With `collide`, each
## chunk also gets a trimesh collider (used when the terrain has holes; HeightMapShape3D can't).
static func _build_chunks(body: StaticBody3D, grid: Dictionary, mat: Material, collide: bool) -> void:
	var w: int = grid.w
	var h: int = grid.h
	for cz in range(0, h - 1, CHUNK):
		for cx in range(0, w - 1, CHUNK):
			LoadKeepAlive.pump()
			var mesh := _chunk_mesh(grid, Rect2i(cx, cz, mini(cx + CHUNK, w - 1) - cx, mini(cz + CHUNK, h - 1) - cz), mat)
			if mesh == null:
				continue
			if not ServerProfile.is_collision_only():
				var mi := MeshInstance3D.new()
				mi.mesh = mesh
				body.add_child(mi)
			if collide:
				_add_trimesh_collision(body, mesh)


## Mesh of the squares in `r` (position = first square, size = squares); null if all are holes.
static func _chunk_mesh(grid: Dictionary, r: Rect2i, mat: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_chunk_vertices(st, grid, r)
	var holes: PackedByteArray = grid.holes
	var w: int = grid.w
	var cols := r.size.x + 1
	var tris := 0
	for z in r.size.y:
		for x in r.size.x:
			if not holes.is_empty() and holes[(r.position.y + z) * (w - 1) + r.position.x + x] == HOLE:
				continue
			var i0 := z * cols + x
			for i in [i0, i0 + 1, i0 + cols, i0 + 1, i0 + cols + 1, i0 + cols]:
				st.add_index(i)
			tris += 2
	if tris == 0:
		return null
	st.set_material(mat)
	return st.commit()


static func _add_chunk_vertices(st: SurfaceTool, grid: Dictionary, r: Rect2i) -> void:
	var heights: PackedFloat32Array = grid.heights
	var w: int = grid.w
	var h: int = grid.h
	var sq: float = grid.sq
	var org: Array = grid.org
	var rep: float = grid.rep
	for z in range(r.position.y, r.end.y + 1):
		for x in range(r.position.x, r.end.x + 1):
			var y := heights[z * w + x]
			var nx := heights[z * w + maxi(x - 1, 0)] - heights[z * w + mini(x + 1, w - 1)]
			var nz := heights[maxi(z - 1, 0) * w + x] - heights[mini(z + 1, h - 1) * w + x]
			st.set_normal(Vector3(nx, 2.0 * sq, nz).normalized())
			st.set_uv(Vector2(float(x) / (w - 1), float(z) / (h - 1)) * rep)
			st.add_vertex(Vector3(float(org[0]) + x * sq, y, float(org[1]) + z * sq))


static func _add_trimesh_collision(body: StaticBody3D, mesh: Mesh) -> void:
	var cs := CollisionShape3D.new()
	var shp := ConcavePolygonShape3D.new()
	shp.set_faces(mesh.get_faces())
	shp.backface_collision = true
	cs.shape = shp
	body.add_child(cs)


## Terrain height at a world position (bilinear); p.y where there is no terrain (or over a hole).
static func ground_height(parent: Node3D, p: Vector3) -> float:
	for t in make_live_terrains(parent):
		var d: Dictionary = t.get_meta("terrain")
		var fx := (p.x - float(d.x0)) / float(d.sq)
		var fz := (p.z - float(d.z0)) / float(d.sq)
		if fx < 0 or fz < 0 or fx > int(d.w) - 1 or fz > int(d.h) - 1:
			continue
		return _height_in(d, fx, fz, p.y)
	return p.y


## The terrains in the tree, except those of a battlefield being freed (a test or a rematch builds the next
## battle before the last one has left the tree; its terrain must not answer for the new one).
static func make_live_terrains(parent: Node3D) -> Array:
	if not parent.is_inside_tree():
		return []
	return parent.get_tree().get_nodes_in_group("terrain").filter(func(t: Node) -> bool: return not _is_leaving(t))


static func _is_leaving(n: Node) -> bool:
	while n != null:
		if n.is_queued_for_deletion():
			return true
		n = n.get_parent()
	return false


## The height a body must stand at to rest on the terrain's collision at `p`'s x/z: the height of the collision triangle
## there (the squares are split along the diagonal of _chunk_mesh, which the heightmap shape shares; on the coarse squares of
## Earthsiege 2 it differs from the bilinear height by metres). `p.y` over a hole or off the terrain (see ground_height).
static func make_collision_height(parent: Node3D, p: Vector3) -> float:
	for t in make_live_terrains(parent):
		var d: Dictionary = t.get_meta("terrain")
		var fx := (p.x - float(d.x0)) / float(d.sq)
		var fz := (p.z - float(d.z0)) / float(d.sq)
		if fx < 0 or fz < 0 or fx > int(d.w) - 1 or fz > int(d.h) - 1:
			continue
		if _height_in(d, fx, fz, INF) == INF:
			return p.y   # (a hole)
		return _make_triangle_height(d, fx, fz)
	return p.y


## The height of the collision triangle over grid position fx / fz (squares split from corner (x+1, z) to (x, z+1)).
static func _make_triangle_height(d: Dictionary, fx: float, fz: float) -> float:
	var w := int(d.w)
	var x0 := mini(int(fx), w - 2)
	var z0 := mini(int(fz), int(d.h) - 2)
	var u := fx - x0
	var v := fz - z0
	var hts: PackedFloat32Array = d.heights
	var h00 := hts[z0 * w + x0]
	var h10 := hts[z0 * w + x0 + 1]
	var h01 := hts[(z0 + 1) * w + x0]
	var h11 := hts[(z0 + 1) * w + x0 + 1]
	if u + v <= 1.0:
		return h00 + u * (h10 - h00) + v * (h01 - h00)
	return h11 + (1.0 - u) * (h01 - h11) + (1.0 - v) * (h10 - h11)


## The grid square size (metres) of the terrain under `p` (0 off the terrain).
static func make_square_size(parent: Node3D, p: Vector3) -> float:
	for t in make_live_terrains(parent):
		var d: Dictionary = t.get_meta("terrain")
		var fx := (p.x - float(d.x0)) / float(d.sq)
		var fz := (p.z - float(d.z0)) / float(d.sq)
		if fx >= 0 and fz >= 0 and fx <= int(d.w) - 1 and fz <= int(d.h) - 1:
			return float(d.sq)
	return 0.0


## The steepest rise per metre of the terrain between `p` and the four points `radius` metres round it (0 off the terrain).
static func make_rise(parent: Node3D, p: Vector3, radius: float) -> float:
	var here := ground_height(parent, p)
	var steepest := 0.0
	for offset in [Vector3(radius, 0, 0), Vector3(-radius, 0, 0), Vector3(0, 0, radius), Vector3(0, 0, -radius)]:
		steepest = maxf(steepest, absf(ground_height(parent, p + offset) - here) / radius)
	return steepest


## The heightfield's height at `p`'s x/z, over terrain holes too (their samples are still there; a base's entrance
## sits at about that height), INF off every terrain.
static func make_surface_height(parent: Node3D, p: Vector3) -> float:
	for t in make_live_terrains(parent):
		var d: Dictionary = t.get_meta("terrain")
		var fx := (p.x - float(d.x0)) / float(d.sq)
		var fz := (p.z - float(d.z0)) / float(d.sq)
		if fx >= 0 and fz >= 0 and fx <= int(d.w) - 1 and fz <= int(d.h) - 1:
			return _sample_heights(d, fx, fz)
	return INF


## The nearest point of solid terrain (not over a hole) to `p`'s x/z, searched in rings of squares out to `reach`
## metres; Vector3.INF when there is none.
static func make_nearest_solid_ground(parent: Node3D, p: Vector3, reach := 96.0) -> Vector3:
	for t in make_live_terrains(parent):
		var d: Dictionary = t.get_meta("terrain")
		var sq := float(d.sq)
		var steps := int(ceil(reach / sq))
		for r in range(0, steps + 1):
			var best := Vector3.INF
			for i in range(-r, r + 1):
				for k in range(-r, r + 1):
					if maxi(absi(i), absi(k)) != r:
						continue
					var q := Vector3(snappedf(p.x, sq) + i * sq, p.y, snappedf(p.z, sq) + k * sq)
					var fx := (q.x - float(d.x0)) / sq
					var fz := (q.z - float(d.z0)) / sq
					if fx < 1 or fz < 1 or fx > int(d.w) - 2 or fz > int(d.h) - 2:
						continue
					var h := _height_in(d, fx, fz, INF)
					if h == INF or _height_in(d, fx + 0.5, fz + 0.5, INF) == INF or _height_in(d, fx - 0.5, fz - 0.5, INF) == INF:
						continue
					q.y = h
					if best == Vector3.INF or q.distance_squared_to(p) < best.distance_squared_to(p):
						best = q
			if best != Vector3.INF:
				return best
	return Vector3.INF


static func _height_in(d: Dictionary, fx: float, fz: float, fallback: float) -> float:
	var w := int(d.w)
	var x0 := int(fx)
	var z0 := int(fz)
	var hl: PackedByteArray = d.get("holes", PackedByteArray())
	if not hl.is_empty() and hl[mini(z0, int(d.h) - 2) * (w - 1) + mini(x0, w - 2)] == HOLE:
		return fallback   # over a hole: no ground here
	return _sample_heights(d, fx, fz)


## The heightfield's bilinear height at grid position fx / fz of terrain record `d` (its "terrain" meta), holes
## included.
static func make_grid_height(d: Dictionary, fx: float, fz: float) -> float:
	return _sample_heights(d, clampf(fx, 0.0, int(d.w) - 1), clampf(fz, 0.0, int(d.h) - 1))


## The heightfield's bilinear height at grid position fx / fz, holes included.
static func _sample_heights(d: Dictionary, fx: float, fz: float) -> float:
	var w := int(d.w)
	var x0 := int(fx)
	var z0 := int(fz)
	var x1 := mini(x0 + 1, w - 1)
	var z1 := mini(z0 + 1, int(d.h) - 1)
	var hts: PackedFloat32Array = d.heights
	var a := lerpf(hts[z0 * w + x0], hts[z0 * w + x1], fx - x0)
	var b := lerpf(hts[z1 * w + x0], hts[z1 * w + x1], fx - x0)
	return lerpf(a, b, fz - z0)

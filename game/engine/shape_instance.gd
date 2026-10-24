class_name ShapeInstance
extends Node3D
## Runtime instance of a converted 3Space shape: node hierarchy, meshes, cell states, animation.
##
## Original coordinates are x right, y forward, z up; Godot is x right, y up, -z forward.

const ANGLE := TAU / 65536.0
## Part ids used as invisible locator polygons (weapon hardpoints, muzzle/exhaust points).
const MARKER_IDS := [8, 9, 10, 11, 18, 66, 77]
## Plain 3Space TSPoly (class 0x01/0x14) has no colour field and DBSIM never draws it: its draw
## methods are empty stubs (ES2 DBSIM vtable 0x4a5ea0, 0x48dbd4..0x48dbf4). Shapes use it for
## invisible geometry: destroyed-state cell placeholders and marker plates (part id 13).
const UNDRAWN_POLY_TYPE := "poly"
## Width of a 3Space line polygon (two vertices), in shape units: about one original 320 x 200 pixel at
## a typical 20 m view distance.
const LINE_WIDTH_UNITS := 20.0
## 3Space quads map the texture to their corners in this order.
const QUAD_UVS: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
## Torque material flags.
const FLAG_TRANSLUCENT := 4
const FLAG_ADDITIVE := 8
const FLAG_SELF_ILLUMINATING := 32

## Darkstar worlds: indexed skins are drawn through the current world's palette. MapBuilder sets
## pack -> palette prefix (e.g. "starsiege" -> "Ice_d"); a skin exported with "Mars_d_2" then uses "Ice_d_2".
static var world_palettes := {}
static var _pal_exists := {}
static var _texmeta := {}
static var _rgba_cache := {}


var shape: Dictionary
var palette_name := "WORLD0"
var lod := 0
var nodes: Array[Node3D] = []
var root_offset := Vector3.ZERO
var markers := {}   # id -> Marker3D
## A skin: base texture file (lower case) -> png path in the shape's pack (SkinCatalog.make_texture_overrides).
## Set before build(); the named materials draw the skin's texture instead.
var texture_overrides := {}

# cell (damage/variant) state: piece meshes grouped by cell index and state
var _cell_meshes := []        # cell index -> Array(state) of Array[MeshInstance3D]
var _cells := []              # cell metadata from data
var _cell_state := {}         # cell index -> state shown
var _hidden_cells := {}       # cell index -> true: hidden in every state
## Torque objects by piece name: [meshes] and whether they start hidden (piece "hidden": default visibility 0;
## a sequence's visibility track shows them, ShapeCycles).
var _piece_meshes := {}       # piece name -> Array[MeshInstance3D]
var _hidden_pieces := {}      # piece name -> true

# animation
var seq_index := -1
var seq_time := 0.0
var playing := false
var loop := true
## Seconds per original tick (to be verified against the original game timing).
var tick_seconds := 0.001
var interpolate := true


static func es_to_godot(v: Array) -> Vector3:
	return Vector3(float(v[0]), float(v[2]), -float(v[1])) * Assets.UNIT


static func es_dir(v: Array) -> Vector3:
	return Vector3(float(v[0]), float(v[2]), -float(v[1]))


static func tf_to_transform(t: Array) -> Transform3D:
	# rotations (1/65536 turn) about original x, y, z; applied x, then y, then z
	var b := Basis(Vector3.UP, float(t[2]) * ANGLE) \
		* Basis(Vector3.FORWARD, float(t[1]) * ANGLE) \
		* Basis(Vector3.RIGHT, float(t[0]) * ANGLE)
	return Transform3D(b, es_to_godot([t[3], t[4], t[5]]))


func build(p_shape: Dictionary, p_lod := 0, p_palette := "WORLD0") -> void:
	shape = p_shape
	var pack: String = shape.get("pack", Assets.default_pack)
	palette_name = _resolve_palette(p_palette, pack)
	# each pack's world units -> shared metric world (see Packs SCALE POLICY)
	scale = Vector3.ONE * Packs.shape_scale(pack)
	lod = clampi(p_lod, 0, shape.lods.size() - 1)
	for c in get_children():
		c.queue_free()
	nodes.clear()
	_cell_meshes.clear()
	markers.clear()
	_build_nodes()
	var l: Dictionary = shape.lods[lod]
	_init_cells(l.cells)
	var texset := []
	if shape.get("texset") != null and not ServerProfile.is_collision_only():
		texset = Assets.texture_set(Assets.qualify(shape.texset, shape.get("pack", "")))
	for piece in l.pieces:
		_build_piece(piece, texset)


## Indexed textures only look right with a palette from their own game: a palette of another pack
## (or an unqualified one for a non-default pack) is replaced by the pack's default palette.
static func _resolve_palette(p_palette: String, pack: String) -> String:
	var pal := Assets.qualify(p_palette, pack)
	if Assets.split_id(pal)[0] != pack or (p_palette.find(":") < 0 and pack != Assets.default_pack):
		pal = Packs.default_palette(pack)
	return pal


## Node hierarchy with each node at its default transform.
func _build_nodes() -> void:
	var node_list: Array = shape.get("nodes", [])
	for i in node_list.size():
		var n := Node3D.new()
		n.name = "node%d" % i
		nodes.append(n)
	for i in node_list.size():
		var parent: int = int(node_list[i].parent)
		if parent >= 0 and parent < nodes.size():
			nodes[parent].add_child(nodes[i])
		else:
			add_child(nodes[i])
		nodes[i].transform = tf_to_transform(shape.transforms[int(node_list[i].default)])


func _init_cells(cells: Array) -> void:
	_cells = cells
	for c in _cells:
		var states := []
		for s in int(c.states):
			states.append([])
		_cell_meshes.append(states)


## A piece becomes a locator marker or a mesh under its node; cell pieces show only in state 0.
func _build_piece(piece: Dictionary, texset: Array) -> void:
	var node_idx: int = int(piece.node)
	var parent_node: Node3D = nodes[node_idx] if node_idx >= 0 and node_idx < nodes.size() else self
	if MARKER_IDS.has(int(piece.get("id", 0))):
		_add_marker(piece, parent_node)
		return
	var mesh := _build_piece_mesh(piece, texset)
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if RenderUnified.enabled():
		mi.layers |= SceneLighting.UNIFIED_LIT_LAYER
	parent_node.add_child(mi)
	var piece_name := str(piece.get("name", ""))
	if not _piece_meshes.has(piece_name):
		_piece_meshes[piece_name] = []
	(_piece_meshes[piece_name] as Array).append(mi)
	if piece.get("hidden", false):
		_hidden_pieces[piece_name] = true
		mi.visible = false
	var cell: int = int(piece.cell)
	if cell >= 0:
		_cell_meshes[cell][int(piece.state)].append(mi)
		mi.visible = int(piece.state) == 0


func _add_marker(piece: Dictionary, parent_node: Node3D) -> void:
	var c := Vector3.ZERO
	var n := 0
	var normal := Vector3.UP
	for poly in piece.polys:
		normal = es_dir(poly.n).normalized()
		for v in poly.v:
			c += es_to_godot(v)
			n += 1
	var m := Marker3D.new()
	m.name = "mount_%d" % int(piece.id)
	m.position = c / max(n, 1)
	if normal.length() > 0.5 and absf(normal.dot(Vector3.UP)) < 0.99:
		m.basis = Basis.looking_at(-normal, Vector3.UP)
	parent_node.add_child(m)
	markers[int(piece.id)] = m


## Truecolour material (Torque/Tribes 2): texture path in shape.materials[index].texture.
## Torque flags: 4 translucent, 8 additive, 32 self-illuminating.
func _rgba_material(idx: int) -> Material:
	var mats: Array = shape.get("materials", [])
	if idx < 0 or idx >= mats.size():
		return null
	var md: Dictionary = mats[idx]
	var pack: String = shape.get("pack", Assets.default_pack)
	var key := "%s/%s" % [pack, md.get("texture", "")]
	if _rgba_cache.has(key):
		return _rgba_cache[key]
	var mat := StandardMaterial3D.new()
	var img := Assets.load_image(String(md.get("texture", "")), pack)
	if img:
		mat.albedo_texture = ImageTexture.create_from_image(img)
	var flags := int(md.get("flags", 0))
	if String(md.get("name", "")).contains("damage"):
		mat.albedo_color = Color(1, 1, 1, 0)   # damage decals: hidden until damaged
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	elif flags & FLAG_ADDITIVE:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	elif flags & FLAG_TRANSLUCENT:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	if flags & FLAG_SELF_ILLUMINATING:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.roughness = 0.9
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_rgba_cache[key] = mat
	return mat


func _material_for(m: Dictionary, texset: Array) -> Material:
	if ServerProfile.is_collision_only():
		return null   # the server never draws: faces and cells only
	var skinned := _override_material(int(m.index))
	if skinned:
		return skinned
	if RenderUnified.enabled():
		var um := _unified_material(m, texset)
		if um:
			return um
	if m.kind == "rgba":
		var rm := _rgba_material(int(m.index))
		if rm:
			return rm
	var tkey := "%s/%s" % [shape.get("pack"), shape.get("texset")] if m.kind == "tex" else ""
	var pal := _tex_palette(int(m.index)) if m.kind == "tex" else palette_name
	return Palette.material(pal, m, tkey, texset)


## The shared material (UnifiedMaterial) for a polygon colour; null when the prototype leaves it to the game's own path.
func _unified_material(m: Dictionary, texset: Array) -> Material:
	var pack: String = shape.get("pack", Assets.default_pack)
	if m.kind == "rgba":
		var mats: Array = shape.get("materials", [])
		var idx := int(m.index)
		return UnifiedMaterial.from_rgba(pack, mats[idx]) if idx >= 0 and idx < mats.size() else null
	var tkey := "%s/%s" % [shape.get("pack"), shape.get("texset")] if m.kind == "tex" else ""
	var pal := _tex_palette(int(m.index)) if m.kind == "tex" else palette_name
	return UnifiedMaterial.from_palette(pal, m, tkey, texset)


## The skin's material for material `idx` (texture_overrides), null when the skin leaves it alone.
func _override_material(idx: int) -> Material:
	if texture_overrides.is_empty():
		return null
	var mats: Array = shape.get("materials", [])
	if idx < 0 or idx >= mats.size():
		return null
	var md: Dictionary = mats[idx]
	var file := str(md.get("file", md.get("name", ""))).to_lower()
	if not texture_overrides.has(file):
		return null
	var pack: String = shape.get("pack", Assets.default_pack)
	if RenderUnified.enabled():
		var um := UnifiedMaterial.from_texture(pack, str(texture_overrides[file]), int(md.get("flags", 0)))
		if um:
			return um
	var key := "%s/%s" % [pack, texture_overrides[file]]
	if not _rgba_cache.has(key):
		var mat := StandardMaterial3D.new()
		var img := Assets.load_image(str(texture_overrides[file]), pack)
		if img:
			mat.albedo_texture = ImageTexture.create_from_image(img)
		mat.roughness = 0.9
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_rgba_cache[key] = mat
	return _rgba_cache[key]


## Palette for an indexed texture: its own PiDX palette (Darkstar texture-set metadata), moved to
## the current world when one is set; falls back to the shape's palette.
func _tex_palette(idx: int) -> String:
	var pack: String = shape.get("pack", Assets.default_pack)
	var mk := "%s/%s" % [pack, shape.get("texset", "")]
	if not _texmeta.has(mk):
		_texmeta[mk] = Assets.load_json("textures/%s.json" % shape.get("texset", ""), pack) if shape.get("texset") else null
	var meta = _texmeta[mk]
	if not (meta is Array) or idx >= meta.size() or not (meta[idx] is Dictionary) or not (meta[idx].get("palette") is String):
		return palette_name
	var pname: String = meta[idx].palette
	var world: String = world_palettes.get(pack, "")
	if world != "":
		var cut := pname.rfind("_")
		var cand := world + pname.substr(cut) if cut > 0 else pname
		if _palette_exists(pack, cand):
			return "%s:%s" % [pack, cand]
	return "%s:%s" % [pack, pname] if _palette_exists(pack, pname) else palette_name


static func _palette_exists(pack: String, pname: String) -> bool:
	var k := pack + ":" + pname
	if not _pal_exists.has(k):
		_pal_exists[k] = FileAccess.file_exists(Assets.path("palettes/%s.json" % pname, pack))
	return _pal_exists[k]


func _build_piece_mesh(piece: Dictionary, texset: Array) -> ArrayMesh:
	var groups := _polys_by_material(piece.polys)
	if groups.is_empty():
		return null
	var mesh := ArrayMesh.new()
	for key in groups:
		var g: Dictionary = groups[key]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var textured: bool = g.m.kind == "tex" or g.m.kind == "rgba"
		for poly in g.polys:
			_add_polygon(st, poly, textured)
		st.set_material(_material_for(g.m, texset))
		st.commit(mesh)
	return mesh


## "kind:index" -> {m: material ref, polys: [...]}, in first-use order (one surface per material).
static func _polys_by_material(polys: Array) -> Dictionary:
	var groups := {}
	for poly in polys:
		if not is_drawn(poly):
			continue
		var m: Dictionary = poly.m
		var key := "%s:%d" % [m.kind, int(m.index)]
		if not groups.has(key):
			groups[key] = {"m": m, "polys": []}
		groups[key].polys.append(poly)
	return groups


## False for polygons the original engine never draws (see UNDRAWN_POLY_TYPE).
static func is_drawn(poly: Dictionary) -> bool:
	return poly.get("t", "") != UNDRAWN_POLY_TYPE


## A two-vertex 3Space polygon is a line (the rails of the particle-beam guns MECHWPNS 2 / 4 / 13 that
## join the gun body to its tip, antennas, wires): drawn as a thin square tube so it keeps its depth and
## shading (the original draws it one pixel wide).
static func _add_line(st: SurfaceTool, a: Vector3, b: Vector3, textured: bool) -> void:
	var axis := b - a
	if axis.is_zero_approx():
		return
	var side := axis.cross(Vector3.UP if absf(axis.normalized().y) < 0.9 else Vector3.RIGHT).normalized()
	var up := side.cross(axis).normalized()
	var half := LINE_WIDTH_UNITS * Assets.UNIT * 0.5
	var ring: Array[Vector3] = [(side + up) * half, (up - side) * half, (-side - up) * half, (side - up) * half]
	for k in ring.size():
		var p: Vector3 = ring[k]
		var q: Vector3 = ring[(k + 1) % ring.size()]
		var n := (p + q).normalized()
		for tri in [[a + p, b + p, b + q], [a + p, b + q, a + q]]:
			if (tri[1] - tri[0]).cross(tri[2] - tri[0]).dot(n) > 0.0:
				tri.reverse()
			for v in tri:
				st.set_normal(n)
				if textured:
					st.set_uv(Vector2.ZERO)
				st.add_vertex(v)


## Triangle fan of one polygon, wound clockwise (Godot front faces) relative to its normal.
static func _add_polygon(st: SurfaceTool, poly: Dictionary, textured: bool) -> void:
	var n := es_dir(poly.n).normalized()
	var pts: Array[Vector3] = []
	for v in poly.v:
		pts.append(es_to_godot(v))
	if pts.size() == 2:
		_add_line(st, pts[0], pts[1], textured)
		return
	if pts.size() < 3:
		return
	var uvs := QUAD_UVS.duplicate()
	if poly.has("uv"):
		# explicit texture coordinates (Darkstar/Torque shapes) instead of 3Space quad corners
		uvs.clear()
		for t in poly.uv:
			uvs.append(Vector2(float(t[0]), float(t[1])))
	var lightmap_uvs := _make_lightmap_uvs(poly)
	var flip := (pts[1] - pts[0]).cross(pts[2] - pts[0]).dot(n) > 0.0
	for k in range(1, pts.size() - 1):
		for idx in ([0, k + 1, k] if flip else [0, k, k + 1]):
			st.set_normal(n)
			if textured:
				st.set_uv(uvs[idx] if idx < uvs.size() else Vector2.ZERO)
			if not lightmap_uvs.is_empty():
				st.set_uv2(lightmap_uvs[idx] if idx < lightmap_uvs.size() else Vector2.ZERO)
			st.add_vertex(pts[idx])


## The lightmap coordinates of a polygon ("uv2": Tribes: Vengeance BSP surfaces), empty when it has none.
static func _make_lightmap_uvs(poly: Dictionary) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for t in poly.get("uv2", []):
		out.append(Vector2(float(t[0]), float(t[1])))
	return out


## Collision-only faces of the built LOD (a piece's "collision_polys": Torque interiors' null surfaces, never drawn)
## as triangle vertices in `space`'s coordinates.
func make_collision_faces(space: Node3D) -> PackedVector3Array:
	var faces := PackedVector3Array()
	if shape.is_empty():
		return faces
	var to_space := space.global_transform.affine_inverse()
	for piece in shape.lods[lod].pieces:
		var node_idx := int(piece.node)
		var node: Node3D = nodes[node_idx] if node_idx >= 0 and node_idx < nodes.size() else self
		var xf := to_space * node.global_transform
		for poly in piece.get("collision_polys", []):
			for v in poly.v:
				faces.append(xf * es_to_godot(v))
	return faces


# ------------------------------------------------------------------ cells

## Lowest point of the visible geometry in this instance's space (to stand shapes on the ground).
func lowest_point() -> float:
	var low := INF
	for mi in find_children("*", "MeshInstance3D", true, false):
		if not mi.is_visible_in_tree():
			continue
		var aabb: AABB = mi.mesh.get_aabb()
		var xf: Transform3D = global_transform.affine_inverse() * mi.global_transform
		for k in 8:
			low = minf(low, (xf * aabb.get_endpoint(k)).y)
	return 0.0 if low == INF else low


func cell_count() -> int:
	return _cells.size()


## Sets every cell whose slot matches to the given state (0 = intact).
func set_slot_state(slot: int, state: int) -> void:
	for ci in _cells.size():
		if int(_cells[ci].slot) == slot:
			set_cell_state(ci, state)


func set_cell_state(ci: int, state: int) -> void:
	var states: Array = _cell_meshes[ci]
	state = clampi(state, 0, states.size() - 1)
	_cell_state[ci] = state
	for s in states.size():
		for mi in states[s]:
			mi.visible = s == state and not _hidden_cells.has(ci)


## State cell ci shows (0 = intact).
func get_cell_state(ci: int) -> int:
	return int(_cell_state.get(ci, 0))


## Damage slot of cell ci (the DMG component's shape_part; -1 when unknown).
func get_cell_slot(ci: int) -> int:
	return int(_cells[ci].get("slot", -1)) if ci >= 0 and ci < _cells.size() else -1


## Cell index of every cell mesh (MeshInstance3D -> cell index), e.g. for per-part damage overlays.
func make_cell_of_meshes() -> Dictionary:
	var out := {}
	for ci in _cell_meshes.size():
		for state in _cell_meshes[ci]:
			for mi in state:
				out[mi] = ci
	return out


## True when some state of cell ci is drawn.
func is_cell_drawn(ci: int) -> bool:
	for state in _cell_meshes[ci]:
		for mi in state:
			if (mi as MeshInstance3D).visible:
				return true
	return false


## Hides cell ci in every state (e.g. a Battledrome pod replaced by another game's weapon), or shows
## its current state again.
func set_cell_hidden(ci: int, hidden: bool) -> void:
	if ci < 0 or ci >= _cell_meshes.size():
		return
	if hidden:
		_hidden_cells[ci] = true
	else:
		_hidden_cells.erase(ci)
	set_cell_state(ci, int(_cell_state.get(ci, 0)))


# ------------------------------------------------------------------ animation

func sequence_count() -> int:
	return shape.get("sequences", []).size()


func play(index: int, p_loop := true) -> void:
	if index < 0 or index >= sequence_count():
		playing = false
		return
	seq_index = index
	seq_time = 0.0
	loop = p_loop
	playing = true
	_apply_pose()


func stop() -> void:
	playing = false


func reset_pose() -> void:
	for i in nodes.size():
		nodes[i].transform = tf_to_transform(shape.transforms[int(shape.nodes[i].default)])
	for piece_name in _hidden_pieces:
		set_piece_visible(piece_name, false)


## The pieces that start hidden (muzzle flashes and the like; a sequence's visibility track shows them).
func make_hidden_piece_names() -> Array:
	return _hidden_pieces.keys()


## True when any mesh of piece `piece_name` is shown.
func is_piece_visible(piece_name: String) -> bool:
	return (_piece_meshes.get(piece_name, []) as Array).any(func(mi) -> bool: return (mi as MeshInstance3D).visible)


## Shows or hides the meshes of piece (Torque object) `piece_name`.
func set_piece_visible(piece_name: String, on: bool) -> void:
	for mi in _piece_meshes.get(piece_name, []):
		(mi as MeshInstance3D).visible = on


func _process(delta: float) -> void:
	if not playing:
		return
	seq_time += delta
	var seq: Dictionary = shape.sequences[seq_index]
	var length: float = float(seq.tick) * tick_seconds
	if length <= 0.0:
		return
	if seq_time >= length:
		if loop:
			seq_time = fmod(seq_time, length)
		else:
			seq_time = length
			playing = false
	_apply_pose()


func _apply_pose() -> void:
	pose(seq_index, seq_time / tick_seconds, loop)


## Length of a sequence in original ticks.
func sequence_ticks(index: int) -> float:
	return float(shape.sequences[index].tick)


## Applies sequence `index` at position `t` (original ticks) to the nodes it animates.
## Several sequences can be layered by calling pose() for each (later calls win on shared nodes).
func pose(index: int, t: float, wrap := true) -> void:
	if index < 0 or index >= sequence_count():
		return
	var seq: Dictionary = shape.sequences[index]
	var frames: Array = seq.frames
	var parts: Array = seq.parts
	var nparts := parts.size()
	if frames.is_empty() or nparts == 0:
		return
	var total := 0.0
	for f in frames:
		total += float(f[0])
	if wrap:
		t = fposmod(t, total)
	else:
		t = clampf(t, 0.0, total)
	var acc := 0.0
	var fi := 0
	var frac := 0.0
	for i in frames.size():
		var ft := float(frames[i][0])
		if t < acc + ft or i == frames.size() - 1:
			fi = i
			frac = clampf((t - acc) / maxf(ft, 1.0), 0.0, 1.0)
			break
		acc += ft
	var fj := (fi + 1) % frames.size()
	if not wrap and fi == frames.size() - 1:
		fj = fi
	for p in nparts:
		var node_idx: int = int(parts[p])
		if node_idx < 0 or node_idx >= nodes.size():
			continue
		var a := tf_to_transform(shape.transforms[int(seq.tf[fi * nparts + p])])
		if interpolate and fj != fi and frac > 0.0:
			var b := tf_to_transform(shape.transforms[int(seq.tf[fj * nparts + p])])
			a = a.interpolate_with(b, frac)
		nodes[node_idx].transform = a

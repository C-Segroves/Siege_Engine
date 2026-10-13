class_name ES2WorldBuilder
extends RefCounted
## Builds the static world of an Earthsiege 2 mission (pack "es2"; docs/formats/es2.md section 3;
## data from tools/export_es2_world.py): banded sky, terrain haze, the zone's heightmap terrain
## (MapTerrain, padded with edge-clamped heights) shaded like DBSIM's textured ground, and a safety floor.

const PACK := "es2"
## Metres of edge-clamped terrain added around an ES2 heightmap (the original draws nothing outside
## the grid; this only hides the edge and keeps strays on solid ground).
const PAD_M := 2048.0
const MIN_PAD_SQUARES := 4
const MAX_PAD_SQUARES := 64
## Safety floor under ES2 terrain (lowest exported terrain is ~11 m above 0).
const FLOOR_Y := -100.0
const DEFAULT_HAZE := [117, 113, 97]
const DEFAULT_SUN := [-0.7582, -0.3593, -0.544]
## Haze distances (original units) when the world file has none.
const DEFAULT_FOG_BEGIN_UNITS := 60000.0
const DEFAULT_FOG_END_UNITS := 126000.0
const AMBIENT := Color(0.5, 0.5, 0.5)
## Full haze at the far threshold (depth fog density 1).
const FOG_DENSITY := 1.0
const MISSING_TEXTURE_COLOUR := Color(0.45, 0.42, 0.36)
const TERRAIN_TEXTURES := 2
## The terrain shader's light curve has this many entries.
const LIGHT_CURVE_SIZE := 32
const DEFAULT_MATERIAL_TILE_M := 128.0
const TERRAIN_SHADER := preload("res://engine/shaders/es2_terrain.gdshader")
const WORLD_COUNT := 10


## ES2 world index from the 10-word script header as the mission compiler emits it
## (mission["header"]["raw"]): DBSIM 0x42e042: n = word0 * 2 + word9
## (word0 = world type 0 urban, 1 bsnow, 2 volcan, 3 ice, 4 moon; word9 = 0 day / 1 night).
static func world_index(header_raw: Array) -> int:
	var t := int(header_raw[0]) if header_raw.size() > 0 else 0
	var tod := int(header_raw[9]) if header_raw.size() > 9 else 0
	return clampi(t * 2 + tod, 0, WORLD_COUNT - 1)


## Returns {"palette", "world", "haze", "terrain"} (terrain: see _build_terrain).
static func build(parent: Node3D, index: int, zone: int) -> Dictionary:
	var w := WorldBuilder.load_world(index, PACK)
	var pal := WorldBuilder.palette_id(w, PACK)
	var hz: Dictionary = w.get("haze", {})
	var haze_rgb: Array = hz.get("terrain_haze_rgb", hz.get("haze_colour_rgb", DEFAULT_HAZE))
	var haze := Color8(int(haze_rgb[0]), int(haze_rgb[1]), int(haze_rgb[2]))
	_build_environment(parent, w, pal, haze_rgb)
	SceneLighting.apply_sun_direction(SceneLighting.make_3space_sun(w.get("light", {}).get("vector_assumed_RzRyRx", DEFAULT_SUN)))
	var tinfo := {}
	if zone >= 0:
		tinfo = _build_terrain(parent, w, zone)
	_build_safety_floor(parent)
	return {"palette": pal, "world": w, "haze": haze, "terrain": tinfo}


static func _build_environment(parent: Node3D, w: Dictionary, pal: String, haze_rgb: Array) -> void:
	var hz: Dictionary = w.get("haze", {})
	# haze: level = #thresholds <= distance, full haze at the last threshold (WLD v2 terrain list)
	SceneLighting.build_palette_environment(parent, {"sky": _sky(w, pal, haze_rgb), "ambient": AMBIENT,
		"haze": Color8(int(haze_rgb[0]), int(haze_rgb[1]), int(haze_rgb[2])), "fog_density": FOG_DENSITY,
		"fog_begin": float(hz.get("fog_begin_units", DEFAULT_FOG_BEGIN_UNITS)) * Assets.UNIT,
		"fog_end": float(hz.get("fog_end_units", DEFAULT_FOG_END_UNITS)) * Assets.UNIT})


## Below the horizon only the fogged terrain edge is ever seen: the terrain haze colour there.
static func _sky(w: Dictionary, pal: String, haze_rgb: Array) -> Sky:
	var wp := w.duplicate()
	var gp: Dictionary = w.get("ground", {}).duplicate()
	gp["band_rgb_near_to_horizon"] = [haze_rgb]
	wp["ground"] = gp
	var sm := PanoramaSkyMaterial.new()
	sm.panorama = ImageTexture.create_from_image(WorldBuilder.make_sky_bands(wp, pal))
	sm.filter = false
	var sky := Sky.new()
	sky.sky_material = sm
	return sky


static func _build_safety_floor(parent: Node3D) -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "SafetyFloor"
	var fcol := CollisionShape3D.new()
	fcol.shape = WorldBoundaryShape3D.new()
	floor_body.add_child(fcol)
	floor_body.position.y = FLOOR_Y
	parent.add_child(floor_body)


## Heightmap terrain of ZONE<zone> (gamedata/es2/terrain/<zone>/terrain.json) through MapTerrain,
## padded by PAD_M of edge-clamped heights. Returns {zone, node, origin, size, square, extent_m, pad_m}.
static func _build_terrain(parent: Node3D, w: Dictionary, zone: int) -> Dictionary:
	var t = Assets.load_json("terrain/%d/terrain.json" % zone, PACK)
	if not (t is Dictionary):
		push_warning("es2 terrain for zone %d not found" % zone)
		return {}
	var dir := Assets.path("terrain/%d" % zone, PACK)
	var w0 := int(t.size[0])
	var h0 := int(t.size[1])
	var sq := float(t.square)
	var src := FileAccess.get_file_as_bytes(dir.path_join(String(t.heights))).to_float32_array()
	if src.size() < w0 * h0:
		push_error("es2 terrain heights short for zone %d" % zone)
		return {}
	var pad := clampi(int(ceil(PAD_M / sq)), MIN_PAD_SQUARES, MAX_PAD_SQUARES)
	MapTerrain.build(parent, _padded_terrain(t, src, pad), dir)
	var body := _terrain_body(parent)
	if body == null:
		return {}
	body.name = "Terrain_%d" % zone
	body.set_meta("es2_grid", {"x0": float(t.origin[0]), "z0": float(t.origin[1]), "w": w0, "h": h0, "sq": sq})
	var mat := _terrain_material(w.get("ground", {}), t, dir)
	for mi in body.get_children():
		if mi is MeshInstance3D:
			mi.material_override = mat
	return {"zone": zone, "node": body, "origin": t.origin, "size": t.size, "square": sq,
		"extent_m": [(w0 - 1) * sq, (h0 - 1) * sq], "pad_m": pad * sq}


## The terrain dict with its heights grown by `pad` squares of edge-clamped heights on each side.
static func _padded_terrain(t: Dictionary, src: PackedFloat32Array, pad: int) -> Dictionary:
	var w0 := int(t.size[0])
	var h0 := int(t.size[1])
	var sq := float(t.square)
	var w1 := w0 + 2 * pad
	var h1 := h0 + 2 * pad
	var hts := PackedFloat32Array()
	hts.resize(w1 * h1)
	for z in h1:
		var sz := clampi(z - pad, 0, h0 - 1) * w0
		for x in w1:
			hts[z * w1 + x] = src[sz + clampi(x - pad, 0, w0 - 1)]
	var tp: Dictionary = t.duplicate()
	tp["size"] = [w1, h1]
	tp["origin"] = [float(t.origin[0]) - pad * sq, float(t.origin[1]) - pad * sq]
	tp["heights_data"] = hts
	tp.erase("albedo")
	return tp


static func _terrain_body(parent: Node3D) -> Node3D:
	var body: Node3D = null
	for c in parent.get_children():
		if c is StaticBody3D and c.is_in_group("terrain"):
			body = c
	return body


## DBSIM-style ground: two material textures picked by the zone's material map, lit by the world's
## light curve.
static func _terrain_material(g: Dictionary, t: Dictionary, dir: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = TERRAIN_SHADER
	var tex_files: Array = g.get("material_textures_png", [])
	for i in TERRAIN_TEXTURES:
		mat.set_shader_parameter("tex%d" % i, ImageTexture.create_from_image(_material_texture(tex_files, i)))
	var mimg := _material_map(dir.path_join(String(t.get("materials", "materials.png"))))
	mat.set_shader_parameter("matmap", ImageTexture.create_from_image(mimg))
	mat.set_shader_parameter("mat_tiles", Vector2(mimg.get_width(), mimg.get_height()))
	mat.set_shader_parameter("tile_m", float(t.get("material_tile_m", DEFAULT_MATERIAL_TILE_M)))
	var curve := PackedFloat32Array()
	for v in g.get("light_curve", []):
		curve.append(float(v))
	while curve.size() < LIGHT_CURVE_SIZE:
		curve.append(1.0)
	mat.set_shader_parameter("light_curve", curve)
	return mat


static func _material_texture(tex_files: Array, i: int) -> Image:
	var img: Image = Assets.load_image("worlds/%s" % tex_files[i], PACK) if i < tex_files.size() else null
	if img == null:
		img = Image.create(1, 1, false, Image.FORMAT_RGB8)
		img.fill(MISSING_TEXTURE_COLOUR)
	img.generate_mipmaps()
	return img


## Material map stored 0/1 -> spread to 0/255 so the shader can threshold the normalised value.
static func _material_map(path: String) -> Image:
	var mimg := Image.load_from_file(path)
	if mimg == null:
		mimg = Image.create(1, 1, false, Image.FORMAT_L8)
	mimg.convert(Image.FORMAT_L8)
	for y in mimg.get_height():
		for x in mimg.get_width():
			mimg.set_pixel(x, y, Color(1, 1, 1) if mimg.get_pixel(x, y).r > 0.0 else Color(0, 0, 0))
	return mimg

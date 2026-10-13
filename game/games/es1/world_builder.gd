class_name WorldBuilder
extends RefCounted
## Builds the static world for an Earthsiege world index (terrain type x time of day) and zone:
## sky (colour bands + distant mountain strips), hazed ground texture, fog and terrain features.

## Original screen pixels per degree of view (used for sky bands / mountain strips).
const DEG_PER_PX := 0.3
const PANORAMA_W := 2048
const PANORAMA_H := 1024
## The mountain strips span this many original pixels around 360 degrees.
const STRIPS_TOTAL_PX := 1280.0
const DEFAULT_ZENITH := [120, 150, 200]
const DEFAULT_HAZE := [200, 190, 160]
const DEFAULT_SUN := [-0.5364, -0.4802, -0.694]
## Haze thresholds (original units): fog starts at the first, ends FOG_END_FACTOR x the last.
const DEFAULT_OBJECT_THRESHOLDS := [30000, 57000]
const FOG_END_FACTOR := 3.0
const AMBIENT := Color(0.5, 0.5, 0.5)
const GROUND_PLANE_SIZE := Vector2(16000, 16000)
## The ground shader takes 15 haze band distances.
const HAZE_BANDS := 15
const DEFAULT_TEXEL_UNITS := 256.0
const GROUND_SHADER := preload("res://engine/shaders/ground.gdshader")


static func load_world(index: int, pack := "es1") -> Dictionary:
	var j = Assets.load_json("worlds/world%d.json" % index, pack)
	return j if j != null else {}


static func palette_id(w: Dictionary, pack := "es1") -> String:
	return "%s:%s" % [pack, String(w.get("palette_file", "WORLD0.DPL")).get_basename()]


static func build(parent: Node3D, world_index: int, zone := -1, pack := "es1") -> Dictionary:
	if pack == "es2":
		return ES2WorldBuilder.build(parent, world_index, zone)
	var w := load_world(world_index, pack)
	var pal := palette_id(w, pack)
	var haze_rgb: Array = w.get("haze", {}).get("haze_colour_rgb", DEFAULT_HAZE)
	var haze := Color8(int(haze_rgb[0]), int(haze_rgb[1]), int(haze_rgb[2]))
	_build_environment(parent, w, pal, pack, haze)
	# original: one fixed directional light
	SceneLighting.apply_sun_direction(SceneLighting.make_3space_sun(w.get("light", {}).get("vector_assumed_RzRyRx", DEFAULT_SUN)))
	_build_ground(parent, w, pal, pack)
	if zone >= 0:
		place_zone(parent, zone, pal, pack)
	return {"palette": pal, "world": w, "haze": haze}


static func _build_environment(parent: Node3D, w: Dictionary, pal: String, pack: String, haze: Color) -> void:
	var sm := PanoramaSkyMaterial.new()
	var img := make_sky_bands(w, pal)
	_add_mountain_strips(img, pal, pack)
	sm.panorama = ImageTexture.create_from_image(img)
	sm.filter = false
	var sky := Sky.new()
	sky.sky_material = sm
	var objs: Array = w.get("haze", {}).get("object_thresholds", DEFAULT_OBJECT_THRESHOLDS)
	SceneLighting.build_palette_environment(parent, {"sky": sky, "ambient": AMBIENT, "haze": haze,
		"fog_begin": float(objs[0]) * Assets.UNIT, "fog_end": float(objs[-1]) * Assets.UNIT * FOG_END_FACTOR})


## Sky panorama (PANORAMA_W x PANORAMA_H, horizon in the middle): sky colour bands above the
## horizon, ground bands below, each band `band_px` original screen pixels high.
static func make_sky_bands(w: Dictionary, pal: String) -> Image:
	var img := Image.create(PANORAMA_W, PANORAMA_H, false, Image.FORMAT_RGB8)
	var sky: Dictionary = w.get("sky", {})
	var bands: Array = sky.get("band_rgb_top_to_horizon", [])
	var zen: Array = sky.get("zenith_rgb", DEFAULT_ZENITH)
	var gbands: Array = w.get("ground", {}).get("band_rgb_near_to_horizon", [])
	var band_px := float(sky.get("band_px", 1)) * DEG_PER_PX * _px_per_degree()
	var horizon := PANORAMA_H / 2
	for y in PANORAMA_H:
		var c: Array = zen
		if y >= horizon:
			c = _ground_band(gbands, int((y - horizon) / maxf(band_px, 0.5)), zen)
		else:
			var k := int((horizon - 1 - y) / maxf(band_px, 0.5))
			if k < bands.size():
				c = bands[bands.size() - 1 - k]
		img.fill_rect(Rect2i(0, y, PANORAMA_W, 1), Color8(int(c[0]), int(c[1]), int(c[2])))
	return img


static func _px_per_degree() -> float:
	return float(PANORAMA_H) / 180.0


## Ground band k below the horizon (counted from the horizon); the nearest band beyond the list.
static func _ground_band(gbands: Array, k: int, zen: Array) -> Array:
	if gbands.is_empty():
		return zen
	return gbands[gbands.size() - 1 - k] if k < gbands.size() else gbands[0]


## Distant mountain strips (the world palette's texture set): 4 x 320 original px cover 360 degrees,
## sitting on the horizon; palette index 0 is transparent.
static func _add_mountain_strips(img: Image, pal: String, pack: String) -> void:
	var strips := Assets.texture_set("%s:%s" % [pack, pal.split(":")[1]])
	if strips.is_empty():
		return
	var palette: Array = Assets.palette(pal)
	var sx := float(PANORAMA_W) / STRIPS_TOTAL_PX
	var sy := DEG_PER_PX * _px_per_degree()
	var horizon := PANORAMA_H / 2
	var x0 := 0.0
	for t in strips:
		var simg: Image = t.get_image()
		var sw := simg.get_width()
		var sh := simg.get_height()
		for py in int(sh * sy):
			var ry := int(py / sy)
			var y := horizon - int(sh * sy) + py
			for px in int(sw * sx):
				var idx := int(round(simg.get_pixel(int(px / sx), ry).r * 255.0))
				if idx == 0:
					continue
				var c: Array = palette[idx]
				img.set_pixel(int(x0 + px) % PANORAMA_W, y, Color8(int(c[0]), int(c[1]), int(c[2])))
		x0 += sw * sx


static func _build_ground(parent: Node3D, w: Dictionary, pal: String, pack: String) -> void:
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var gcol := CollisionShape3D.new()
	gcol.shape = WorldBoundaryShape3D.new()
	ground.add_child(gcol)
	var gm := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = GROUND_PLANE_SIZE
	gm.mesh = plane
	var g: Dictionary = w.get("ground", {})
	var tex_name := String(g.get("texture", "trenches.64k")).get_basename().to_upper()
	var img := Assets.load_image("textures/ground/%s.png" % tex_name, pack)
	var n := String(pal.split(":")[1]).trim_prefix("WORLD")
	var lut := Assets.load_image("worlds/groundlut_%s.png" % n, pack)
	if img and lut:
		img.convert(Image.FORMAT_L8)
		lut.convert(Image.FORMAT_L8)
		var sm := ShaderMaterial.new()
		sm.shader = GROUND_SHADER
		sm.set_shader_parameter("index_tex", ImageTexture.create_from_image(img))
		sm.set_shader_parameter("palette", Assets.palette_texture(pal))
		sm.set_shader_parameter("ground_lut", ImageTexture.create_from_image(lut))
		var dists := PackedFloat32Array()
		for d in g.get("haze_band_distances", []):
			dists.append(float(d) * Assets.UNIT)
		while dists.size() < HAZE_BANDS:
			dists.append(1e9)
		sm.set_shader_parameter("band_dist", dists)
		sm.set_shader_parameter("texel_size", float(g.get("texel_world_units", DEFAULT_TEXEL_UNITS)) * Assets.UNIT)
		gm.material_override = sm
	ground.add_child(gm)
	parent.add_child(ground)


## Places the terrain features of an original zone file.
static func place_zone(parent: Node3D, zone: int, pal: String, pack := "es1") -> void:
	var z = Assets.load_json("zones/%d.json" % zone, pack)
	if z == null:
		return
	var terr := String(z.get("terrain", "desert")).to_upper()
	for o in z.get("objects", []):
		var sid := "%s:%s_%d" % [pack, terr, int(o.shape)]
		var r: Array = o.get("rot", [0, 0, 0])
		var p: Array = o.pos
		var xf := ShapeInstance.tf_to_transform([r[0], r[1], r[2], p[0], p[1], p[2]])
		place_static(parent, sid, xf, pal)


## Places a static shape (terrain feature or building) with mesh collision.
static func place_static(parent: Node3D, shape_id: String, xf: Transform3D, pal: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = shape_id.replace(":", "_")
	body.transform = xf
	parent.add_child(body)
	var inst := ShapeInstance.new()
	body.add_child(inst)
	inst.build(Assets.shape(shape_id), 0, pal)
	var faces := PackedVector3Array()
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		if not mi.visible:
			continue
		var mxf: Transform3D = body.global_transform.affine_inverse() * mi.global_transform
		for v in mi.mesh.get_faces():
			faces.append(mxf * v)
	faces.append_array(inst.make_collision_faces(body))   # undrawn faces that close the hulls (Torque null surfaces)
	if faces.size() >= 3:
		var cs := ConcavePolygonShape3D.new()
		cs.backface_collision = true
		cs.set_faces(faces)
		var col := CollisionShape3D.new()
		col.shape = cs
		body.add_child(col)
	return body


# ------------------------------------------------------------------ Earthsiege 2 (see ES2WorldBuilder)

## ES2 world index from the mission header words (see ES2WorldBuilder.world_index).
static func es2_world_index(header_raw: Array) -> int:
	return ES2WorldBuilder.world_index(header_raw)


## Terrain height (metres, engine y) at an engine position: heightmap (group "terrain") if p lies on
## it, else 0 (ES1 flat ground plane / outside an ES2 grid).
static func ground_height(parent: Node3D, p: Vector3) -> float:
	if parent == null or not parent.is_inside_tree():
		return 0.0
	for t in parent.get_tree().get_nodes_in_group("terrain"):
		var d: Dictionary = t.get_meta("terrain", {})
		if d.is_empty():
			continue
		var fx := (p.x - float(d.x0)) / float(d.sq)
		var fz := (p.z - float(d.z0)) / float(d.sq)
		if fx >= 0.0 and fz >= 0.0 and fx <= int(d.w) - 1 and fz <= int(d.h) - 1:
			return MapBuilder.ground_height(parent, p)
	return 0.0

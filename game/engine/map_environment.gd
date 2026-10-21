class_name MapEnvironment
extends RefCounted
## Environment of the engine map schema (docs/formats/map_schema.md "environment"): background
## colour, skybox cubemap or Darkstar panel sky (engine/darkstar_sky.gd), ambient light, depth fog, the
## sun (a shadowed directional light plus the global "sun_dir" shader parameter) and falling snow or
## rain (engine/map_weather.gd).

## Godot cubemap layer order: +X right, -X left, +Y top, -Y bottom, +Z back, -Z front.
const SKYBOX_FACES := ["right", "left", "top", "bottom", "back", "front"]
## Layout of the six face images. "cube": already in Godot's cubemap orientation (the Tribes AA baker writes these).
## "torque": the pictures as a Torque sky material list shows them, each as seen from inside the box looking at it
## (Tribes 2: sky_<face>.png exported untouched). A map says "torque" with skybox_layout, or by naming its skybox_source.
const LAYOUT_CUBE := "cube"
const LAYOUT_TORQUE := "torque"
const SKYBOX_SHADER := preload("res://engine/shaders/skybox.gdshader")
const DARKSTAR_SKY := preload("res://engine/darkstar_sky.gd")
const DEFAULT_SKY := [140, 160, 190]
const DEFAULT_AMBIENT := [120, 120, 120]
const DEFAULT_FOG := [160, 160, 170]
const DEFAULT_FOG_START := 300.0
const DEFAULT_FOG_END := 1500.0
const DEFAULT_SUN_DIR := [-0.4, -0.8, -0.4]
const DEFAULT_SUN := [255, 250, 235]
const SUN_SHADOW_DISTANCE := 500.0


## Adds the WorldEnvironment and the sun to `parent`. dir: the map folder (skybox images).
static func build(parent: Node3D, e: Dictionary, dir := "") -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = make_color(e.get("horizon_color", e.get("sky_color", DEFAULT_SKY)))
	var draws := not ServerProfile.is_collision_only()
	var faces = e.get("skybox_faces")
	if draws and faces is Dictionary and dir != "":
		var sky := _skybox(faces, dir, make_skybox_layout(e))
		if sky:
			env.sky = sky
			env.background_mode = Environment.BG_SKY
	if draws and e.get("darkstar_sky") is Dictionary:
		_apply_darkstar_sky(env, e, dir)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = make_color(e.get("ambient", DEFAULT_AMBIENT))
	env.fog_enabled = e.has("fog_color")
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = make_color(e.get("fog_color", DEFAULT_FOG))
	env.fog_depth_begin = float(e.get("fog_start", DEFAULT_FOG_START))
	env.fog_depth_end = float(e.get("fog_end", DEFAULT_FOG_END))
	env.fog_sky_affect = float(e.get("fog_sky_affect", env.fog_sky_affect))   # < 1 keeps a skybox visible through the fog
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var env_node := WorldEnvironment.new()
	env_node.environment = env
	parent.add_child(env_node)
	_add_sun(parent, e)
	if draws:
		_add_weather(parent, e)


## Darkstar panel sky; it draws its own haze toward the fog colour, so depth fog leaves it alone.
static func _apply_darkstar_sky(env: Environment, e: Dictionary, dir: String) -> void:
	var fog := make_color(e.get("fog_color", e.get("horizon_color", DEFAULT_FOG)))
	env.sky = DARKSTAR_SKY.make_sky(e.darkstar_sky, fog, dir)
	env.background_mode = Environment.BG_SKY
	env.fog_sky_affect = 0.0


## LAYOUT_TORQUE or LAYOUT_CUBE: how the face images of environment `e` are oriented.
static func make_skybox_layout(e: Dictionary) -> String:
	return str(e.get("skybox_layout", LAYOUT_TORQUE if e.has("skybox_source") else LAYOUT_CUBE))


## Turns the picture of `face` as seen from inside the box into the orientation of a Godot cubemap layer. Godot samples
## a layer the OpenGL way (+X: u runs toward -Z, +Y: v runs toward -Z ...), so a side picture is mirrored left to right
## and the top one top to bottom; the bottom of a Torque sky is a flat colour and needs nothing.
static func apply_torque_orientation(img: Image, face: String) -> void:
	if face == "top":
		img.flip_y()
	elif face != "bottom":
		img.flip_x()


## Cubemap sky from the six face images; null if any is missing.
static func _skybox(faces: Dictionary, dir: String, layout: String) -> Sky:
	var imgs: Array[Image] = []
	for k in SKYBOX_FACES:
		var img := Image.load_from_file(dir.path_join(String(faces.get(k, ""))))
		if img == null:
			return null
		img.convert(Image.FORMAT_RGB8)
		if layout == LAYOUT_TORQUE:
			apply_torque_orientation(img, k)
		if not imgs.is_empty() and img.get_size() != imgs[0].get_size():
			img.resize(imgs[0].get_width(), imgs[0].get_height())
		imgs.append(img)
	var cube := Cubemap.new()
	cube.create_from_images(imgs)
	var sm := ShaderMaterial.new()
	sm.shader = SKYBOX_SHADER
	sm.set_shader_parameter("sky_cube", cube)
	var sky := Sky.new()
	sky.sky_material = sm
	return sky


static func _add_weather(parent: Node3D, e: Dictionary) -> void:
	if not e.get("weather") is Dictionary:
		return
	var weather := MapWeather.make(e.weather)
	if weather:
		parent.add_child(weather)


static func _add_sun(parent: Node3D, e: Dictionary) -> void:
	var sun := DirectionalLight3D.new()
	var d: Array = e.get("sun_dir", DEFAULT_SUN_DIR)
	var sdir := Vector3(float(d[0]), float(d[1]), float(d[2])).normalized()
	parent.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, sdir, Vector3.UP if absf(sdir.y) < 0.99 else Vector3.RIGHT)
	sun.light_color = make_color(e.get("sun_color", DEFAULT_SUN))
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = SUN_SHADOW_DISTANCE
	SceneLighting.apply_sun_direction(sdir)
	SceneLighting.apply_scene_light(sun.light_color, make_color(e.get("ambient", DEFAULT_AMBIENT)), true)


## Map colour [r, g, b]: 0..255 unless every component is a fraction in 0..1 (e.g. Tribes 2);
## all-integer 0/1 triples such as [0, 0, 1] are 0..255 (near-black).
static func make_color(c) -> Color:
	if not (c is Array and c.size() >= 3):
		return Color(0.5, 0.5, 0.5)
	var k := 1.0 if _is_fraction_triple(c) else 255.0
	return Color(float(c[0]) / k, float(c[1]) / k, float(c[2]) / k)


static func _is_fraction_triple(c: Array) -> bool:
	var all_integer := true
	for i in 3:
		var v := float(c[i])
		if v > 1.0 or (v != 0.0 and v != 1.0 and v == floorf(v)):
			return false
		if v != floorf(v):
			all_integer = false
	return not (all_integer and float(c[0]) + float(c[1]) + float(c[2]) <= 1.0)

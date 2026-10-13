class_name DarkstarSky
extends RefCounted
## Sky of the Darkstar games (Starsiege: Tribes, Starsiege) from the map schema
## "environment.darkstar_sky" (docs/formats/map_schema.md; geometry and evidence in tools/darkstar_sky.py):
## a ring of 16 sky panels, flat-coloured cones above/below, billboard planets and an optional star field.

const SHADER := preload("res://engine/shaders/darkstar_sky.gdshader")
const MAX_PLANETS := 4
const PLANET_SLOTS := ["planet_0", "planet_1", "planet_2", "planet_3"]
## Shader star_mode values.
const STARS_NONE := 0
const STARS_BEHIND := 1
const STARS_IN_FRONT := 2


## Sky resource for `sky` (the darkstar_sky dictionary); dir: the map folder with the sky images.
static func make_sky(sky: Dictionary, fog_color: Color, dir: String) -> Sky:
	var sm := ShaderMaterial.new()
	sm.shader = SHADER
	_apply_ring(sm, sky, fog_color, dir)
	_apply_planets(sm, sky.get("planets", []), dir)
	_apply_stars(sm, sky.get("stars"))
	var out := Sky.new()
	out.sky_material = sm
	out.process_mode = Sky.PROCESS_MODE_QUALITY
	return out


static func _apply_ring(sm: ShaderMaterial, sky: Dictionary, fog_color: Color, dir: String) -> void:
	sm.set_shader_parameter("first_corner", deg_to_rad(float(sky.get("first_corner_deg", 67.5))))
	sm.set_shader_parameter("panel_step", deg_to_rad(float(sky.get("panel_deg", 22.5))))
	sm.set_shader_parameter("band_bottom", float(sky.get("band_bottom", -0.1)))
	sm.set_shader_parameter("band_top", float(sky.get("band_top", 0.6)))
	sm.set_shader_parameter("top_color", MapEnvironment.make_color(sky.get("top_color")))
	sm.set_shader_parameter("fog_color", fog_color)
	# Untextured skies show the screen clear colour (the haze) between the cones (tribes.exe 0x4736f3).
	sm.set_shader_parameter("band_color", fog_color)
	var panels := _load_texture(dir, sky.get("panels"))
	sm.set_shader_parameter("has_panels", panels != null)
	if panels:
		sm.set_shader_parameter("panels", panels)


static func _apply_planets(sm: ShaderMaterial, planets: Array, dir: String) -> void:
	var dirs := PackedVector4Array()
	for p in planets:
		var tex := _load_texture(dir, p.get("image"))
		if tex == null or dirs.size() >= MAX_PLANETS:
			continue
		var d: Array = p.get("dir", [0, 1, 0])
		var radius := deg_to_rad(float(p.get("radius_deg", 2.0)))
		sm.set_shader_parameter(PLANET_SLOTS[dirs.size()], tex)
		dirs.append(Vector4(float(d[0]), float(d[1]), float(d[2]), tan(radius)))
	sm.set_shader_parameter("planet_count", dirs.size())
	dirs.resize(MAX_PLANETS)
	sm.set_shader_parameter("planet_dir_tan", dirs)


static func _apply_stars(sm: ShaderMaterial, stars) -> void:
	if not stars is Dictionary:
		sm.set_shader_parameter("star_mode", STARS_NONE)
		return
	var colors := PackedVector3Array()
	for c in stars.get("colors", []):
		var col := MapEnvironment.make_color(c)
		colors.append(Vector3(col.r, col.g, col.b))
	colors.resize(3)
	sm.set_shader_parameter("star_colors", colors)
	sm.set_shader_parameter("star_mode", STARS_IN_FRONT if stars.get("in_front", true) else STARS_BEHIND)


static func _load_texture(dir: String, file) -> Texture2D:
	if not file is String or dir == "":
		return null
	var img := Image.load_from_file(dir.path_join(file))
	if img == null:
		push_error("darkstar sky image missing: " + dir.path_join(file))
		return null
	return ImageTexture.create_from_image(img)

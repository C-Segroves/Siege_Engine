class_name SceneLighting
extends RefCounted
## The scene lighting every game's world builder sets up, in one place:
## - the sun: the global shader parameter "sun_dir" (the direction the light travels, world space) that the
##   palette shaders (indexed / shaded / ground) shade with, I = (1 - n.L) / 2 (docs/formats/world.md section 4);
##   the Darkstar maps also add a DirectionalLight3D for their lit materials (MapEnvironment);
## - the 3Space palette environment of Earthsiege 1 and 2: band-panorama sky, flat ambient, linear tone mapping
##   (palette colours stay exact) and depth haze in the world's haze colour.
## Per-game data stays with the game: each builder reads its WLD / arena / map record and hands the values here.


## Sets the direction sunlight travels for every palette shader.
static func apply_sun_direction(travel_dir: Vector3) -> void:
	_sun_travel = travel_dir.normalized()
	RenderingServer.global_shader_parameter_set("sun_dir", _sun_travel)
	if is_instance_valid(_palette_sun):
		_orient(_palette_sun, _sun_travel)


## Render layer (bit 20) of the lit unified meshes. A 3Space palette world's sun only lights this layer, so it
## shades Torque/Darkstar models standing in that world without touching anything else.
const UNIFIED_LIT_LAYER := 1 << 19

static var _sun_travel := Vector3(0, -1, 0)
static var _palette_sun: DirectionalLight3D


static func _orient(light: DirectionalLight3D, travel: Vector3) -> void:
	light.look_at_from_position(Vector3.ZERO, travel, Vector3.UP if absf(travel.y) < 0.99 else Vector3.RIGHT)

## Publishes the scene's light to the shared material (UnifiedMaterial): sun and ambient colour for lambert-lit
## models, and whether the scene's tone map is FILMIC (the material then undoes it).
static func apply_scene_light(sun_color: Color, ambient: Color, filmic: bool) -> void:
	RenderingServer.global_shader_parameter_set("scene_sun_color", Vector3(sun_color.r, sun_color.g, sun_color.b))
	RenderingServer.global_shader_parameter_set("scene_ambient", Vector3(ambient.r, ambient.g, ambient.b))
	RenderingServer.global_shader_parameter_set("scene_tonemap", 1 if filmic else 0)


## Sun and ambient of a 3Space palette world, as seen by lambert-lit (Torque) models standing in it.
const PALETTE_WORLD_SUN := Color(0.6, 0.6, 0.6)
const PALETTE_WORLD_AMBIENT := Color(0.4, 0.4, 0.4)


## The engine-space sun of a 3Space WLD light vector (stored as RzRyRx, original x / y / z = engine x / -z / y).
static func make_3space_sun(light_vector: Array) -> Vector3:
	return Vector3(float(light_vector[0]), float(light_vector[2]), -float(light_vector[1])).normalized()


## Adds the 3Space palette environment under `parent`. spec: {sky: Sky, ambient: Color, haze: Color,
## fog_begin: metres, fog_end: metres, fog_density (optional; Godot's default when absent)}.
static func build_palette_environment(parent: Node3D, spec: Dictionary) -> WorldEnvironment:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = spec.sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = spec.ambient
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = spec.haze
	env.fog_sky_affect = 0.0
	env.fog_depth_begin = float(spec.fog_begin)
	env.fog_depth_end = float(spec.fog_end)
	if spec.has("fog_density"):
		env.fog_density = float(spec.fog_density)
	var env_node := WorldEnvironment.new()
	env_node.environment = env
	parent.add_child(env_node)
	apply_scene_light(PALETTE_WORLD_SUN, PALETTE_WORLD_AMBIENT, false)
	add_palette_world_sun(parent)
	return env_node


## The sun of a 3Space palette world for lit (Torque / Darkstar) models standing in it, on the unified lit layer only.
static func add_palette_world_sun(parent: Node3D) -> void:
	if not RenderUnified.enabled():
		return
	_palette_sun = DirectionalLight3D.new()
	_palette_sun.light_color = PALETTE_WORLD_SUN
	_palette_sun.light_energy = 1.0
	_palette_sun.light_cull_mask = UNIFIED_LIT_LAYER
	parent.add_child(_palette_sun)
	_orient(_palette_sun, _sun_travel)


## A plain studio environment for tools and test scenes (shape viewer, line-ups, screenshot sheets): a flat
## background colour, a flat ambient colour when spec has "ambient" (else the background's ambient), at
## "ambient_energy" (default 1).
## spec: {background: Color, ambient: Color (optional), ambient_energy: float (optional)}.
static func add_studio_environment(parent: Node, spec: Dictionary) -> WorldEnvironment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = spec.background
	if spec.has("ambient"):
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = spec.ambient
	env.ambient_light_energy = float(spec.get("ambient_energy", 1.0))
	var node := WorldEnvironment.new()
	node.environment = env
	parent.add_child(node)
	apply_scene_light(Color.WHITE, env.ambient_light_color, false)   # default tone map: linear for the unified material
	return node


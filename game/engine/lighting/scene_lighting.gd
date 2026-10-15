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
	RenderingServer.global_shader_parameter_set("sun_dir", travel_dir.normalized())

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
	return env_node


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
	return node


class_name DayCycleLight
extends Node
## Plays a map's day (environment.day_cycle, DayCycle) on the scene: it turns the sun round the sky and blends the sun and
## moon light, ambient light, background, fog and the sky's tint, stars and sun / moon disc as the day goes by, and
## publishes the same light to the shared materials (SceneLighting). The host owns the clock (the raid's SiteSpawner);
## every peer runs this node on its own clock between the host's updates (apply_clock).
const GROUP := "day_cycle"
const STAR_FULL_AT := -0.18
const APPLY_EVERY_S := 0.1
const SUN_DISC_COS := 0.9996
const MOON_DISC_COS := 0.9992

var look: Dictionary
var timing: Dictionary
var clock_s := 0.0
var _env: Environment
var _sun: DirectionalLight3D
var _sky: ShaderMaterial
var _noon_toward := Vector3(0.0, 0.0, 1.0)
var _since_apply := 0.0


## The cycle of environment `e` driving `env` and `sun`; null when the map has no day_cycle (or no timing for it).
static func make(e: Dictionary, env: Environment, sun: DirectionalLight3D, sun_travel: Vector3) -> DayCycleLight:
	var spec = e.get("day_cycle")
	if not (spec is Dictionary and spec.get("stops") is Array and spec.get("timing") is Dictionary):
		return null
	var node := DayCycleLight.new()
	node.name = "DayCycle"
	node.look = spec
	node.timing = spec.timing
	node._env = env
	node._sun = sun
	node._noon_toward = -sun_travel
	if env.sky != null and env.sky.sky_material is ShaderMaterial:
		node._sky = env.sky.sky_material
	node.clock_s = DayCycle.make_start_clock(node.timing)
	node.add_to_group(GROUP)
	return node


func _ready() -> void:
	apply_phase(make_phase())


func _process(delta: float) -> void:
	clock_s += delta
	_since_apply += delta
	if _since_apply >= APPLY_EVERY_S:
		_since_apply = 0.0
		_show(make_phase())


func make_phase() -> float:
	return DayCycle.make_phase(timing, clock_s)


## Sets the clock (the host's clock arrives with each state update).
func apply_clock(host_clock_s: float) -> void:
	clock_s = host_clock_s
	_show(make_phase())


## Moves the clock to day position `phase` (0..1) and shows it (tests and renders).
func apply_phase(phase: float) -> void:
	clock_s = phase * DayCycle.make_length(timing)
	_show(phase)


func _show(phase: float) -> void:
	var pos := DayCycle.make_sun_position(look, timing, phase, _noon_toward)
	var l := DayCycle.make_look(look, pos.y)
	var light_toward := pos if pos.y >= 0.0 else -pos   # the moon stands opposite the sun
	_apply_light(l, -light_toward)
	_apply_environment(l)
	_apply_sky(l, pos)


func _apply_light(l: Dictionary, travel: Vector3) -> void:
	var sun_color: Color = l.sun_color
	var energy: float = l.sun_energy
	_sun.look_at_from_position(Vector3.ZERO, travel, Vector3.UP if absf(travel.y) < 0.99 else Vector3.RIGHT)
	_sun.light_color = sun_color
	_sun.light_energy = energy
	_sun.shadow_enabled = energy > 0.02
	SceneLighting.apply_sun_direction(travel)
	SceneLighting.apply_scene_light(sun_color * energy, l.ambient, true)


func _apply_environment(l: Dictionary) -> void:
	_env.ambient_light_color = l.ambient
	_env.background_color = l.horizon_color
	_env.fog_light_color = l.fog_color
	_env.fog_depth_begin = l.fog_start
	_env.fog_depth_end = l.fog_end


func _apply_sky(l: Dictionary, sun_pos: Vector3) -> void:
	if _sky == null:
		return
	var up := sun_pos.y >= 0.0
	var body: Vector3 = sun_pos if up else -sun_pos
	var sun_color: Color = l.sun_color
	var body_color := sun_color * (4.0 if up else 3.0)
	var tint: Color = l.sky_tint
	_sky.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	_sky.set_shader_parameter("star_amount", clampf(sun_pos.y / STAR_FULL_AT, 0.0, 1.0))
	_sky.set_shader_parameter("body_dir", body)
	_sky.set_shader_parameter("body_color", Vector3(body_color.r, body_color.g, body_color.b))
	_sky.set_shader_parameter("body_cos", SUN_DISC_COS if up else MOON_DISC_COS)

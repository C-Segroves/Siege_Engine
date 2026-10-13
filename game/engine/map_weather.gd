class_name MapWeather
extends Node3D
## Falling snow or rain of the map schema "environment.weather" (docs/formats/map_schema.md;
## decoded from the Darkstar Snowfall object by tools/darkstar_weather.py): GPU particles spawned in a
## box that follows the current camera, falling along the wind vector, as many as the intensity asks.
## The box sits upwind of the camera by half a particle's flight, so the flakes cross the view whatever
## the wind; particles live in world space, so they drift past a moving camera instead of travelling
## with it.
##
## The Snowfall "wind" is the particles' velocity in the original's units (snow maps -35 down, rain -85,
## Winter Wasteland's blizzard 100 sideways); WIND_TO_METRES turns it into metres per second that read
## like the original's flurries (35 m/s snow would fall through the box in a second).

const WIND_TO_METRES := 0.2
## Particles at intensity 1.
const SNOW_AMOUNT := 6000
const RAIN_AMOUNT := 5000
## Spawn box around the camera (metres): half extents x / z and height above the camera.
const BOX_HALF := 70.0
const BOX_HEIGHT := 45.0
## Fallback fall speed when a map gives no vertical wind (m/s).
const MIN_FALL_SPEED := 2.0
const SNOW_SIZE := 0.25
const RAIN_SIZE := Vector2(0.025, 0.9)
const SNOW_COLOR := Color(1.0, 1.0, 1.0, 0.9)
const RAIN_COLOR := Color(0.75, 0.8, 0.9, 0.45)
## Snow flutters: random sideways speed (m/s).
const SNOW_FLUTTER := 0.8

var kind := "snow"
var intensity := 1.0
var velocity := Vector3(0, -7, 0)
var particles: GPUParticles3D


## The weather node for `w` (the weather dictionary); null when there is nothing to show.
static func make(w: Dictionary) -> MapWeather:
	var amount := float(w.get("intensity", 0.0))
	if amount <= 0.0:
		return null
	var node := MapWeather.new()
	node.name = "Weather"
	node.kind = "rain" if String(w.get("kind", "snow")) == "rain" else "snow"
	node.intensity = clampf(amount, 0.0, 1.0)
	node.velocity = make_velocity(w.get("wind", [0, -35, 0]))
	node._build_particles()
	return node


## Engine-frame particle velocity (m/s) from the map's wind; always falling.
static func make_velocity(wind) -> Vector3:
	var v := Vector3(0, -35, 0)
	if wind is Array and wind.size() >= 3:
		v = Vector3(float(wind[0]), float(wind[1]), float(wind[2]))
	v *= WIND_TO_METRES
	v.y = minf(v.y, -MIN_FALL_SPEED)
	return v


func is_rain() -> bool:
	return kind == "rain"


func _build_particles() -> void:
	particles = GPUParticles3D.new()
	particles.name = "Particles"
	particles.local_coords = false
	particles.amount = maxi(1, int((RAIN_AMOUNT if is_rain() else SNOW_AMOUNT) * intensity))
	particles.lifetime = _fall_time()
	particles.preprocess = particles.lifetime
	var reach := BOX_HALF + BOX_HEIGHT + velocity.length() * particles.lifetime
	particles.visibility_aabb = AABB(-Vector3.ONE * reach, Vector3.ONE * reach * 2.0)
	particles.process_material = _make_process_material()
	particles.draw_pass_1 = _make_mesh()
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(particles)


## A particle's flight (s): long enough to fall twice the box height.
func _fall_time() -> float:
	return clampf(BOX_HEIGHT * 2.0 / absf(velocity.y), 1.0, 20.0)


func _make_process_material() -> ParticleProcessMaterial:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(BOX_HALF, BOX_HEIGHT * 0.5, BOX_HALF)
	m.gravity = Vector3.ZERO
	m.direction = velocity.normalized()
	m.spread = 0.0
	m.initial_velocity_min = velocity.length()
	m.initial_velocity_max = velocity.length()
	if not is_rain():
		m.spread = rad_to_deg(atan2(SNOW_FLUTTER, velocity.length()))
		m.turbulence_enabled = true
		m.turbulence_noise_strength = 0.6
		m.turbulence_influence_min = 0.05
		m.turbulence_influence_max = 0.15
	return m


func _make_mesh() -> QuadMesh:
	var q := QuadMesh.new()
	q.size = RAIN_SIZE if is_rain() else Vector2(SNOW_SIZE, SNOW_SIZE)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = RAIN_COLOR if is_rain() else SNOW_COLOR
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y if is_rain() else BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material = mat
	return q


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam:
		global_position = cam.global_position - velocity * particles.lifetime * 0.5

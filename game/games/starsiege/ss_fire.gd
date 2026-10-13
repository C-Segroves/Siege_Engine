class_name SSFire
extends Node3D
## The fire of a burning Starsiege structure (SSStructure under its fire threshold): flames licking up
## from the top of the shape and a column of dark smoke above them. Pure decoration, built on the host
## where the burn runs (campaign missions are single player).

const FLAME_COLOR := Color(1.0, 0.55, 0.12, 0.85)
const SMOKE_COLOR := Color(0.16, 0.14, 0.13, 0.75)
const FLAME_SIZE := 2.5
const SMOKE_SIZE := 5.0
const FLAME_AMOUNT := 40
const SMOKE_AMOUNT := 30
## Rise speeds (m/s) and lifetimes (s).
const FLAME_RISE := 4.0
const SMOKE_RISE := 6.0
const FLAME_LIFETIME := 0.8
const SMOKE_LIFETIME := 4.0


## A fire of `radius` metres (spread of the flames) at the local position `top` of `parent`.
static func make(parent: Node3D, top: Vector3, radius: float) -> SSFire:
	var f := SSFire.new()
	f.name = "Fire"
	parent.add_child(f)
	f.position = top
	f.add_child(_make_particles(FLAME_COLOR, FLAME_SIZE, FLAME_AMOUNT, [FLAME_RISE, FLAME_LIFETIME, radius]))
	f.add_child(_make_particles(SMOKE_COLOR, SMOKE_SIZE, SMOKE_AMOUNT, [SMOKE_RISE, SMOKE_LIFETIME, radius * 0.5]))
	return f


## motion = [rise speed, lifetime, emission radius].
static func _make_particles(color: Color, size: float, amount: int, motion: Array) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = float(motion[1])
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.process_material = _make_motion(color, float(motion[0]), float(motion[2]))
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.albedo_texture = _make_soft_dot()
	quad.material = mat
	p.draw_pass_1 = quad
	return p


## A round puff fading out to its edge.
static func _make_soft_dot() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color.WHITE)
	g.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	return tex


static func _make_motion(color: Color, rise: float, radius: float) -> ParticleProcessMaterial:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = maxf(radius, 0.5)
	m.direction = Vector3.UP
	m.spread = 15.0
	m.gravity = Vector3.ZERO
	m.initial_velocity_min = rise * 0.6
	m.initial_velocity_max = rise
	m.scale_min = 0.6
	m.scale_max = 1.2
	var fade := Gradient.new()
	fade.set_color(0, color)
	fade.set_color(1, Color(color, 0.0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	m.color_ramp = ramp
	return m

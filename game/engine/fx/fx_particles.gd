class_name FxParticles
extends RefCounted
## A one-shot particle burst from an effect layer's "particles" block (weapon_fx.md 1.1): Torque
## ParticleEmitter/ParticleData, Darkstar debris and sparks. CPU particles, so it runs headless and on
## every renderer; FxPlayer caps how many bursts live at once.

const MIN_LIFETIME := 0.05
const DEFAULT_LIFETIME_RANDOMNESS := 0.3
## Darkstar/Torque drag coefficients act per second on velocity; Godot damping is m/s^2 at unit speed.
const DRAG_TO_DAMPING := 1.0


## The burst node (not yet in the tree); frees itself after the longest particle has died.
static func build(block: Dictionary, sprite: Dictionary, scale_factor: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = maxi(1, int(block.get("count", 8)))
	p.one_shot = true
	p.lifetime = maxf(MIN_LIFETIME, float(block.get("lifetime", 1.0)) + float(block.get("lifetime_variance", 0.0)))
	p.lifetime_randomness = clampf(float(block.get("lifetime_variance", 0.0)) / p.lifetime * 2.0, 0.0, 1.0) if block.has("lifetime_variance") else DEFAULT_LIFETIME_RANDOMNESS
	# Torque emitters spread their particles over emit_time; 0 = one burst
	p.explosiveness = clampf(1.0 - float(block.get("emit_time", 0.0)) / p.lifetime, 0.0, 1.0)
	p.direction = Vector3.UP
	p.spread = float(block.get("spread_deg", 180.0))
	var speed := float(block.get("speed", 4.0)) * scale_factor
	var variance := float(block.get("speed_variance", speed * 0.5)) * scale_factor
	p.initial_velocity_min = maxf(0.0, speed - variance)
	p.initial_velocity_max = speed + (variance if block.has("speed_variance") else 0.0)
	_apply_emission_radius(p, float(block.get("radius", 0.0)) * scale_factor)
	_apply_spin(p, block.get("spin_dps"))
	p.gravity = Vector3(0, float(block.get("gravity", 0.0)), 0)
	p.damping_min = float(block.get("drag", 0.0)) * DRAG_TO_DAMPING
	p.damping_max = p.damping_min
	p.mesh = _make_quad(float(block.get("size", 0.5)) * scale_factor)
	p.material_override = _make_material(sprite, str(block.get("blend", sprite.get("blend", "additive"))))
	p.color_ramp = _make_ramp(block)
	p.scale_amount_curve = _make_size_curve(block)
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.emitting = true
	p.finished.connect(p.queue_free)
	return p


static func _make_quad(size: float) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	return q


static func _make_material(sprite: Dictionary, blend: String) -> StandardMaterial3D:
	var tex: Texture2D = sprite.textures[0] if not sprite.is_empty() else FxMaterials.glow_texture()
	var m := FxMaterials.make_unshaded(Color.WHITE, tex, blend == "additive")
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	return m


static func _apply_emission_radius(p: CPUParticles3D, radius: float) -> void:
	if radius > 0.0:
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		p.emission_sphere_radius = radius


## Torque spinRandomMin / Max (deg/s).
static func _apply_spin(p: CPUParticles3D, spin: Variant) -> void:
	if spin is Array and spin.size() >= 2:
		p.angular_velocity_min = float(spin[0])
		p.angular_velocity_max = float(spin[1])


## Colour over life: the full key list when given (Torque colors[] / times[]), else start -> end.
static func _make_ramp(block: Dictionary) -> Gradient:
	var g := Gradient.new()
	var start := FxLibrary.make_color(block.get("color"), Color(1, 0.8, 0.4, 1))
	var finish := FxLibrary.make_color(block.get("color_end"), Color(start.r, start.g, start.b, 0.0))
	g.set_color(0, start)
	g.set_color(1, finish)
	var keys := _keys(block)
	for i in range(1, keys.times.size() - 1):
		if i < keys.colors.size():
			g.add_point(float(keys.times[i]), FxLibrary.make_color(keys.colors[i], start))
	return g


## Size over life (relative to the start size): the key list when given, else start -> size_end.
static func _make_size_curve(block: Dictionary) -> Curve:
	var size := maxf(float(block.get("size", 0.5)), 0.001)
	var keys := _keys(block)
	var points := [Vector2(0, 1.0)]
	for i in range(1, keys.times.size() - 1):
		if i < keys.sizes.size():
			points.append(Vector2(float(keys.times[i]), float(keys.sizes[i]) / size))
	points.append(Vector2(1, float(block.get("size_end", size)) / size))
	var c := Curve.new()
	var top := 1.0
	for pt in points:
		top = maxf(top, pt.y)
	c.max_value = top
	for pt in points:
		c.add_point(pt)
	return c


## Key times normalised to 0..1 with their colours and sizes ({} parts when the block has no keys).
static func _keys(block: Dictionary) -> Dictionary:
	var k: Dictionary = block.get("keys", {}) if block.get("keys") is Dictionary else {}
	var times: Array = k.get("times", []) if k.get("times") is Array else []
	var last := float(times[-1]) if not times.is_empty() and float(times[-1]) > 0.0 else 1.0
	return {"times": times.map(func(t): return clampf(float(t) / last, 0.0, 1.0)),
		"colors": k.get("colors", []) if k.get("colors") is Array else [],
		"sizes": k.get("sizes", []) if k.get("sizes") is Array else []}

class_name FxMaterials
extends RefCounted
## Materials and procedural textures shared by the FX nodes: a soft radial glow (flashes, colour-only
## projectiles, generic particles) and a soft cross-beam profile (solid beams, tracers).

const GLOW_SIZE := 64
const BEAM_PROFILE_WIDTH := 64

static var _glow: Texture2D
static var _beam_profile: Texture2D


## White radial glow, opaque centre to clear edge.
static func glow_texture() -> Texture2D:
	if _glow == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.35, Color(1, 1, 1, 0.75))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = GLOW_SIZE
		t.height = GLOW_SIZE
		_glow = t
	return _glow


## Beam cross-section: clear edges, bright core (v across the beam).
static func beam_profile_texture() -> Texture2D:
	if _beam_profile == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 0))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.5, Color(1, 1, 1, 1))
		g.add_point(0.3, Color(1, 1, 1, 0.45))
		g.add_point(0.7, Color(1, 1, 1, 0.45))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill_from = Vector2(0, 0)
		t.fill_to = Vector2(0, 1)
		t.width = 1
		t.height = BEAM_PROFILE_WIDTH
		_beam_profile = t
	return _beam_profile


## Unshaded see-through material; `additive` adds light (glows, lasers), else alpha blends.
static func make_unshaded(color: Color, texture: Texture2D, additive: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = color
	m.albedo_texture = texture
	return m


## Camera-facing quad of `size` metres with the glow texture tinted `color`.
static func build_glow_quad(color: Color, size: float, additive := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	mi.mesh = q
	var m := make_unshaded(color, glow_texture(), additive)
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

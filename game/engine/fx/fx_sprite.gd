class_name FxSprite
extends MeshInstance3D
## One animated bitmap billboard (an explosion frame strip, a bullet bitmap, a smoke puff): frames of an
## FxLibrary sprite on a camera-facing quad anchored at the frame's origin pixel, optionally growing,
## rising and fading. Pooled by FxPlayer: `finished` fires when a one-shot ends and the player reuses it.

signal finished(sprite: FxSprite)

const DEFAULT_METRES_PER_PIXEL := 0.05
const FACE_CAMERA := "camera"
## Lies flat on the ground plane (a shockwave ring shape, Starsiege fx_shock_*), seen from above.
const FACE_GROUND := "ground"
## Lies on the surface it hit, facing along its normal (Darkstar ExplosionData faceCamera false: Tribes Shockwave).
const FACE_SURFACE := "surface"
const GROUND_LIFT := 0.1

var _sprite := {}
var _frame := -1
var _frame_time := 0.1
var _age := 0.0
var _duration := 0.0          # 0 = loop forever (projectile sprites)
var _frame_scale := []          # metres per pixel of each frame
## Phased sprites (Battledrome plasma ball): the loop of frames steps to a later phase as the owner ages.
var phase_lifetime := 0.0
var _grow := 1.0
var _rise := 0.0
var _fade := false
var _color := Color.WHITE
## Height of a ground-flat sprite above its point (clear of the terrain it lies on).
var _lift := 0.0
var _quad := QuadMesh.new()
var _material := StandardMaterial3D.new()


func _init() -> void:
	mesh = _quad
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_material.billboard_keep_scale = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED


## Shows `sprite` (FxLibrary.sprite) per `layer` (weapon_fx.md 1.1: size, duration, grow, rise, fade, color).
## `looping` plays forever (until the owner frees it), else the layer duration or one pass of the frames.
func setup(sprite: Dictionary, layer: Dictionary, looping: bool, normal := Vector3.UP) -> void:
	_sprite = sprite
	_age = 0.0
	_frame = -1
	_grow = float(layer.get("grow", 1.0))
	_rise = float(layer.get("rise", 0.0))
	_fade = bool(layer.get("fade", false))
	_color = FxLibrary.make_color(layer.get("color"), Color.WHITE)
	_frame_scale = _make_frame_scales(sprite, float(layer.get("size", 0.0)))
	var count: int = sprite.textures.size()
	var fps: float = maxf(float(sprite.fps), 0.001)
	var given := float(layer.get("duration", 0.0))
	_duration = 0.0 if looping else (given if given > 0.0 else count / fps)
	_frame_time = (_duration / count) if (given > 0.0 and not sprite.loop) else 1.0 / fps
	_apply_blend(str(sprite.blend), bool(sprite.pixel_art))
	_apply_facing(str(layer.get("face", FACE_CAMERA)), normal)
	scale = Vector3.ONE
	_show_frame(0)
	set_process(true)


## World metres per pixel of each frame: the sprite's own (per frame when given), uniformly rescaled so the
## largest frame spans the layer `size` when the layer gives one.
static func _make_frame_scales(sprite: Dictionary, size: float) -> Array:
	var scales := []
	var largest := 0.0
	for i in sprite.sizes.size():
		var mpp := float(sprite.frame_metres_per_pixel[i])
		mpp = mpp if mpp > 0.0 else (float(sprite.metres_per_pixel) if float(sprite.metres_per_pixel) > 0.0 else DEFAULT_METRES_PER_PIXEL)
		scales.append(mpp)
		largest = maxf(largest, mpp * maxi(sprite.sizes[i].x, sprite.sizes[i].y))
	if size > 0.0 and largest > 0.0:
		for i in scales.size():
			scales[i] *= size / largest
	return scales


## Camera-facing billboard, or a flat quad facing `normal` for `ground` (normal up) and `surface` layers
## (other faces: camera).
func _apply_facing(face: String, normal: Vector3) -> void:
	var flat := face == FACE_GROUND or face == FACE_SURFACE
	_material.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED if flat else BaseMaterial3D.BILLBOARD_ENABLED
	_lift = GROUND_LIFT if flat else 0.0
	basis = Basis.IDENTITY
	if not flat:
		return
	var n := Vector3.UP if face == FACE_GROUND or normal.length() < 0.001 else normal.normalized()
	var side := Vector3.RIGHT if absf(n.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var up := n.cross(side).normalized()
	basis = Basis(up.cross(n).normalized(), up, n)


func _apply_blend(blend: String, pixel_art: bool) -> void:
	if blend == "additive":
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	else:
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR if pixel_art else BaseMaterial3D.TRANSPARENCY_ALPHA
		_material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST if pixel_art else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


func _process(delta: float) -> void:
	_age += delta
	if _duration > 0.0 and _age >= _duration:
		set_process(false)
		finished.emit(self)
		return
	var f := _make_frame_index()
	if f != _frame:
		_show_frame(f)
	if _duration > 0.0:
		_apply_life(_age / _duration, delta)


func _make_frame_index() -> int:
	var count: int = _sprite.textures.size()
	var f := int(_age / _frame_time)
	var phases: int = _sprite.phases
	if phases > 1 and phase_lifetime > 0.0:
		# SIM 0xdd81: frame = tick % phase_frames + phase_frames * min(phases - 1, t * phases / lifetime)
		var per: int = maxi(1, _sprite.phase_frames)
		return mini(count - 1, f % per + per * mini(phases - 1, int(_age * phases / phase_lifetime)))
	return f % count if (_duration == 0.0 or _sprite.loop) else mini(f, count - 1)


func _apply_life(t: float, delta: float) -> void:
	if _grow != 1.0:
		scale = Vector3.ONE * lerpf(1.0, _grow, t)
	if _rise != 0.0:
		position.y += _rise * delta
	if _fade:
		_material.albedo_color.a = _color.a * (1.0 - t)


func _show_frame(f: int) -> void:
	_frame = f
	var px: Vector2i = _sprite.sizes[f]
	var origin: Vector2 = _sprite.origins[f]
	var mpp: float = _frame_scale[f]
	_quad.size = Vector2(px) * mpp
	# anchor pixel (from the top-left) on the effect position
	_quad.center_offset = Vector3(px.x * 0.5 - origin.x, origin.y - px.y * 0.5, 0.0) * mpp + Vector3(0.0, 0.0, _lift)
	_material.albedo_texture = _sprite.textures[f]
	_material.albedo_color = _color

class_name FxBeam
extends MeshInstance3D
## An instant beam from a weapon's fx "beam" block (weapon_fx.md 1.2): a flat strip along the beam that
## turns about its own axis to face the camera, drawn with the original beam bitmap ("textured"), a soft
## glowing core ("solid"), or as a short bolt travelling from the muzzle to the hit ("bolt").
## It fades over the beam's duration, then frees itself.

## Share of the beam length a travelling bolt covers.
const BOLT_LENGTH_SHARE := 0.25
const MIN_BOLT_LENGTH := 2.0
const DEFAULT_WIDTH := 0.2
const DEFAULT_DURATION := 0.12
## Screen height the pixel caps of the original data refer to (320 x 200 VGA).
const ORIGINAL_SCREEN_LINES := 200.0
## A stippled beam (ES2 ELF, 0x40bcb4) sets every other pixel: drawn half transparent.
const STIPPLE_ALPHA := 0.5

var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _width := DEFAULT_WIDTH
var _width_end := DEFAULT_WIDTH   # width at the end of the beam's life (Torque sniper / shock lance)
var _duration := DEFAULT_DURATION
var _age := 0.0
var _frames_shown := 0          # a one-sim-frame beam (ES1/ES2) is still drawn at least once
var _bolt := false
var _bolt_length := 0.0          # m; 0 = a share of the beam
var _fade := true                # glows fade out; flat palette beams stay solid until they vanish
var _color := Color.WHITE
var _quad := QuadMesh.new()
var _material: StandardMaterial3D
var _core_material: StandardMaterial3D
var _max_half_width_px := 0.0   # screen cap at the original 200-line screen (0 = none)
var _frames: Array[Texture2D] = []   # animated beam bitmaps (Tribes 2 sniper laserrip01.., shock lance bolts)
var _overlay_material: StandardMaterial3D
var _stretch := false           # the bitmap spans the beam once (ES2 BEAMTEX u0..u1, 0x40bef1)
var _scroll := 0.0               # texture repeats per second along the beam (Tribes 2 shock lance boltSpeed[0])


## Builds the beam node (not yet in the tree) for `block` (fx beam block), `pack` its textures' pack.
static func create(block: Dictionary, pack: String, from: Vector3, to: Vector3) -> FxBeam:
	var b := FxBeam.new()
	b._setup(block, pack, from, to)
	return b


func _setup(block: Dictionary, pack: String, from: Vector3, to: Vector3) -> void:
	_from = from
	_to = to
	_width = float(block.get("width", DEFAULT_WIDTH))
	_width_end = float(block.get("width_end", _width))
	_duration = maxf(0.02, float(block.get("duration", DEFAULT_DURATION)))
	_bolt = str(block.get("style", "solid")) == "bolt"
	_color = FxLibrary.make_block_color(block, pack, Color(1, 0.3, 0.2))
	if bool(block.get("stipple", false)):
		_color.a *= STIPPLE_ALPHA
	var tex := _make_texture(block, pack)
	var glow := bool(block.get("glow", true)) or str(block.get("blend", "")) == "additive"
	_bolt_length = float(block.get("length", 0.0)) if _bolt else 0.0
	var speed := float(block.get("speed", 0.0))
	if _bolt and speed > 0.0:
		# Starsiege NewBeam: a `length` segment travelling at `speed` from the muzzle to the end
		_duration = maxf(0.02, (from.distance_to(to) + _bolt_length) / speed)
	_width_end = float(block.get("width_far", _width_end))
	_fade = bool(block.get("fade", glow))
	# a beam without bitmap and glow is a flat opaque quad (Battledrome 0xc738)
	_material = FxMaterials.make_unshaded(_color, tex if tex else (FxMaterials.beam_profile_texture() if glow else null), glow)
	_max_half_width_px = float(block.get("max_half_width_px", 0.0))
	_add_core(block)
	_stretch = bool(block.get("stretch", false))
	_frames = _make_frames(block, pack)
	_add_frame_overlay(block)
	_scroll = float(block.bolt_speed[0]) if block.get("bolt_speed") is Array and not block.bolt_speed.is_empty() else 0.0
	if tex:
		_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST if str(block.get("texture_format", "rgba")) == "indexed" else BaseMaterial3D.TEXTURE_FILTER_LINEAR
		_material.texture_repeat = true
	mesh = _quad
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## The bright inner strip ("core_color", "core_width_ratio" of the width), drawn over the beam.
func _add_core(block: Dictionary) -> void:
	if not (block.get("core_color") is Array):
		return
	var core := MeshInstance3D.new()
	core.mesh = _quad
	_core_material = FxMaterials.make_unshaded(FxLibrary.make_color(block.core_color), null, false)
	_core_material.render_priority = 1
	core.material_override = _core_material
	core.scale = Vector3(1.0, float(block.get("core_width_ratio", 0.5)), 1.0)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(core)


## The beam bitmap (cached by FxLibrary): along the beam = the texture's width, repeated per its aspect.
static func _make_texture(block: Dictionary, pack: String) -> Texture2D:
	var rel = block.get("texture")
	if not (rel is String) or rel == "":
		return null
	return FxLibrary.texture(str(rel), pack, str(block.get("texture_format", "rgba")), FxLibrary.make_palette_name(block, pack),
		str(block.get("texture_axis", "along")) == "across" or str(block.get("texture_length_axis", "U")) == "V")


## The beam's animated bitmaps, played once each over its life: `frames` (Tribes 2 shock lance texture[0..2]
## lightning, which include the beam texture: they replace it; sniper laserrip01..09, which do not: drawn
## additively over the beam texture by an overlay strip). [] when the block has none.
static func _make_frames(block: Dictionary, pack: String) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	if not (block.get("frames") is Array):
		return out
	for rel in block.frames:
		var t := FxLibrary.texture(str(rel), pack, "rgba", "") if rel is String and rel != "" else null
		if t:
			out.append(t)
	return out


## Frames that do not include the beam texture animate on an additive strip over the beam.
func _add_frame_overlay(block: Dictionary) -> void:
	if _frames.is_empty() or (block.get("frames") as Array).has(block.get("texture")):
		return
	var overlay := MeshInstance3D.new()
	overlay.mesh = _quad
	_overlay_material = FxMaterials.make_unshaded(_color, _frames[0], true)
	_overlay_material.texture_repeat = true
	_overlay_material.render_priority = 1
	overlay.material_override = _overlay_material
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(overlay)


func _show_frame() -> void:
	if _frames.is_empty():
		return
	var tex := _frames[mini(_frames.size() - 1, int(_age / _duration * _frames.size()))]
	if _overlay_material:
		_overlay_material.albedo_texture = tex
		_overlay_material.albedo_color.a = _material.albedo_color.a
		_overlay_material.uv1_scale = _material.uv1_scale
	else:
		_material.albedo_texture = tex


func _ready() -> void:
	_update_shape()


func _process(delta: float) -> void:
	_age += delta
	_frames_shown += 1
	if _age >= _duration and _frames_shown > 1:
		queue_free()
		return
	_material.albedo_color.a = _color.a * (1.0 - _age / _duration) if (_fade and not _bolt) else _color.a
	if _core_material and not _bolt:
		_core_material.albedo_color.a = _material.albedo_color.a
	_show_frame()
	if _scroll != 0.0:
		_material.uv1_offset.x = fposmod(_age * _scroll, 1.0)
	_update_shape()


## Places the strip between the current ends, turned about the beam axis toward the camera.
func _update_shape() -> void:
	var a := _from
	var b := _to
	if _bolt:
		var length := _from.distance_to(_to)
		var seg := _bolt_length if _bolt_length > 0.0 else maxf(MIN_BOLT_LENGTH, length * BOLT_LENGTH_SHARE)
		var t := clampf(_age / _duration, 0.0, 1.0)
		var dir := (_to - _from).normalized()
		b = _from + dir * minf(length, seg + (length - seg) * t)
		a = b - dir * minf(seg, length)
	var axis := b - a
	var length2 := axis.length()
	if length2 < 0.001:
		visible = false
		return
	visible = true
	_quad.size = Vector2(length2, _make_width((a + b) * 0.5))
	if _material.albedo_texture and _material.texture_repeat and not _stretch:
		var tex_size := _material.albedo_texture.get_size()
		_material.uv1_scale = Vector3(length2 / maxf(_width * tex_size.x / maxf(tex_size.y, 1.0), 0.001), 1, 1)
	global_transform = Transform3D(_make_basis(axis / length2, (a + b) * 0.5), (a + b) * 0.5)


## Basis: x along the beam, quad normal (z) toward the camera.
func _make_basis(along: Vector3, centre: Vector3) -> Basis:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var to_cam := (cam.global_position - centre).normalized() if cam else Vector3.UP
	var up := along.cross(to_cam)
	if up.length() < 0.001:
		up = along.cross(Vector3.UP if absf(along.y) < 0.99 else Vector3.RIGHT)
	up = up.normalized()
	return Basis(along, up, along.cross(up).normalized())


## The beam width, narrowed near the camera so its half width stays under the original's pixel cap
## (measured on a 200-line screen, scaled to the viewport height).
func _make_width(centre: Vector3) -> float:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var width := lerpf(_width, _width_end, clampf(_age / _duration, 0.0, 1.0))
	if _max_half_width_px <= 0.0 or cam == null:
		return width
	var dist := maxf(0.1, cam.global_position.distance_to(centre))
	var px_per_m := ORIGINAL_SCREEN_LINES / (2.0 * dist * tan(deg_to_rad(cam.fov) * 0.5))
	return minf(width, 2.0 * _max_half_width_px / px_per_m)

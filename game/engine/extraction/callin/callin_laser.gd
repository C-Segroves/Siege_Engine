class_name CallinLaser
extends Node3D
## The Targeting Laser as the caller sees it (child "CallinLaser" of the battle, the local player only): the beam from his hand
## to the spot it paints, the dot (CallinLaserDot) with the verdict in words above it, the ring of the footprint the call-in
## needs, and, for a kind that flies a line, the arrow of the line after the first click. Green means the call-in can land
## there, red names the reason. Visual only: CallinDesignator decides and sends.

const HAND_RIGHT := 0.28
const HAND_DOWN := 0.22
const HAND_FORWARD := 0.45
const RING_THICKNESS := 0.1
const RING_LIFT := 0.12
const ARROW_LENGTH := 14.0
const ARROW_WIDTH := 0.3
const NO_LENGTH := 0.001

var dot := CallinLaserDot.new()
var _beam: Array[MeshInstance3D] = []
var _ring: MeshInstance3D
var _arrow: MeshInstance3D
var _paint_loop: AudioStreamPlayer3D
var _raised := false


func _init() -> void:
	name = "CallinLaser"
	add_child(dot)
	var beam_material := CallinLaserLook.make_beam_material()
	for i in 2:
		var mi := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(CallinLaserLook.BEAM_WIDTH, 1.0)
		mi.mesh = quad
		mi.material_override = beam_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_beam.append(mi)
	_ring = _make_ring_mesh()
	add_child(_ring)
	_arrow = _make_arrow_mesh()
	add_child(_arrow)
	apply_lower()


func is_raised() -> bool:
	return _raised


## The laser comes up: the beam shows from the next frame, the switch cue plays and the paint hum starts.
func apply_raise() -> void:
	_raised = true
	visible = true
	CallinLaserLook.play(CallinLaserLook.SOUND_RAISE)
	var hum := CallinLaserLook.pick_sound(CallinLaserLook.SOUND_PAINT)
	if hum != "" and _paint_loop == null:
		_paint_loop = Sfx.attach_loop(hum, dot)


func apply_lower() -> void:
	_raised = false
	visible = false
	_arrow.visible = false
	if _paint_loop != null and is_instance_valid(_paint_loop):
		_paint_loop.queue_free()
	_paint_loop = null


## One frame: the beam from `soldier`'s hand to `point`, the dot with `text` over it, the ring of `footprint` metres.
func apply_paint(soldier: Infantry, point: Vector3, ok: bool, text: String, footprint: float) -> void:
	var basis := soldier.aim_basis()
	var hand := soldier.aim_origin() + basis.x * HAND_RIGHT - basis.y * HAND_DOWN - basis.z * HAND_FORWARD
	_place_beam(hand, point)
	dot.apply_paint(point, ok, text)
	var color := CallinLaserLook.make_validity_color(ok)
	_ring.visible = footprint > 0.0
	_ring.global_position = point + Vector3.UP * RING_LIFT
	_ring.scale = Vector3.ONE * maxf(footprint, 0.5)
	(_ring.material_override as StandardMaterial3D).albedo_color = color


## The arrow of the line a directional call-in flies, from the first click `from` along `direction` (flat).
func apply_arrow(from: Vector3, direction: Vector3, ok: bool) -> void:
	_arrow.visible = direction.length() > 0.0
	if not _arrow.visible:
		return
	var along := direction.normalized()
	_arrow.global_transform = Transform3D(Basis.looking_at(along, Vector3.UP), from + along * ARROW_LENGTH * 0.5 + Vector3.UP * RING_LIFT)
	(_arrow.material_override as StandardMaterial3D).albedo_color = CallinLaserLook.make_validity_color(ok)


func hide_arrow() -> void:
	_arrow.visible = false


func _place_beam(from: Vector3, to: Vector3) -> void:
	var along := to - from
	var length := maxf(along.length(), NO_LENGTH)
	var y := along / length
	var ref := Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT
	var x := y.cross(ref).normalized()
	var z := x.cross(y).normalized()
	for i in _beam.size():
		var turned := Basis(y, PI * 0.5 * i) * Basis(x, y, z)
		_beam[i].global_transform = Transform3D(turned.scaled_local(Vector3(1.0, length, 1.0)), from + along * 0.5)


func _make_ring_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.0 - RING_THICKNESS
	torus.outer_radius = 1.0
	mi.mesh = torus
	mi.material_override = FxMaterials.make_unshaded(CallinLaserLook.VALID_COLOR, null, false)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _make_arrow_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(ARROW_WIDTH, 0.06, ARROW_LENGTH)
	mi.mesh = box
	mi.material_override = FxMaterials.make_unshaded(CallinLaserLook.VALID_COLOR, null, false)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

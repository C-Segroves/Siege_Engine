class_name CallinLaserDot
extends Node3D
## The spot a Targeting Laser paints (the caller's own and the teammates' that the host relays): a glowing dot that keeps
## its size on screen at any range, in the colour of the verdict, with an optional name or reason above it. Visual only.

const SIZE_PER_M := 0.016
const MIN_SIZE := 0.8
const MAX_SIZE := 5.0
const LABEL_LIFT := 1.0
const LABEL_PIXELS := 0.0011
const PULSE_HZ := 3.0

var _glow: MeshInstance3D
var _label: Label3D
var _color := CallinLaserLook.INVALID_COLOR
var _age := 0.0


func _init() -> void:
	name = "CallinLaserDot"
	_glow = FxMaterials.build_glow_quad(_color, 1.0, false)
	add_child(_glow)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.no_depth_test = true
	_label.pixel_size = LABEL_PIXELS
	_label.font_size = 30
	_label.outline_size = 10
	_label.position = Vector3.UP * LABEL_LIFT
	_label.visible = false
	add_child(_label)


func _process(delta: float) -> void:
	_age += delta
	var cam := get_viewport().get_camera_3d()
	var dist := cam.global_position.distance_to(global_position) if cam != null else 20.0
	_glow.scale = Vector3.ONE * clampf(dist * SIZE_PER_M, MIN_SIZE, MAX_SIZE) * (1.0 + 0.12 * sin(_age * TAU * PULSE_HZ))


## Paints the dot `ok`-coloured at `point`; `text` is shown above it ("" hides it).
func apply_paint(point: Vector3, ok: bool, text := "") -> void:
	global_position = point
	_color = CallinLaserLook.make_validity_color(ok)
	((_glow.material_override) as StandardMaterial3D).albedo_color = _color
	_label.visible = text != ""
	_label.text = text
	_label.modulate = _color
	_label.outline_modulate = Color(0, 0, 0, 0.85)
	_label.position = Vector3.UP * LABEL_LIFT


func get_text() -> String:
	return _label.text


func is_ok() -> bool:
	return _color == CallinLaserLook.VALID_COLOR

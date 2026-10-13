class_name LineupPanShot
extends Node3D
## Trailer shot: a slow dolly along the group lineup (tools/lineup.gd) - every Herc and Cybrid of
## every game at its converted size, the infantry armors standing in front.

const LINEUP_SCRIPT := preload("res://tools/lineup.gd")
const SETTLE_SECONDS := 0.8
const CAMERA_FOV := 50.0
const CAMERA_FAR := 3000.0
const EYE := Vector3(0.0, 4.5, 9.0)       # metres; just in front of the infantry row (z = 4)
const AIM_OFFSET := Vector3(22.0, 0.5, -40.0)   # metres from the eye: along and into the rows

var spec: Dictionary
var _camera: Camera3D
var _extent := Vector3.ONE
var _clock := 0.0
var _playing := false


func prepare() -> void:
	var lineup: Node3D = LINEUP_SCRIPT.new()
	lineup.auto_save = false
	add_child(lineup)
	_extent = lineup.build()
	for label in lineup.find_children("*", "Label3D", true, false):
		label.visible = false   # name tags are too small to read in a moving shot
	_camera = Camera3D.new()
	_camera.fov = CAMERA_FOV
	_camera.far = CAMERA_FAR
	add_child(_camera)
	_camera.make_current()
	_apply_camera(0.0)
	await get_tree().create_timer(SETTLE_SECONDS).timeout


func play() -> void:
	_playing = true


func _process(delta: float) -> void:
	if not _playing:
		return
	_clock += delta
	_apply_camera(smoothstep(0.0, 1.0, _clock / float(spec.seconds)))


## Camera at fraction `k` (0..1) of the dolly along the rows, looking along and into them.
func _apply_camera(k: float) -> void:
	var dolly: Dictionary = spec.dolly
	var x := lerpf(float(dolly.from), float(dolly.to), k) * _extent.x
	var eye := EYE + Vector3(x, 0.0, 0.0)
	_camera.look_at_from_position(eye, eye + AIM_OFFSET, Vector3.UP)

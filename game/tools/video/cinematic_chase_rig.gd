class_name CinematicChaseRig
extends RefCounted
## Trailer camera: follows a vehicle from behind and to one side, framing it together with its
## target (when it has one) so both the shooter and the hits are in shot. Drives an existing
## camera (the battle's chase camera) after the battle has placed it.

const DEFAULT_DISTANCE := 24.0      # metres behind
const DEFAULT_HEIGHT := 8.0         # metres above the vehicle's feet
const DEFAULT_SIDE := 8.0           # metres to the right (negative: left)
const LOOK_HEIGHT := 5.0
const LOOK_AHEAD := 40.0            # metres ahead when there is no target
const TARGET_WEIGHT := 0.25         # how far the aim point leans towards the target
## The lean stays within this share of the camera distance, so the subject stays in frame.
const MAX_LEAN_SHARE := 0.4
const FOLLOW_RATE := 3.0            # 1/s smoothing of position and aim
const FOV := 60.0

var camera: Camera3D
var subject: Herc
var distance := DEFAULT_DISTANCE
var height := DEFAULT_HEIGHT
var side := DEFAULT_SIDE
var _pos := Vector3.ZERO
var _look := Vector3.ZERO
var _placed := false


func _init(p_camera: Camera3D, p_subject: Herc, params: Dictionary) -> void:
	camera = p_camera
	subject = p_subject
	distance = float(params.get("distance", DEFAULT_DISTANCE))
	height = float(params.get("height", DEFAULT_HEIGHT))
	side = float(params.get("side", DEFAULT_SIDE))
	camera.fov = FOV


func update(delta: float) -> void:
	if not is_instance_valid(subject):
		return
	var basis := _make_heading()
	var want := subject.global_position + basis.z * distance + basis.x * side + Vector3.UP * height
	var look := make_look_point(basis)
	var k := 1.0 if not _placed else clampf(delta * FOLLOW_RATE, 0.0, 1.0)
	_placed = true
	_pos = _pos.lerp(want, k)
	_look = _look.lerp(look, k)
	camera.global_position = _pos
	camera.look_at(_look, Vector3.UP)


## The next update places the camera at once instead of easing in (a cut).
func restart() -> void:
	_placed = false


## Ahead of the subject, leaning towards its living target.
func make_look_point(basis: Basis) -> Vector3:
	var base := subject.global_position + Vector3.UP * LOOK_HEIGHT
	var t := subject.target as Herc
	if t == null or not is_instance_valid(t) or not t.alive:
		return base - basis.z * LOOK_AHEAD
	var lean := (t.global_position - base) * TARGET_WEIGHT
	return base + lean.limit_length(distance * MAX_LEAN_SHARE)


## Flat heading of the body (flyers) or of the torso (walking Hercs, which aim with it).
func _make_heading() -> Basis:
	var b := subject.global_basis if subject is Flyer else subject.aim_basis()
	var back := Vector3(b.z.x, 0.0, b.z.z)
	if back.length() < 0.01:
		back = Vector3.BACK
	return Basis.looking_at(-back.normalized(), Vector3.UP)

class_name SSCameraFunctions
extends RefCounted
## The camera and input-lock engine functions of Starsiege mission scripts, played by SSCutscene on the
## host's screen: focusCamera(splineCamera, path), setPlayerCamera(), lockUserInput(on) and the object
## cameras setDominantCamera / setFlybyCamera / setTowerCamera / setOrbitCamera (SSObjectCamera).
## An object the script names but the mission does not have leaves the view unchanged, as the original
## prints "... is non-existent or non-net object" and returns.

var rt: StarsiegeMissionRuntime


func _init(runtime: StarsiegeMissionRuntime) -> void:
	rt = runtime


## {lower-case function name: Callable(name, args)} for SSEngineFunctions.
func make_handlers() -> Dictionary:
	return {
		"focuscamera": _focus_camera,
		"setplayercamera": _set_player_camera,
		"lockuserinput": _lock_user_input,
		"setdominantcamera": _set_dominant_camera,
		"setflybycamera": _set_flyby_camera,
		"settowercamera": _set_tower_camera,
		"setorbitcamera": _set_orbit_camera,
	}


## focusCamera(camera, path): SSCutscene flies the mission's camera path.
func _focus_camera(_n: String, a: Array):
	if rt.cutscene:
		rt.cutscene.focus_path(SSScript.to_str(_arg(a, 1)))
	return ""


func _set_player_camera(_n: String, _a: Array):
	if rt.cutscene:
		rt.cutscene.end_camera()
	return ""


func _lock_user_input(_n: String, a: Array):
	if rt.cutscene:
		rt.cutscene.lock_input(SSScript.truthy(_arg(a, 0, 1)))
	return ""


## setDominantCamera(object0, object1, [x, y, z]).
func _set_dominant_camera(_n: String, a: Array):
	var subject := _node(a, 0)
	var focus := _node(a, 1)
	if subject and focus:
		_follow(SSObjectCamera.make_dominant(subject, focus, _vector(a, 2, SSObjectCamera.DOMINANT_OFFSET)))
	return ""


## setFlybyCamera(object, [cameraOffsetX, Y, Z, objectOffsetX, Y, Z]).
func _set_flyby_camera(_n: String, a: Array):
	var subject := _node(a, 0)
	if subject:
		_follow(SSObjectCamera.make_flyby(subject, _vector(a, 1, SSObjectCamera.FLYBY_OFFSET),
			_vector(a, 4, SSObjectCamera.OBJECT_OFFSET)))
	return ""


## setTowerCamera(object, cameraPositionX, Y, Z, [objectOffsetX, Y, Z]); the position is a mission point.
func _set_tower_camera(_n: String, a: Array):
	var subject := _node(a, 0)
	if subject and a.size() >= 4:
		var p := _vector(a, 1, Vector3.ZERO)
		_follow(SSObjectCamera.make_tower(subject, StarsiegeMissionRuntime.orig_to_eng(p.x, p.y, p.z),
			_vector(a, 4, SSObjectCamera.OBJECT_OFFSET)))
	return ""


## setOrbitCamera(object, [distance, azimuthDegrees, incidenceDegrees]).
func _set_orbit_camera(_n: String, a: Array):
	var subject := _node(a, 0)
	if subject:
		var start := Vector3(SSObjectCamera.ORBIT_DISTANCE, SSObjectCamera.ORBIT_AZIMUTH_DEG,
			SSObjectCamera.ORBIT_INCIDENCE_DEG)
		_follow(SSObjectCamera.make_orbit(subject, _vector(a, 1, start)))
	return ""


func _follow(cam: SSObjectCamera) -> void:
	if rt.cutscene:
		rt.cutscene.follow(cam)


func _node(a: Array, i: int) -> Node3D:
	if i >= a.size():
		return null
	var n = rt.tree.node_of(rt.ss_resolve(a[i]))
	return n if n is Node3D else null


## Up to three numbers from argument `i` on; missing ones keep the component of `fallback`.
static func _vector(a: Array, i: int, fallback: Vector3) -> Vector3:
	var v := fallback
	for k in 3:
		if i + k < a.size():
			v[k] = SSScript.num(a[i + k])
	return v


static func _arg(a: Array, i: int, default = ""):
	return a[i] if i < a.size() else default

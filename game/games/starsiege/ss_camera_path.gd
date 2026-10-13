class_name SSCameraPath
extends RefCounted
## One Starsiege camera path (.mis SCPG group: SCPW waypoints in flight order, exported to the mission
## JSON "camera_paths"): the spline camera flies through the waypoints on a Catmull-Rom curve, turning
## from one waypoint's view to the next, at the speed stored on each waypoint (m/s, interpolated along
## the segment). The flight reports each waypoint it reaches; the mission scripts' callbacks
## <path>::camera::waypoint<k> are numbered from 1 = the first waypoint (reached at the start:
## CA4's path1 has four waypoints and its waypoint4 callback ends the cut-scene).

## Speeds as low as 1e-6 occur (HE1 path1 holds the camera on a waypoint); a floor keeps the flight
## from stalling for ever while still lingering there.
const MIN_SPEED := 0.01
## Below this length a segment is passed at once.
const MIN_SEGMENT := 0.001

var path_name := ""
var points: Array[Vector3] = []
var views: Array[Quaternion] = []
var speeds: Array[float] = []
var segment := 0          # index of the waypoint the camera left last
var fraction := 0.0       # 0..1 along the current segment


## A path from its exported definition {path, waypoints: [{pos, forward, up, speed}]}.
static func from_def(p_name: String, def: Dictionary) -> SSCameraPath:
	var cp := SSCameraPath.new()
	cp.path_name = p_name
	for w in MissionRuntime._arr(def.get("waypoints")):
		cp.points.append(_vec(w.pos))
		cp.views.append(Basis.looking_at(_vec(w.forward), _vec(w.up)).get_rotation_quaternion())
		cp.speeds.append(float(w.get("speed", 1.0)))
	return cp


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func is_empty() -> bool:
	return points.is_empty()


func is_finished() -> bool:
	return segment >= points.size() - 1


## Moves the camera on by `delta` seconds; returns the indices (0-based) of the waypoints reached.
func advance(delta: float) -> Array[int]:
	var reached: Array[int] = []
	var time_left := delta
	while time_left > 0.0 and not is_finished():
		var length := points[segment].distance_to(points[segment + 1])
		if length < MIN_SEGMENT:
			_pass_waypoint(reached)
			continue
		var speed := maxf(lerpf(speeds[segment], speeds[segment + 1], fraction), MIN_SPEED)
		var to_end := (1.0 - fraction) * length / speed
		if to_end > time_left:
			fraction += time_left * speed / length
			return reached
		time_left -= to_end
		_pass_waypoint(reached)
	return reached


func _pass_waypoint(reached: Array[int]) -> void:
	segment += 1
	fraction = 0.0
	reached.append(segment)


## The camera's world transform at the current point of the flight.
func make_transform() -> Transform3D:
	if points.is_empty():
		return Transform3D.IDENTITY
	if is_finished():
		return Transform3D(Basis(views[-1]), points[-1])
	var i := segment
	var p0 := points[maxi(i - 1, 0)]
	var p3 := points[mini(i + 2, points.size() - 1)]
	var pos := points[i].cubic_interpolate(points[i + 1], p0, p3, fraction)
	return Transform3D(Basis(views[i].slerp(views[i + 1], fraction)), pos)

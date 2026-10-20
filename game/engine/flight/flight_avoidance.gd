class_name FlightAvoidance
extends RefCounted
## Obstacle and map-edge avoidance of a FlightPilot. Obstacles (buildings, interiors, anything solid the terrain scan
## cannot see) are found with three ray casts ahead; the craft turns to the clearer side or climbs over. The map edge
## turns the craft back when it would cross it within the profile's margin.

## Sideways probes are turned this far from the nose (rad), and the turn asked for when one is clearer.
const PROBE_ANGLE := 0.6
## The side probes look this much farther than the one ahead, and two runs this close (m) are alike.
const SIDE_PROBE_FACTOR := 1.5
const TIE_M := 5.0
## Once turned back from the edge, the craft keeps turning until it would clear it by this much more.
const EDGE_RELEASE := 1.5
const AVOID_TURN := 0.9
## A side is clearer when it is clear, or its free run is this much longer than straight ahead.
const CLEARER_BY := 1.3
## The probe looks at least this far (m) and this many seconds ahead.
const MIN_PROBE_M := 60.0
const PROBE_S := 3.5
## Free fraction of a probe that still counts as clear.
const CLEAR_FRACTION := 0.98

## free_run(from: Vector3, direction: Vector3, length: float) -> float: how far a ray from `from` goes before it hits
## something solid (`length` when clear).
var free_run := Callable()
## The playable area (engine x / z); an empty rect = no edge.
var area := Rect2()
## True to turn back at the map edge; false for a craft entering or leaving the map.
var checks_edge := true
## True when the goal is a point the craft stops or turns at: it does not fly on past it into the edge.
var stops_at_aim := false
var max_climb := deg_to_rad(25.0)
var _turning_back := false
var edge_margin_s := 5.0

## The heading to fly instead of the goal's (rad, Godot yaw), NAN when the way is free.
var heading := NAN
## A climb (m/s) to make when no side is clearer, FlightTerrainScan.NONE when none.
var climb := FlightTerrainScan.NONE


func apply_profile(profile: FlightProfile) -> void:
	max_climb = profile.max_climb
	edge_margin_s = profile.edge_margin_s


## Reads the ground ahead of a craft at `pos` flying along flat unit `dir` at `speed`, towards the point `aim`.
func apply_scan(pos: Vector3, dir: Vector3, speed: float, aim: Vector3) -> void:
	heading = NAN
	climb = FlightTerrainScan.NONE
	_scan_obstacles(pos, dir, speed, aim)
	if is_nan(heading):
		_scan_edge(pos, dir, speed, aim)


func _scan_obstacles(pos: Vector3, dir: Vector3, speed: float, aim: Vector3) -> void:
	if not free_run.is_valid():
		return
	var length := maxf(speed * PROBE_S, MIN_PROBE_M)
	var ahead: float = free_run.call(pos, dir, length)
	if ahead >= length * CLEAR_FRACTION:
		return
	var left := dir.rotated(Vector3.UP, PROBE_ANGLE)
	var right := dir.rotated(Vector3.UP, -PROBE_ANGLE)
	var side_length := length * SIDE_PROBE_FACTOR
	var left_run: float = free_run.call(pos, left, side_length)
	var right_run: float = free_run.call(pos, right, side_length)
	var best := maxf(left_run, right_run)
	if best >= length * CLEAR_FRACTION or best > ahead * CLEARER_BY:
		heading = _heading_of(dir) + (AVOID_TURN if _is_left_clearer(left_run, right_run, dir, aim - pos) else -AVOID_TURN)
	else:
		climb = speed * sin(max_climb)


## The left side is clearer, or - when both are as free - the one the goal lies on.
func _is_left_clearer(left_run: float, right_run: float, dir: Vector3, to_aim: Vector3) -> bool:
	if absf(left_run - right_run) > TIE_M:
		return left_run > right_run
	return dir.cross(to_aim).y >= 0.0


func _scan_edge(pos: Vector3, dir: Vector3, speed: float, aim: Vector3) -> void:
	if not checks_edge or not area.has_area() or not area.has_point(Vector2(pos.x, pos.z)):
		return
	var aim_distance := Vector2(aim.x - pos.x, aim.z - pos.z).length()
	var margin := maxf(speed, 1.0) * edge_margin_s * (EDGE_RELEASE if _turning_back else 1.0)
	if stops_at_aim:
		margin = minf(margin, aim_distance)
	var predicted := Vector2(pos.x, pos.z) + Vector2(dir.x, dir.z) * margin
	_turning_back = not area.has_point(predicted)
	if not _turning_back:
		return
	var to_centre := area.get_center() - Vector2(pos.x, pos.z)
	heading = atan2(-to_centre.x, -to_centre.y)


## Godot yaw of a flat direction (Basis(UP, yaw) * FORWARD = dir).
static func _heading_of(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)

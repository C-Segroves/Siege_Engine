class_name FlightGoal
extends RefCounted
## Where a FlightPilot flies: a point, a path of points, an orbit about a point or a straight line, each held at
## a height above the ground (or at a world height), or a descent to a point on the ground. A goal answers one
## question, make_aim(): the flat point to turn towards from where the craft is.

enum Kind { POINT, PATH, ORBIT, LINE, DESCEND }

## Distance (m) at which a path point counts as reached (banked turns are wide).
const PATH_REACH := 60.0
## An orbit's aim point leads the craft round the circle by this angle (rad).
const ORBIT_LEAD := 0.6

var kind := Kind.POINT
var point := Vector3.ZERO
var points: Array[Vector3] = []
var index := 0
var radius := 0.0
var clockwise := true
var direction := Vector3.FORWARD
var look_ahead := 0.0
## Height above the ground to hold (m).
var agl := 30.0
## World height to hold instead of `agl`; NAN when none.
var height_y := NAN
## Height to keep over the ground (m) instead of the profile's clearance; NAN when none (a strafing run flies low).
var clearance := NAN
## Seconds of flight ahead to read the ground for instead of the profile's; NAN when none (a strafing run reads little).
var look_ahead_s := NAN
## True for a craft that enters or leaves the map: the map edge does not turn it back.
var crosses_edge := false
## Sink rate of a DESCEND goal (m/s, positive down).
var sink_rate := 3.0
## True for a hover goal: the craft holds `agl` over the ground below it, however the ground ahead rises; neither the terrain
## look-ahead nor an obstacle ray lifts it (a delivery hanging its load a few metres over the ground goes there on purpose).
var holds_height := false


## Stops over `p` and holds `p_agl` metres over the ground below it: the terrain clearance does not override the height.
static func make_hover(p: Vector3, p_agl: float) -> FlightGoal:
	var g := make_point(p, p_agl)
	g.holds_height = true
	return g


## True when the goal's own height or descent is meant: the terrain ahead and obstacles do not change it.
func is_deliberate() -> bool:
	return kind == Kind.DESCEND or holds_height


static func make_point(p: Vector3, p_agl: float) -> FlightGoal:
	var g := FlightGoal.new()
	g.point = p
	g.agl = p_agl
	return g


## Patrol path: the point at `p_index` is aimed at, the next one once it is reached; the path loops.
static func make_path(p_points: Array[Vector3], p_index: int, p_agl: float) -> FlightGoal:
	var g := FlightGoal.new()
	g.kind = Kind.PATH
	g.points = p_points
	g.index = p_index
	g.agl = p_agl
	return g


static func make_orbit(centre: Vector3, p_radius: float, p_agl: float, p_clockwise: bool) -> FlightGoal:
	var g := FlightGoal.new()
	g.kind = Kind.ORBIT
	g.point = centre
	g.radius = p_radius
	g.agl = p_agl
	g.clockwise = p_clockwise
	return g


## A line through `origin` along the flat unit `p_direction`: the aim point is `p_look_ahead` metres ahead of the craft's
## closest point on it, so the craft flies back onto the line from any offset.
static func make_line(origin: Vector3, p_direction: Vector3, p_look_ahead: float, p_agl: float) -> FlightGoal:
	var g := FlightGoal.new()
	g.kind = Kind.LINE
	g.point = origin
	g.direction = Vector3(p_direction.x, 0.0, p_direction.z).normalized()
	g.look_ahead = p_look_ahead
	g.agl = p_agl
	return g


## Straight on from the craft's own position and heading (a strafing run's pass).
static func make_straight(from: Vector3, heading_direction: Vector3, p_agl: float) -> FlightGoal:
	return make_line(from, heading_direction, 100.0, p_agl)


## Sinks over `p` at `p_sink_rate` until the model touches down; no terrain clearance applies.
static func make_descent(p: Vector3, p_sink_rate: float) -> FlightGoal:
	var g := FlightGoal.new()
	g.kind = Kind.DESCEND
	g.point = p
	g.sink_rate = p_sink_rate
	return g


## The point the craft turns towards from `pos` (flat, y = pos.y).
func make_aim(pos: Vector3) -> Vector3:
	match kind:
		Kind.PATH:
			return _make_path_aim(pos)
		Kind.ORBIT:
			return _make_orbit_aim(pos)
		Kind.LINE:
			return _make_line_aim(pos)
		_:
			return point


## The point after the aim point on a path (the leg the craft turns on to next); NAN components for any other goal.
func make_next_aim() -> Vector3:
	if kind != Kind.PATH or points.size() < 2:
		return Vector3(NAN, NAN, NAN)
	return points[(index + 1) % points.size()]


## Moves a path on to its next point when the craft has reached the current one.
func apply_progress(pos: Vector3) -> void:
	if kind == Kind.PATH and not points.is_empty() and _flat_distance(points[index % points.size()], pos) < PATH_REACH:
		index = (index + 1) % points.size()


func _make_path_aim(pos: Vector3) -> Vector3:
	if points.is_empty():
		return pos
	return points[index % points.size()]


func _make_orbit_aim(pos: Vector3) -> Vector3:
	var flat := Vector2(pos.x - point.x, pos.z - point.z)
	var angle := flat.angle() if flat.length() > 1.0 else 0.0
	angle += ORBIT_LEAD if clockwise else -ORBIT_LEAD
	return point + Vector3(cos(angle), 0.0, sin(angle)) * radius


func _make_line_aim(pos: Vector3) -> Vector3:
	var along := (pos - point).dot(direction)
	return point + direction * (along + look_ahead)


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

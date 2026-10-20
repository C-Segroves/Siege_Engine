class_name FlightPilot
extends RefCounted
## The one autopilot every AI flyer flies by (ES2 / Starsiege flyers, Tribes Shrike, Thundersword and Havoc, the call-in
## bombers and attack craft, the extraction transports). Given a FlightGoal it outputs the controls of one frame:
##   - heading: banks into the turn (bank proportional to the heading error, capped by the profile) with the rudder
##     coordinated, so the craft turns on its bank and never slides;
##   - height: holds the goal's height above the ground, reads the terrain ahead (FlightTerrainScan) and climbs early
##     over a ridge to keep the profile's clearance, then sinks smoothly once past it; slows down when the climb the
##     ground asks for is more than the craft can make;
##   - avoidance: ray casts for solid obstacles and the map edge (FlightAvoidance).
## It never touches nodes: the Flyer feeds it its position and speeds and the ground / ray functions of its map.

## Heading error (rad) at which the turn demand saturates (1 / TURN_PER_RAD), and the turn demand per rad.
const TURN_PER_RAD := 2.0
## Closer than this to the aim point (m) the craft keeps its heading instead of turning on the spot.
const KEEP_HEADING_NEAR := 2.0
## The terrain and obstacles are rescanned this often (s).
const SCAN_INTERVAL := 0.12
## The slowest the craft is held to when the ground asks for more climb than it can make (fraction of the asked speed).
const MIN_CLIMB_SPEED_SHARE := 0.1
## The craft slows down once the ground asks for more than this share of the climb it can make.
const CLIMB_HEADROOM := 0.8
## Vertical speed a hover craft may add with its lift on top of its nose (share of its maximum vertical speed).
const NOSE_PITCH_LIMIT := 0.95
## The height held over the ground never exceeds this share of the craft's ceiling.
const CEILING_SHARE := 0.85
## The craft climbs this fast per metre it is below its clearance (1/s).
const FLOOR_CLIMB_PER_M := 2.0
## The sink towards the clearance is held to this share of the vertical braking the craft has.
const SINK_BRAKE_SHARE := 0.5
## A hover goal's height is approached at no more than this share of the vertical braking the craft has.
const HOVER_BRAKE_SHARE := 0.5
## The ground is read this far past a goal point the craft stops at (m).
const STOP_MARGIN_M := 30.0

var model: FlightModel
var profile: FlightProfile
var terrain := FlightTerrainScan.new()
var avoidance := FlightAvoidance.new()
var _scan_age := SCAN_INTERVAL
var _required_climb := FlightTerrainScan.NONE


func _init(p_model: FlightModel, p_profile: FlightProfile) -> void:
	model = p_model
	profile = p_profile
	terrain.apply_profile(p_profile)
	avoidance.apply_profile(p_profile)


## Ground height function ground(x, z) -> float (NAN unknown), ray function free_run(from, dir, length) -> float and the
## playable area (an empty Rect2 for none).
func apply_world(ground: Callable, free_run: Callable, area: Rect2) -> void:
	terrain.ground = ground
	avoidance.free_run = free_run
	avoidance.area = area


## The controls for one frame towards `goal` at `speed` m/s; `pos` is the craft's world position, `agl` its height over the
## ground and `delta` the frame time.
func steer(pos: Vector3, agl: float, goal: FlightGoal, speed: float, delta: float) -> FlightControls:
	goal.apply_progress(pos)
	var aim := goal.make_aim(pos)
	var forward := make_forward(model.heading)
	_apply_scans(pos, agl, forward, aim, goal, delta)
	var cmd := FlightCommand.new()
	var error := _make_heading_error(pos, aim, goal)
	_apply_turn(cmd, error)
	var climb := _make_climb_rate(pos, agl, goal)
	cmd.climb = climb
	cmd.pitch = _make_pitch(climb, goal)
	cmd.throttle = model.make_throttle_for(_make_speed(speed))
	return model.make_controls(cmd)


## The signed angle (rad, + = to the left) from the nose to the flat direction of `aim` from `pos`.
func make_heading_error(pos: Vector3, aim: Vector3) -> float:
	var flat := Vector3(aim.x - pos.x, 0.0, aim.z - pos.z)
	if flat.length() <= KEEP_HEADING_NEAR:
		return 0.0
	return angle_difference(model.heading, FlightAvoidance._heading_of(flat))


static func make_forward(heading: float) -> Vector3:
	return Vector3(-sin(heading), 0.0, -cos(heading))


# ------------------------------------------------------------------ scans

func _apply_scans(pos: Vector3, agl: float, forward: Vector3, aim: Vector3, goal: FlightGoal, delta: float) -> void:
	_scan_age += delta
	if _scan_age < SCAN_INTERVAL:
		return
	_scan_age = 0.0
	var speed := maxf(model.speed, 0.0)
	avoidance.checks_edge = not goal.crosses_edge
	avoidance.stops_at_aim = goal.kind in [FlightGoal.Kind.POINT, FlightGoal.Kind.DESCEND]
	avoidance.apply_scan(pos, forward, speed, aim)
	terrain.clearance = profile.clearance_m if is_nan(goal.clearance) else goal.clearance
	terrain.look_ahead_s = profile.look_ahead_s if is_nan(goal.look_ahead_s) else goal.look_ahead_s
	terrain.max_distance = _make_stop_distance(pos, aim, goal)
	terrain.vertical_speed = model.velocity.y
	terrain.climb_capacity = _make_max_rate(profile.max_climb) * CLIMB_HEADROOM
	terrain.climb_accel = model.make_climb_accel()
	if goal.is_deliberate():
		_required_climb = FlightTerrainScan.NONE
		terrain.safe_speed = INF
		return
	var directions: Array[Vector3] = [forward]
	var to_aim := Vector3(aim.x - pos.x, 0.0, aim.z - pos.z)
	if to_aim.length() > KEEP_HEADING_NEAR:
		directions.append(to_aim.normalized())
	var after := goal.make_next_aim()
	if after.is_finite() and Vector2(after.x - pos.x, after.z - pos.z).length() > KEEP_HEADING_NEAR:   # round the corner of a path
		directions.append(Vector3(after.x - pos.x, 0.0, after.z - pos.z).normalized())
	var sink := _make_goal_climb(pos, pos.y - agl, goal)
	_required_climb = terrain.make_required_climb(pos, directions, speed, sink, _make_wanted_y(pos.y - agl, goal))


## How far the craft flies on this goal: to a point it stops at (and a little past it), else without limit.
func _make_stop_distance(pos: Vector3, aim: Vector3, goal: FlightGoal) -> float:
	if goal.kind in [FlightGoal.Kind.POINT, FlightGoal.Kind.DESCEND]:
		return Vector2(aim.x - pos.x, aim.z - pos.z).length() + STOP_MARGIN_M
	return INF


# ------------------------------------------------------------------ heading

func _make_heading_error(pos: Vector3, aim: Vector3, goal: FlightGoal) -> float:
	if not goal.is_deliberate():
		if not is_nan(avoidance.heading):
			return angle_difference(model.heading, avoidance.heading)
	return make_heading_error(pos, aim)


## Turn demand from the heading error, and the bank that goes with it, capped by the profile.
func _apply_turn(cmd: FlightCommand, error: float) -> void:
	cmd.turn = clampf(-error * TURN_PER_RAD, -1.0, 1.0)
	cmd.bank = clampf(-error * profile.bank_per_rad, -profile.max_bank, profile.max_bank)


# ------------------------------------------------------------------ height

## Wanted vertical speed: the goal's height, or the climb the ground ahead and any obstacle ask for if that is more.
func _make_climb_rate(pos: Vector3, agl: float, goal: FlightGoal) -> float:
	if goal.kind == FlightGoal.Kind.DESCEND:
		return -goal.sink_rate
	var ground_here := pos.y - agl
	if goal.holds_height:
		return _make_braked_climb(_make_goal_climb(pos, ground_here, goal), _make_wanted_y(ground_here, goal) - pos.y)
	var wanted := maxf(_make_goal_climb(pos, ground_here, goal), maxf(_required_climb, maxf(avoidance.climb, _make_floor_climb(agl))))
	wanted = maxf(wanted, -_make_sink_limit(agl))
	return clampf(wanted, -_make_max_rate(profile.max_dive), _make_max_rate(profile.max_climb))


## The climb rate (m/s) that restores the clearance when the craft is below it (the clearance of the goal, else of the profile;
## a strafing dive's goal lowers it): the last word of the terrain scan, which cannot see a ridge a craft is too slow to climb.
func _make_floor_climb(agl: float) -> float:
	return maxf(terrain.clearance - agl, 0.0) * FLOOR_CLIMB_PER_M if agl < terrain.clearance else FlightTerrainScan.NONE


## The fastest the craft may sink (m/s): what it can still arrest with the lift it has before it is down to its clearance.
func _make_sink_limit(agl: float) -> float:
	return sqrt(2.0 * SINK_BRAKE_SHARE * model.make_climb_accel() * maxf(agl - terrain.clearance, 0.0))


## A hover craft meets its height without overshooting: the vertical speed is at most what it can still shed over the height
## error left (`error` m, + = goal above), with the lift it has.
func _make_braked_climb(rate: float, error: float) -> float:
	var limit := sqrt(2.0 * HOVER_BRAKE_SHARE * model.make_climb_accel() * absf(error))
	return clampf(rate, -limit, limit)


## The climb rate (m/s) the goal's own height asks for.
func _make_goal_climb(pos: Vector3, ground_here: float, goal: FlightGoal) -> float:
	if goal.kind == FlightGoal.Kind.DESCEND:
		return -goal.sink_rate
	return clampf((_make_wanted_y(ground_here, goal) - pos.y) * profile.climb_per_m * model.make_climb_scale(), -_make_max_rate(profile.max_dive), _make_max_rate(profile.max_climb))


## The world height the goal holds: its own, or its height over the ground below, within the craft's ceiling.
func _make_wanted_y(ground_here: float, goal: FlightGoal) -> float:
	if not is_nan(goal.height_y):
		return goal.height_y
	return ground_here + minf(goal.agl, model.make_ceiling() * CEILING_SHARE)


## The steepest vertical speed the craft can make: a jet climbs along a flight path of `angle` at its speed, a hover
## craft by its lift (its nose adds to it only up to the same limit).
func _make_max_rate(angle: float) -> float:
	var lift := model.make_vertical_rate()
	return lift if lift > 0.0 else maxf(model.speed, 0.0) * sin(angle)


## Nose pitch that makes the wanted vertical speed at the present speed.
func _make_pitch(climb: float, goal: FlightGoal) -> float:
	if goal.kind == FlightGoal.Kind.DESCEND and model.make_vertical_rate() > 0.0:
		return 0.0   # a hover craft sinks on its lift and stays level
	var speed := maxf(model.speed, model.make_flying_speed())
	return asin(clampf(climb / speed, -NOSE_PITCH_LIMIT, NOSE_PITCH_LIMIT))


## The speed to fly: the asked one, slowed so that a hover craft can climb the rise ahead before it gets there (a jet needs its
## speed to climb, so it keeps it).
func _make_speed(asked: float) -> float:
	if model.make_vertical_rate() <= 0.0:
		return asked
	return clampf(terrain.safe_speed, asked * MIN_CLIMB_SPEED_SHARE, asked)

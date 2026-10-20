class_name CallinAttackPilot
extends FlyerAI
## The autopilot of a fast attack craft (host). It flies to the designated point, then works that station for a set time: it
## picks the nearest hostile unit within the engagement radius of the point and makes strafing runs at it (in low and fast,
## firing while the nose is on it, past the target and up and away, then round again), orbiting the point while there is
## nothing to shoot. When its time or its ammunition is gone it flies out along the line and reports DONE. It flies through
## the shared
## FlightPilot (engine/flight), which holds a clearance over the terrain it flies (a hill in the way would ground a hover
## craft); it can be shot down (the Flyer then crashes).

enum Phase { APPROACH, STATION, LEAVE, DONE }
enum Run { IN, OUT }

## The flight out is over this close to its exit point (m).
const EXIT_REACH_M := 60.0
## Share of the cruise speed flown on the approach, on a strafing run and on the orbit.
const APPROACH_SPEED_SHARE := 1.0
const RUN_SPEED_SHARE := 0.8
const ORBIT_SPEED_SHARE := 0.6
## A run passes the target when this close (m, flat); then it flies on for at most RUN_OUT_S seconds / RUN_OUT_RANGE_M metres.
const PASS_DISTANCE_M := 45.0
const RUN_OUT_S := 3.5
const RUN_OUT_RANGE_M := 320.0
## Height above the ground at the target of a run, and the distance over which the run descends to it (m).
const RUN_LOW_AGL_M := 16.0
const RUN_DESCENT_M := 260.0
const RUN_DESCENT_START_M := 60.0
## The craft shoots when it heads within FIRE_CONE_RAD of the target, the target is not more than MAX_DEPRESSION_RAD below
## its horizon and it is nearer than FIRE_RANGE_M. (A hover craft's body stays level: its guns turn to the target by
## themselves, Flyer.aim_basis, so it need not point its nose down at it.)
const FIRE_CONE_RAD := 0.12
const MAX_DEPRESSION_RAD := 0.7
const FIRE_RANGE_M := 330.0
## The ground is read this many seconds ahead (a station is worked low and close, in the hills too).
const RUN_LOOK_AHEAD_S := 3.0
## Stick that takes a landed craft off again.
const TAKE_OFF_THROTTLE := 0.5

var phase := Phase.APPROACH
var point := Vector3.ZERO
var exit_point := Vector3.ZERO
## Seconds the station is still worked, and the radii of the engagement and of the orbit (m).
var loiter_left := 0.0
var engage_radius := 200.0
var orbit_radius := 110.0
var station_reach := 130.0
var run := Run.IN
var _pass_left := 0.0
var clockwise := true
## Frame time of the update in progress (the steering helpers below use it).
var _delta := 0.0


static func make(p_flyer: Flyer, p_point: Vector3, p_exit: Vector3, rule: Dictionary, loiter_s: float) -> CallinAttackPilot:
	var pilot := CallinAttackPilot.new(p_flyer)
	pilot.point = p_point
	pilot.exit_point = p_exit
	pilot.loiter_left = loiter_s
	pilot.engage_radius = float(rule.get("engage_radius_m", 200.0))
	pilot.orbit_radius = float(rule.get("orbit_radius_m", 110.0))
	pilot.station_reach = float(rule.get("station_reach_m", 130.0))
	p_flyer.altitude = float(rule.get("altitude_m", 45.0))
	return pilot


func is_done() -> bool:
	return phase == Phase.DONE


func is_on_station() -> bool:
	return phase == Phase.STATION


func is_leaving() -> bool:
	return phase == Phase.LEAVE or phase == Phase.DONE


## Gives up the station now (the caller is gone, the order was cancelled).
func apply_leave() -> void:
	if phase == Phase.APPROACH or phase == Phase.STATION:
		_enter_leave()


func update(delta: float) -> void:
	_delta = delta
	if flyer.flight.landed:
		_take_off()
		return
	match phase:
		Phase.APPROACH:
			_approach()
		Phase.STATION:
			_work_station(delta)
		Phase.LEAVE:
			_fly_out()
		Phase.DONE:
			_hold_fire()


func _take_off() -> void:
	_hold_fire()
	flyer.apply_controls(FlightControls.make(TAKE_OFF_THROTTLE, 0.0, Vector2.ZERO, 1.0))


func _approach() -> void:
	_hold_fire()
	_steer_to(point, flyer.altitude, APPROACH_SPEED_SHARE)
	if _flat_to(point).length() <= station_reach:
		phase = Phase.STATION


func _work_station(delta: float) -> void:
	loiter_left -= delta
	if loiter_left <= 0.0 or is_out_of_ammunition():
		_enter_leave()
		return
	_apply_target_search()
	if is_instance_valid(flyer.target) and flyer.target.alive:
		_strafe(delta)
	else:
		_orbit()


func _fly_out() -> void:
	_hold_fire()
	_steer_to(exit_point, flyer.altitude, APPROACH_SPEED_SHARE)
	if _flat_to(exit_point).length() <= EXIT_REACH_M:
		phase = Phase.DONE


func _enter_leave() -> void:
	flyer.target = null
	_hold_fire()
	phase = Phase.LEAVE


## True when the craft carries ammunition weapons and every one of them is empty.
func is_out_of_ammunition() -> bool:
	var counted := flyer.weapons.filter(func(w: Weapon) -> bool: return w.ammo_max > 0)
	return not counted.is_empty() and counted.all(func(w: Weapon) -> bool: return w.ammo == 0)


# ------------------------------------------------------------------ the station

## Nothing to shoot: round the ring about the point.
func _orbit() -> void:
	_hold_fire()
	var goal := FlightGoal.make_orbit(point, orbit_radius, flyer.altitude, clockwise)
	flyer.apply_flight(goal, flyer.cruise * ORBIT_SPEED_SHARE, _delta)


## One frame of a strafing run: in at the target (low, fast, firing), then on past it and up, then round again.
func _strafe(delta: float) -> void:
	var aim := flyer.target.global_position + Vector3.UP * FlyerAI.make_aim_height(flyer.target)
	var flat := _flat_to(aim)
	if run == Run.IN and flat.length() < PASS_DISTANCE_M:
		run = Run.OUT
		_pass_left = RUN_OUT_S
	elif run == Run.OUT:
		_pass_left -= delta
		if _pass_left <= 0.0 or flat.length() > RUN_OUT_RANGE_M:
			run = Run.IN
	if run == Run.IN:
		_run_in(aim, flat.length())
	else:
		_run_out()


func _run_in(aim: Vector3, distance: float) -> void:
	var descent := clampf((distance - RUN_DESCENT_START_M) / RUN_DESCENT_M, 0.0, 1.0)
	_steer_to(aim, lerpf(RUN_LOW_AGL_M, flyer.altitude, descent), RUN_SPEED_SHARE)
	var to := aim - flyer.global_position
	var flat := _flat_to(aim)
	var ahead := absf(flyer.pilot.make_heading_error(flyer.global_position, aim)) < FIRE_CONE_RAD and atan2(-to.y, maxf(flat.length(), 1.0)) < MAX_DEPRESSION_RAD
	var fire: bool = ahead and to.length() < FIRE_RANGE_M and LineOfSight.is_clear(flyer, flyer.aim_origin(), flyer.target, aim)
	for w in flyer.weapons:
		w.trigger = fire


## Straight on past the target, climbing away.
func _run_out() -> void:
	_hold_fire()
	var forward := -flyer.global_basis.z
	_steer_to(flyer.global_position + Vector3(forward.x, 0.0, forward.z) * RUN_OUT_RANGE_M, flyer.altitude, RUN_SPEED_SHARE)


## The nearest living hostile within the engagement radius of the point (FlyerAI's search is round the craft).
func _apply_target_search() -> void:
	if is_instance_valid(flyer.target) and flyer.target.alive and _is_in_reach(flyer.target):
		return
	var best: Herc = null
	var best_d := INF
	for v in flyer.get_tree().get_nodes_in_group("vehicles"):
		if not is_target(v):
			continue
		var d := _flat_between(v.global_position, point)
		if d <= engage_radius and d < best_d:
			best_d = d
			best = v
	flyer.target = best


## True when `v` is a unit this craft shoots: alive, hostile to it, not dormant, not riding inside a vehicle.
func is_target(v: Node) -> bool:
	var h := v as Herc
	if h == null or h == flyer or not h.alive or h.has_meta("dormant") or not TeamRelations.is_hostile(flyer.team, h.team):
		return false
	return not (h is Infantry and (h as Infantry).stowed)


func _is_in_reach(unit: Herc) -> bool:
	return _flat_between(unit.global_position, point) <= engage_radius * 1.25


# ------------------------------------------------------------------ aiming

## The direction a gun fires in from its muzzle so that the shot, which keeps the craft's own velocity, flies on to where
## the target will be: a craft at 80 m/s would otherwise put its fire metres beside a man. ZERO for a beam, a bomb or a
## gun without a living target (the weapon then aims at the crosshair point).
func make_lead_direction(weapon: Weapon, muzzle: Vector3) -> Vector3:
	if weapon.fires_beam() or weapon.kind in Weapon.DROPPED_KINDS or not is_instance_valid(flyer.target):
		return Vector3.ZERO
	var aim := flyer.target.global_position + Vector3.UP * FlyerAI.make_aim_height(flyer.target)
	var to := aim - muzzle
	if to.length() < 1.0:
		return Vector3.ZERO
	var carried := flyer.velocity * float(weapon.def.get("projectile", {}).get("inherit_velocity", 0.0))
	var flight_s := to.length() / maxf(weapon.projectile_speed + carried.dot(to.normalized()), 1.0)
	var target_move := Vector3.ZERO
	if flyer.target.get("velocity") is Vector3:
		target_move = flyer.target.get("velocity")
	return ((to + target_move * flight_s) / flight_s - carried).normalized()


# ------------------------------------------------------------------ steering

func _hold_fire() -> void:
	for w in flyer.weapons:
		w.trigger = false


## Steers for `goal` at `agl` metres over the ground (the pilot reads the ground ahead) at `speed_share` of the cruise speed.
func _steer_to(goal: Vector3, agl: float, speed_share: float) -> void:
	flyer.apply_flight(_make_point_goal(goal, agl), flyer.cruise * speed_share, _delta)


func _make_point_goal(goal: Vector3, agl: float) -> FlightGoal:
	var g := FlightGoal.make_point(goal, agl)
	g.crosses_edge = phase == Phase.LEAVE
	g.clearance = minf(agl, flyer.pilot.profile.clearance_m)
	if agl < flyer.altitude - 1.0:   # the run's descent to the target is flown low: the ground is read only a little way ahead
		g.look_ahead_s = RUN_LOOK_AHEAD_S
	return g


func _flat_to(goal: Vector3) -> Vector3:
	var to := goal - flyer.global_position
	return Vector3(to.x, 0.0, to.z)


static func _flat_between(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

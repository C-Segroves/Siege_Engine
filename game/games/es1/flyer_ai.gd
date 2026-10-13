class_name FlyerAI
extends RefCounted
## Built-in pilot of an AI flyer: patrols the flyer's path at its cruise height, attacks the
## nearest enemy with strafing runs (a straight pass beyond the target, then back) and dives to
## just above it on the final approach. It steers through the flyer's FlightModel autopilot
## (FlightModel.make_steering), so AI and player flyers obey the same physics.

## Faster on attack runs (fraction of the cruise speed; the model caps it at its maximum).
const ATTACK_SPEED_FACTOR := 1.3
const LOOK_AHEAD := 50.0
## Horizontal distance (m) at which a patrol point counts as reached. Banked turns are wider
## than the old flat turns, so this is a little more generous than the turn radius at cruise.
const PATROL_REACH := 60.0
const TARGET_AIM_HEIGHT := 4.0
const STRAFE_PASS_DISTANCE := 40.0
const STRAFE_RUN_TIME := 2.5
const DIVE_DISTANCE := 120.0
const DIVE_HEIGHT := 10.0
const FIRE_CONE := 0.25
const FIRE_RANGE := 300.0
const TARGET_SEARCH_RANGE := 600.0

var flyer: Flyer
var _run_t := 0.0


func _init(p_flyer: Flyer) -> void:
	flyer = p_flyer


## One frame: pick a target, steer towards the goal, fire when it is ahead.
func update(delta: float) -> void:
	_apply_target_search()
	var attacking: bool = is_instance_valid(flyer.target) and flyer.target.alive
	var goal := _make_goal(attacking)
	var to := goal - flyer.global_position
	var flat := Vector3(to.x, 0, to.z)
	_apply_run_timer(delta, flat, attacking)
	var heading_error := _make_heading_error(flat)
	var climb_error := _make_wanted_height(flat, attacking) - flyer.global_position.y
	var cruise := flyer.cruise * (ATTACK_SPEED_FACTOR if attacking else 1.0)
	flyer.apply_controls(flyer.flight.make_steering(heading_error, climb_error, flyer.make_throttle_for(cruise)))
	var ahead := (-flyer.global_basis.z).angle_to(to.normalized()) < FIRE_CONE
	var fire: bool = attacking and ahead and to.length() < FIRE_RANGE 		and LineOfSight.is_clear(flyer, flyer.aim_origin(), flyer.target, goal)
	for w in flyer.weapons:
		w.trigger = fire


## The target (when attacking), else the next patrol point (advanced when reached), else ahead.
func _make_goal(attacking: bool) -> Vector3:
	if attacking:
		return flyer.target.global_position + Vector3.UP * TARGET_AIM_HEIGHT
	if flyer.patrol.is_empty():
		return flyer.global_position - flyer.global_basis.z * LOOK_AHEAD
	var goal := flyer.patrol[flyer.patrol_i]
	if Vector2(goal.x - flyer.global_position.x, goal.z - flyer.global_position.z).length() < PATROL_REACH:
		flyer.patrol_i = (flyer.patrol_i + 1) % flyer.patrol.size()
	return goal


## A strafing run keeps going straight for a while after passing the target.
func _apply_run_timer(delta: float, flat: Vector3, attacking: bool) -> void:
	_run_t -= delta
	if attacking and flat.length() < STRAFE_PASS_DISTANCE:
		_run_t = STRAFE_RUN_TIME


## Signed horizontal angle to the goal (+ = to the left), 0 during a strafing run.
func _make_heading_error(flat: Vector3) -> float:
	if _run_t > 0.0 or flat.length() <= 1.0:
		return 0.0
	var fwd := -flyer.global_basis.z
	fwd.y = 0
	return fwd.normalized().signed_angle_to(flat.normalized(), Vector3.UP)


## Cruise height above the ground (or the target), close above the target on the final approach.
func _make_wanted_height(flat: Vector3, attacking: bool) -> float:
	if not attacking:
		return flyer.altitude + flyer.global_position.y - flyer.make_altitude()
	if flat.length() < DIVE_DISTANCE:
		return flyer.target.global_position.y + DIVE_HEIGHT
	return flyer.target.global_position.y + flyer.altitude


func _apply_target_search() -> void:
	if is_instance_valid(flyer.target) and flyer.target.alive:
		return
	var best: Herc = null
	var best_distance := TARGET_SEARCH_RANGE
	for v in flyer.get_tree().get_nodes_in_group("vehicles"):
		if v == flyer or not v.alive or not TeamRelations.is_hostile(flyer.team, v.team) or v.has_meta("dormant"):
			continue
		var d: float = flyer.global_position.distance_to(v.global_position)
		if d < best_distance:
			best_distance = d
			best = v
	flyer.target = best

class_name FlyerAI
extends RefCounted
## Built-in pilot of an AI flyer: patrols the flyer's path at its cruise height, attacks the
## nearest enemy with strafing runs (a straight pass beyond the target, then back) and dives to
## just above it on the final approach. It flies through the shared FlightPilot (engine/flight: banked
## turns, terrain look-ahead, obstacle and map-edge avoidance), so AI and player flyers obey the same physics.

## Faster on attack runs (fraction of the cruise speed; the model caps it at its maximum).
const ATTACK_SPEED_FACTOR := 1.3
const LOOK_AHEAD := 50.0
const TARGET_AIM_HEIGHT := 4.0
## A soldier is shot at this far above his feet: the middle of his body, not the middle of a Herc.
const INFANTRY_AIM_HEIGHT := 1.0
const STRAFE_PASS_DISTANCE := 40.0
const STRAFE_RUN_TIME := 2.5
const DIVE_DISTANCE := 120.0
const DIVE_HEIGHT := 10.0
const ATTACK_LOOK_AHEAD_S := 3.0
const FIRE_CONE := 0.25
const FIRE_RANGE := 300.0
const TARGET_SEARCH_RANGE := 600.0

var flyer: Flyer
var _run_t := 0.0


func _init(p_flyer: Flyer) -> void:
	flyer = p_flyer


## One frame: pick a target, fly towards the goal, fire when it is ahead.
func update(delta: float) -> void:
	_apply_target_search()
	var attacking: bool = is_instance_valid(flyer.target) and flyer.target.alive
	var aim := _make_aim_point(attacking)
	var to := aim - flyer.global_position
	var flat := Vector3(to.x, 0, to.z)
	_apply_run_timer(delta, flat, attacking)
	var goal := _make_goal(aim, flat, attacking)
	var cruise := flyer.cruise * (ATTACK_SPEED_FACTOR if attacking else 1.0)
	flyer.apply_flight(goal, cruise, delta)
	if goal.kind == FlightGoal.Kind.PATH:
		flyer.patrol_i = goal.index
	var ahead := (-flyer.global_basis.z).angle_to(to.normalized()) < FIRE_CONE
	var fire: bool = attacking and ahead and to.length() < FIRE_RANGE 		and LineOfSight.is_clear(flyer, flyer.aim_origin(), flyer.target, aim)
	for w in flyer.weapons:
		w.trigger = fire


## The direction `weapon` fires in from `muzzle` while the flyer has a living target (Herc.make_lead_direction); ZERO: the
## weapon fires at the crosshair point. A subclass may lead the shot.
func make_lead_direction(_weapon: Weapon, _muzzle: Vector3) -> Vector3:
	return Vector3.ZERO


## How far above its origin the flyers aim at `target`: a soldier's body is low, a Herc's centre is high.
static func make_aim_height(target: Node3D) -> float:
	return INFANTRY_AIM_HEIGHT if target is Infantry else TARGET_AIM_HEIGHT


## The target (when attacking), else the next patrol point, else ahead.
func _make_aim_point(attacking: bool) -> Vector3:
	if attacking:
		return flyer.target.global_position + Vector3.UP * make_aim_height(flyer.target)
	if flyer.patrol.is_empty():
		return flyer.global_position - flyer.global_basis.z * LOOK_AHEAD
	return flyer.patrol[flyer.patrol_i % flyer.patrol.size()]


## A strafing run keeps going straight for a while after passing the target.
func _apply_run_timer(delta: float, flat: Vector3, attacking: bool) -> void:
	_run_t -= delta
	if attacking and flat.length() < STRAFE_PASS_DISTANCE:
		_run_t = STRAFE_RUN_TIME


## The pilot's goal: straight on during a strafing run, the target at attack height, the patrol path, else ahead.
func _make_goal(aim: Vector3, flat: Vector3, attacking: bool) -> FlightGoal:
	var forward := -flyer.global_basis.z
	var goal: FlightGoal
	if _run_t > 0.0 or flat.length() <= 1.0 or (not attacking and flyer.patrol.is_empty()):
		goal = FlightGoal.make_straight(flyer.global_position, forward, flyer.altitude)
	elif attacking:
		goal = FlightGoal.make_point(aim, flyer.altitude)
	else:
		goal = FlightGoal.make_path(flyer.patrol, flyer.patrol_i, flyer.altitude)
	if attacking:
		goal.height_y = _make_attack_height(flat)
		if flat.length() < DIVE_DISTANCE:   # only the dive at the target is flown low, close to the ground
			goal.clearance = flyer.pilot.profile.dive_clearance_m   # the dive's floor is the profile's
			goal.look_ahead_s = ATTACK_LOOK_AHEAD_S
	return goal


## World height of an attack: close above the target on the final approach, else its cruise height above it.
func _make_attack_height(flat: Vector3) -> float:
	var base: float = flyer.target.global_position.y
	return base + (DIVE_HEIGHT if flat.length() < DIVE_DISTANCE else flyer.altitude)


func _apply_target_search() -> void:
	if is_instance_valid(flyer.target) and flyer.target.alive:
		return
	var best: Herc = null
	var best_distance := TARGET_SEARCH_RANGE
	for v in flyer.get_tree().get_nodes_in_group("vehicles"):
		if v == flyer or not v.alive or not TeamRelations.is_hostile(flyer.team, v.team) or v.has_meta("dormant") 				or CloakRules.is_hidden_from_radar(flyer, v):
			continue
		var d: float = flyer.global_position.distance_to(v.global_position)
		if d < best_distance:
			best_distance = d
			best = v
	flyer.target = best

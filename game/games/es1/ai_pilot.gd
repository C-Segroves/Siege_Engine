class_name AIPilot
extends Node
## Combat AI driven by the original mission orders:
##   SEARCH (search/destroy: hunt enemies anywhere), GUARD (hold, engage what comes close),
##   PATROL (loop the path, engage contacts), TRAVEL (follow the path once), SLEEP (idle until
##   alerted: hit, or an enemy within the alert radius), RAM (charge the target).
## A game mode may give it an objective (GameModeBrains): go there (urgent: whatever happens, e.g. a flag
## carrier running home), fighting on the way; hold there; shoot the objective's target (an enemy objective
## to destroy, the carrier to hunt).

enum Order { SEARCH, GUARD, PATROL, TRAVEL, SLEEP, RAM }

signal alerted(pilot: AIPilot)
signal path_finished(pilot: AIPilot)

## Herc meta set once its pilot reached the end of a path it travels once (mission rules read it: escorts).
const PATH_DONE_META := "path_done"

var herc: Herc
var order := Order.PATROL
var engaging := false
var patrol_points: Array[Vector3] = []
var patrol_index := 0
var loop_path := true
var guard_point := Vector3.ZERO
var formation_offset := Vector3.ZERO    # metres, relative to the leader's frame
var leader: Herc = null                 # follow this Herc in formation when set
var _leader_cloak_seen := false         # the leader's cloak wish last copied (copied when it changes)
var sensor_range := 900.0
var alert_range := 50000.0 * Assets.UNIT
var preferred_range := 150.0
var skill := 0.5
var _think := 0.0
## BotSleep tier: 0 NEAR (full), 1 MID (thinned target search, line of sight checked less often).
var ai_lod := 0
var _decisions := 0
var _strafe := 1.0
var _was_alerted := false
var _los_due_ms := 0
var _los_target: Node3D = null
var _los_clear := true
var _blocked_t := 0.0
var _detour_t := 0.0
var _detour_side := 1.0
## The game mode's goal ({} none): {point: Vector3, urgent: bool, radius: float, hold: bool, target: Node3D}.
var objective := {}

## Aim point height above the target's origin (m).
const TARGET_AIM_HEIGHT := 4.0
## Fire when the sight is within this angle (rad) of the aim point.
const FIRE_CONE := 0.12
const LOS_CHECK_SECONDS := 0.25
const MID_LOS_CHECK_SECONDS := 1.0
## Every tier decides at 5 Hz; a MID Herc searches for a target on every MID_SEARCH_EVERY-th decision only.
const THINK_SECONDS := 0.2
const MID_SEARCH_EVERY := 4
## Repositioning without line of sight: a goal this far toward the target and this far to the side (m).
const REPOSITION_AHEAD := 60.0
const REPOSITION_SIDE := 40.0
const REPOSITION_SPEED := 0.9
## Unsticking (remake rule: the originals' units are not traced to collide with buildings): a Herc driving with at
## least BLOCKED_THROTTLE that moves slower than BLOCKED_SPEED for BLOCKED_SECONDS turns DETOUR_ANGLE aside for
## DETOUR_SECONDS (alternating sides), then heads for its goal again.
const BLOCKED_THROTTLE := 0.3
const BLOCKED_SPEED := 0.5
const BLOCKED_SECONDS := 2.0
const DETOUR_SECONDS := 2.5
const DETOUR_ANGLE := PI / 3.0


static func order_from_original(code: int) -> int:
	match code:
		1: return Order.SEARCH
		3: return Order.RAM
		6: return Order.GUARD
		7, 8: return Order.PATROL
		10: return Order.SLEEP
		11: return Order.TRAVEL
	return Order.PATROL


func _ready() -> void:
	if herc:
		guard_point = herc.global_position
		herc.damaged.connect(func(_h, attacker):
			if attacker is Herc and attacker.team != herc.team:   # neutral teams (TeamRelations) still answer fire
				wake(attacker))


func wake(by: Node = null) -> void:
	if order == Order.SLEEP:
		order = Order.SEARCH
	if by is Herc:
		herc.target = by
		engaging = true
	if not _was_alerted:
		_was_alerted = true
		alerted.emit(self)


func _physics_process(delta: float) -> void:
	if herc == null or not herc.alive or not herc.is_inside_tree():
		return
	_think -= delta
	if _think <= 0.0:
		_think = _make_think_period()
		_reconsider()
	if order == Order.SLEEP:
		_idle()
		return
	if engaging and is_instance_valid(herc.target) and not bool(objective.get("urgent", false)):
		_attack()
	elif not objective.is_empty():
		_pursue_objective()
	else:
		_move_by_orders()


func _reconsider() -> void:
	_follow_leader_cloak()
	var range := sensor_range
	match order:
		Order.SLEEP:
			range = alert_range
		Order.GUARD:
			range = sensor_range * 0.6
		Order.SEARCH:
			range = 100000.0
	_decisions += 1
	var t: Herc
	if ai_lod > 0 and _decisions % MID_SEARCH_EVERY != 0 and is_instance_valid(herc.target) and herc.target.alive:
		t = herc.target
	else:
		t = _find_target(range)
	var hunted = objective.get("target")
	if hunted is Herc and is_instance_valid(hunted) and hunted.alive:
		t = hunted
	if t:
		if order == Order.SLEEP:
			wake(t)
		herc.target = t
		engaging = true
		if randf() < 0.3:
			_strafe = -_strafe
	else:
		engaging = false
		if herc.target and (not is_instance_valid(herc.target) or not herc.target.alive):
			herc.target = null


## A wingman cloaks when the leader he follows does (Starsiege training: "your squadmates have also cloaked").
func _follow_leader_cloak() -> void:
	if leader != null and is_instance_valid(leader) and herc.cloak.is_equipped() and leader.cloak_input != _leader_cloak_seen:
		_leader_cloak_seen = leader.cloak_input
		herc.cloak_input = _leader_cloak_seen


func _find_target(range: float) -> Herc:
	var best: Herc = null
	var best_d := range
	for v in herc.get_tree().get_nodes_in_group("vehicles"):
		var d: float = herc.global_position.distance_to(v.global_position)
		if d >= best_d:   # the signature only shortens how far a unit is seen: beyond the best so far, out (a native test first)
			continue
		if v == herc or not v.alive or not TeamRelations.is_hostile(herc.team, v.team) or v.has_meta("dormant"):
			continue
		if CloakRules.is_hidden_from_radar(herc, v):   # a cloaked unit the pilot's sensors do not find
			continue
		if d / RadarMode.make_signature(v) < best_d:   # a passive (EMCON) unit is seen from half as far
			best_d = d / RadarMode.make_signature(v)
			best = v
	return best


func _idle() -> void:
	herc.throttle = 0.0
	herc.turn = 0.0
	for w in herc.weapons:
		w.trigger = false


func _steer_to(point: Vector3, speed_frac: float) -> float:
	var to := point - herc.global_position
	to.y = 0
	var heading := make_detour_heading(to, get_physics_process_delta_time())
	var fwd := -herc.global_basis.z
	fwd.y = 0
	var ang := fwd.signed_angle_to(heading, Vector3.UP)
	herc.turn = clampf(-ang * 2.0, -1.0, 1.0)
	herc.throttle = speed_frac * clampf(1.0 - absf(ang) / PI, 0.2, 1.0)
	return to.length()


## The heading to steer along toward `to` (horizontal): `to` itself, or turned aside while a detour runs around
## whatever blocks the Herc (a building, a wreck, another Herc).
func make_detour_heading(to: Vector3, delta: float) -> Vector3:
	var dir := to.normalized()
	if _detour_t > 0.0:
		_detour_t -= delta
		return dir.rotated(Vector3.UP, DETOUR_ANGLE * _detour_side)
	var moving := Vector2(herc.velocity.x, herc.velocity.z).length() >= BLOCKED_SPEED
	_blocked_t = 0.0 if moving or herc.throttle < BLOCKED_THROTTLE else _blocked_t + delta
	if _blocked_t >= BLOCKED_SECONDS:
		_blocked_t = 0.0
		_detour_t = DETOUR_SECONDS
		_detour_side = -_detour_side
	return dir


func _move_by_orders() -> void:
	for w in herc.weapons:
		w.trigger = false
	herc.torso_target = 0.0
	herc.pitch_target = 0.0
	if is_instance_valid(leader) and leader.alive and leader != herc:
		var goal := leader.global_transform * formation_offset
		var d := _steer_to(goal, 0.9)
		if d < 8.0:
			herc.throttle = clampf(leader.speed / maxf(herc.max_speed, 0.1), 0.0, 1.0)
			herc.turn = 0.0
		return
	match order:
		Order.GUARD:
			if _steer_to(guard_point, 0.4) < 20.0:
				_idle()
		Order.SEARCH, Order.RAM:
			# no contact yet: sweep the patrol path if any, else hold
			if patrol_points.is_empty():
				_idle()
			else:
				_follow_path(0.6)
		_:
			_follow_path(0.5)


func _follow_path(speed_frac: float) -> void:
	if patrol_points.is_empty():
		_idle()
		return
	var d := _steer_to(patrol_points[patrol_index], speed_frac)
	if d < 25.0:
		if patrol_index + 1 >= patrol_points.size():
			if loop_path and order != Order.TRAVEL:
				patrol_index = 0
			else:
				herc.set_meta(PATH_DONE_META, true)
				path_finished.emit(self)
				order = Order.GUARD
				guard_point = patrol_points[-1]
		else:
			patrol_index += 1


func _attack() -> void:
	var t := herc.target
	if not t.alive:
		engaging = false
		return
	var to := t.global_position - herc.global_position
	var dist := to.length()
	var aim_pos := t.global_position + Vector3.UP * TARGET_AIM_HEIGHT
	var seen := _make_line_of_sight(t, aim_pos)
	if order == Order.RAM or _is_self_destructing():
		_steer_to(t.global_position, 1.0)
	elif not seen:
		_steer_to(_make_reposition_goal(to), REPOSITION_SPEED)
	else:
		_keep_preferred_range(to, dist)
	_aim_and_fire(to, aim_pos, seen)


func _aim_and_fire(to: Vector3, aim_pos: Vector3, seen: bool) -> void:
	_aim_at(to, aim_pos)
	var on_target := seen and (-herc.aim_basis().z).angle_to((aim_pos - herc.aim_origin()).normalized()) < FIRE_CONE
	for w in herc.weapons:
		w.trigger = on_target and to.length() < w.weapon_range


## Heads for the objective's point (holding there when asked) and shoots what it may on the way: the target it
## is engaging, else the objective's own target.
func _pursue_objective() -> void:
	var point: Vector3 = objective.point
	var urgent := bool(objective.get("urgent", false))
	if _steer_to(point, 1.0 if urgent else 0.8) < float(objective.get("radius", 20.0)) and bool(objective.get("hold", false)):
		herc.throttle = 0.0
		herc.turn = 0.0
	var t: Node3D = herc.target if engaging and is_instance_valid(herc.target) else objective.get("target")
	if t == null or not is_instance_valid(t) or not bool(t.get("alive")):
		for w in herc.weapons:
			w.trigger = false
		return
	var aim_pos := t.global_position + Vector3.UP * TARGET_AIM_HEIGHT
	_aim_and_fire(t.global_position - herc.global_position, aim_pos, _make_line_of_sight(t, aim_pos))


## Seconds between target choices: a Spider re-picks every retarget_s (DBSIM 0x18395), the others by skill.
func _make_think_period() -> float:
	if _is_self_destructing():
		return float(herc.def.self_destruct.retarget_s)
	return minf(lerpf(1.0, 0.35, skill), THINK_SECONDS)


## A unit that blows itself up on contact (the Spider) runs straight at its target (DBSIM 0x18320).
func _is_self_destructing() -> bool:
	return herc.is_self_destructing()


## Circles the target at the preferred range, strafing.
func _keep_preferred_range(to: Vector3, dist: float) -> void:
	var goal := herc.global_position + to
	if dist < preferred_range * 1.3:
		goal = herc.global_position + herc.global_basis.x * _strafe * 60.0 - to.normalized() * (preferred_range - dist)
	_steer_to(goal, 0.8 if dist > preferred_range else 0.5)


## Torso twist and pitch toward the aim point (with the skill's aiming error).
func _aim_at(to: Vector3, aim_pos: Vector3) -> void:
	var flat := Vector3(to.x, 0, to.z).normalized()
	var err := (1.0 - skill) * 0.08
	herc.torso_target = (-herc.global_basis.z).signed_angle_to(flat, Vector3.UP) + randf_range(-err, err)
	var eye := herc.aim_origin()
	var horiz := Vector2(aim_pos.x - eye.x, aim_pos.z - eye.z).length()
	herc.pitch_target = atan2(aim_pos.y - eye.y, horiz)


## Line of sight from the eye to the target, re-checked every LOS_CHECK_SECONDS (a ray per AI per frame is
## needless); terrain, buildings and other vehicles in between block it.
func _make_line_of_sight(t: Node3D, aim_pos: Vector3) -> bool:
	var now := Time.get_ticks_msec()
	if now >= _los_due_ms or t != _los_target:
		_los_due_ms = now + int((LOS_CHECK_SECONDS if ai_lod == 0 else MID_LOS_CHECK_SECONDS) * 1000.0)
		_los_target = t
		_los_clear = LineOfSight.is_clear(herc, herc.aim_origin(), t, aim_pos)
	return _los_clear


## Blocked: close in on the target while side-stepping (round the hill or building in the way, over the crest).
func _make_reposition_goal(to: Vector3) -> Vector3:
	var side := herc.global_basis.x * _strafe
	return herc.global_position + to.normalized() * REPOSITION_AHEAD + side * REPOSITION_SIDE

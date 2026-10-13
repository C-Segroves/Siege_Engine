class_name TribesBot
extends InfantryBot
## A training mission's AI soldier: the infantry bot (InfantryBot) under the mission script's orders
## (Tribes AI::DirectiveTarget / Tribes 2 AIConnection.stepEngage / stepMove):
##   HOLD    stays where it was spawned and fights only an enemy that comes within HOLD_REACT_RANGE (the
##           training bots wait for the script to send them, then defend themselves);
##   ENGAGE  hunts `engage_target` (the player) wherever he is, else the nearest enemy;
##   MOVE    walks to `move_goal`, fighting enemies that come near on the way; with a patrol (Tribes createAI on
##           a path group) it walks the path's points round and round.
## It never boards vehicles (the scripts seat their pilots themselves).

enum Order { HOLD, ENGAGE, MOVE }

const HOLD_REACT_RANGE := 60.0
## A patrol point counts as reached this near (metres, horizontally).
const PATROL_REACH := 4.0

var order := Order.HOLD
var engage_target: Herc = null
var move_goal := Vector3.ZERO
var patrol: Array[Vector3] = []
var _patrol_index := 0


static func make_scripted(s: Infantry, id: int, p_skill: float) -> TribesBot:
	var b := TribesBot.new()
	b.soldier = s
	b.bot_id = id
	b.skill = p_skill
	b.name = "Bot"
	return b


func apply_engage(t: Herc) -> void:
	order = Order.ENGAGE
	engage_target = t
	_think = 0.0


func apply_move(p: Vector3) -> void:
	order = Order.MOVE
	move_goal = p
	_think = 0.0


func apply_hold() -> void:
	order = Order.HOLD
	engage_target = null
	_think = 0.0


## Walks `points` in order, round and round (MOVE).
func apply_patrol(points: Array[Vector3]) -> void:
	patrol = points
	_patrol_index = 0
	if not patrol.is_empty():
		apply_move(patrol[0])


func _advance_patrol() -> void:
	if order != Order.MOVE or patrol.size() < 2:
		return
	var to := move_goal - soldier.global_position
	if Vector2(to.x, to.z).length() < PATROL_REACH:
		_patrol_index = (_patrol_index + 1) % patrol.size()
		move_goal = patrol[_patrol_index]


func _reconsider() -> void:
	if soldier.stowed:
		return
	_advance_patrol()
	target = _make_order_target()
	var d := soldier.global_position.distance_to(target.global_position) if target else INF
	if target and randf() < 0.3:
		_strafe = -_strafe
	if target and d < FIGHT_RANGE:
		task = Task.COVER if soldier.integrity < COVER_INTEGRITY else Task.FIGHT
		goal = _find_cover(target) if task == Task.COVER else _make_fight_point(d)
	elif order == Order.ENGAGE and target:
		task = Task.ROAM
		goal = target.global_position
	else:
		task = Task.ROAM
		goal = move_goal if order == Order.MOVE else soldier.global_position
	_apply_weapon_choice(d)


func _make_order_target() -> Herc:
	match order:
		Order.ENGAGE:
			if is_instance_valid(engage_target) and engage_target.alive:
				return engage_target
			return _find_target(INF)
		Order.MOVE:
			return _find_target(HOLD_REACT_RANGE)
	return _find_target(HOLD_REACT_RANGE)

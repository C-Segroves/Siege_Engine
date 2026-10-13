class_name InfantryBotRoute
extends RefCounted
## The way an AI soldier gets to its goal (InfantryBot). In the open he goes as the Tribes bots did: straight at
## the goal, running, skiing and jetting over the terrain. Where a building stands in his way (the straight line
## ahead hits an interior or structure, not the terrain) he follows a walkable path (BattleNavigation) into or out
## of the base instead. Past the path's end (a goal on a roof, a ledge the walkable surface doesn't reach), while
## its tiles are still baking, or when following the path stops shortening the way left (STUCK_SECONDS: a ledge
## too high, a jet that falls short) he goes straight again for a while, as before navigation existed.

## A new path is asked for when the goal moved this far, or this often.
const REPATH_DISTANCE := 4.0
const REPATH_SECONDS := 3.0
## With no path, or its end reached short of the goal, it asks again this often.
const SPENT_REPATH_SECONDS := 0.5
## A path point counts as reached this near (horizontal metres) and within this height.
const POINT_REACH := 1.5
const POINT_HEIGHT := 2.5
## Goals nearer than this are walked to straight (a fight, a hatch at arm's length).
const DIRECT_DISTANCE := 8.0
## The look ahead for a building in the way: this far along the straight line, at chest height.
const LOOK_AHEAD := 40.0
const CHEST := 1.2
## The way left along the path shortened by less than STUCK_PROGRESS metres in STUCK_SECONDS: straight (and
## jetting up to the goal) for GIVE_UP_SECONDS.
const STUCK_SECONDS := 6.0
const STUCK_PROGRESS := 1.0
const GIVE_UP_SECONDS := 5.0

var _path := PackedVector3Array()
var _index := 0
var _goal := Vector3.INF
var _age := 0.0
var _straight_left := 0.0
var _watch_t := 0.0
var _watch_best := INF


## The point to head for now on the way from `at` to `goal` (`battle`: the navigation's owner).
func make_next_point(battle: Node3D, at: Vector3, goal: Vector3, delta: float) -> Vector3:
	_straight_left -= delta
	if Vector2(goal.x - at.x, goal.z - at.z).length() < DIRECT_DISTANCE or _straight_left > 0.0:
		return goal
	_age += delta
	if _path.is_empty() and _age < SPENT_REPATH_SECONDS:
		return goal
	if _path.is_empty() and not is_building_ahead(battle, at, goal) and not _goal_inside(battle, goal):
		_age = 0.0
		return goal   # open ground: straight, as the Tribes bots ran and skied
	var spent := _index >= _path.size()
	if _goal.distance_to(goal) > REPATH_DISTANCE or _age > (SPENT_REPATH_SECONDS if spent else REPATH_SECONDS):
		_apply_new_path(battle, at, goal)
	while _index < _path.size() and _is_reached(at, _path[_index]):
		_index += 1
	if _index >= _path.size():
		return goal
	_apply_stuck_watch(make_remaining_length(at), delta)
	return _path[_index] if _straight_left <= 0.0 else goal


## True when the straight line from `at` toward `goal` meets a building (not the terrain) within LOOK_AHEAD.
static func is_building_ahead(battle: Node3D, at: Vector3, goal: Vector3) -> bool:
	var from := at + Vector3.UP * CHEST
	var to := goal + Vector3.UP * CHEST
	if from.distance_to(to) > LOOK_AHEAD:
		to = from + (to - from).normalized() * LOOK_AHEAD
	var q := PhysicsRayQueryParameters3D.create(from, to)
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty() and hit.collider is StaticBody3D and not (hit.collider as Node).is_in_group("terrain")


## Forgets the path (a new task).
func clear() -> void:
	_path = PackedVector3Array()
	_index = 0
	_goal = Vector3.INF


## The path being followed (tests).
func make_path() -> PackedVector3Array:
	return _path


func _apply_new_path(battle: Node3D, at: Vector3, goal: Vector3) -> void:
	_age = 0.0
	_goal = goal
	_path = BattleNavigation.of(battle).make_path(at, goal) if is_building_ahead(battle, at, goal) or _goal_inside(battle, goal) \
		else PackedVector3Array()
	_index = 0


## A goal under a roof (inside a building): the path is kept up to it even when the way ahead looks clear.
static func _goal_inside(battle: Node3D, goal: Vector3) -> bool:
	var from := goal + Vector3.UP * CHEST
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.UP * LOOK_AHEAD)
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(q)
	return not hit.is_empty() and not (hit.collider as Node).is_in_group("terrain")


## The way left along the path from `at`: to the current point, then point to point to its end.
func make_remaining_length(at: Vector3) -> float:
	if _index >= _path.size():
		return 0.0
	var total := at.distance_to(_path[_index])
	for i in range(_index, _path.size() - 1):
		total += _path[i].distance_to(_path[i + 1])
	return total


## Gives the path up for GIVE_UP_SECONDS when following it does not shorten the way left (`remaining`, metres):
## a path that circles a ledge he cannot climb. A way round (out of the door first) shortens it all along.
func _apply_stuck_watch(remaining: float, delta: float) -> void:
	if remaining < _watch_best - STUCK_PROGRESS:
		_watch_best = remaining
		_watch_t = 0.0
		return
	_watch_t += delta
	if _watch_t >= STUCK_SECONDS:
		_watch_t = 0.0
		_watch_best = INF
		_straight_left = GIVE_UP_SECONDS
		clear()


static func _is_reached(at: Vector3, p: Vector3) -> bool:
	return Vector2(p.x - at.x, p.z - at.z).length() <= POINT_REACH and absf(p.y - at.y) <= POINT_HEIGHT

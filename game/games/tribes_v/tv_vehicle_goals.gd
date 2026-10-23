class_name TVVehicleGoals
extends RefCounted
## The AI goals of a crewed Tribes: Vengeance vehicle (the script ops ActionAddGoal / ActionReplaceGoal / ActionRemoveGoal on a vehicle's
## label, tools/tv_script.py "goal"): the vehicle keeps its goals by name (TVNpcGoals.apply) and the one of highest Priority steers its pilot
## through the shared AIOrder (VehicleOrders), the way the original's goal arbiter did for a pilot:
##   vehicle_patrol  fly or drive the listed nodes in turn, round and round, or once (bExecuteOnce) and then the goal is achieved;
##   vehicle_move    go to the node (an urgent order); achieved on arrival;
##   vehicle_attack  hunt the target (a vehicle or soldier by label, "Player" the player); achieved when it is dead;
##   vehicle_guard   hold where the vehicle stands.
## `expel` (AI_VehicleExpellOccupantGoal) is not a goal that steers: it puts the pilot out (TVVehicleFleet.apply_goal).
## An achieved goal is removed and the next one takes over (a MoveTo then a Patrol is the usual pair). At equal Priority the goal that is
## done once (move, attack) comes before the one that repeats (patrol, guard). Steering is host-side; positions are engine metres.

const KIND_PATROL := "vehicle_patrol"
const KIND_MOVE := "vehicle_move"
const KIND_ATTACK := "vehicle_attack"
const KIND_GUARD := "vehicle_guard"
const KIND_EXPEL := "expel"
const KINDS := [KIND_PATROL, KIND_MOVE, KIND_ATTACK, KIND_GUARD]
## At equal priority the lower rank is served first.
const RANK := {KIND_MOVE: 0, KIND_ATTACK: 1, KIND_PATROL: 2, KIND_GUARD: 3}
## How close a place counts as reached (m): an aircraft turns wide.
const REACHED_FLYER_M := 70.0
const REACHED_GROUND_M := 20.0
const MIN_CRUISE_MPS := 8.0


static func is_vehicle_goal(goal: Dictionary) -> bool:
	return KINDS.has(str(goal.get("kind", "")))


## The goal of highest priority ({} when none), a goal that is done once before one that repeats at equal priority.
static func make_top_goal(e: Dictionary) -> Dictionary:
	var best := {}
	for g in (e.goals as Dictionary).values():
		if not is_vehicle_goal(g):
			continue
		if best.is_empty() or _outranks(g, best):
			best = g
	return best


static func _outranks(a: Dictionary, b: Dictionary) -> bool:
	var pa := int(a.get("priority", TVNpcGoals.DEFAULT_PRIORITY))
	var pb := int(b.get("priority", TVNpcGoals.DEFAULT_PRIORITY))
	return pa > pb or (pa == pb and int(RANK[a.kind]) < int(RANK[b.kind]))


## The order that carries out `g` for the vehicle `h` that stands at `spawn` (null when the goal names nothing it can find).
## `ctx`: {actors: label -> [x, y, z], player: Vector3, node_of: Callable(label) -> Node3D}.
static func make_order(g: Dictionary, h: Herc, spawn: Vector3, ctx: Dictionary) -> AIOrder:
	match str(g.kind):
		KIND_PATROL:
			return _make_patrol(g, ctx)
		KIND_MOVE:
			var at := _point(str(g.get("dest", "")), ctx)
			return null if at == Vector3.INF else AIOrder.make_plan(AIOrder.MOVE, at, true, make_reach(h), true)
		KIND_ATTACK:
			var target: Node3D = ctx.node_of.call(str(g.get("target", "")))
			return null if target == null else AIOrder.make(AIOrder.ATTACK, target.global_position, target)
		KIND_GUARD:
			return AIOrder.make_hold_at(spawn)
	return null


static func _make_patrol(g: Dictionary, ctx: Dictionary) -> AIOrder:
	var pts: Array[Vector3] = []
	for label in g.get("points", []):
		var at := _point(str(label), ctx)
		if at != Vector3.INF:
			pts.append(at)
	if pts.is_empty():
		return null
	var once := bool(g.get("once", false))
	return AIOrder.make_route(AIOrder.TRAVEL if once else AIOrder.PATROL, pts, not once)


## True when `g` is achieved: the place reached (a patrol that is done once: its last node), the target dead.
static func is_achieved(g: Dictionary, h: Herc, order: AIOrder, ctx: Dictionary) -> bool:
	match str(g.kind):
		KIND_MOVE:
			return order != null and _flat_distance(h, order.point) <= make_reach(h)
		KIND_PATROL:
			return bool(g.get("once", false)) and order != null and not order.path.is_empty() \
				and _flat_distance(h, order.path[order.path.size() - 1]) <= make_reach(h)
		KIND_ATTACK:
			var target: Node3D = ctx.node_of.call(str(g.get("target", "")))
			return target == null or not target.get("alive")
	return false


static func make_reach(h: Herc) -> float:
	return REACHED_FLYER_M if h is Flyer else REACHED_GROUND_M


## A flyer flies the goal's DesiredSpeed (m/s) as its cruise; other vehicles ignore it.
static func apply_speed(g: Dictionary, h: Herc) -> void:
	if h is Flyer and g.has("speed"):
		(h as Flyer).cruise = clampf(float(g.speed), MIN_CRUISE_MPS, h.max_speed)


static func _flat_distance(h: Herc, p: Vector3) -> float:
	return Vector2(h.global_position.x - p.x, h.global_position.z - p.z).length()


static func _point(label: String, ctx: Dictionary) -> Vector3:
	return TVNpcGoals.make_point(label, ctx.actors, ctx.player)

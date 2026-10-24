class_name TVNpcGoals
extends RefCounted
## The AI goals of Tribes: Vengeance's placed soldiers (the script ops ActionAddGoal / ActionReplaceGoal / ActionRemoveGoal,
## tools/tv_script.py "goal"): each soldier keeps its goals by name, and the one of highest Priority steers its brain
## (InfantryBot) the way the original's goal arbiter did:
##   move    walk to the node (an urgent goal, priority >= URGENT_PRIORITY, ignores a fight on the way);
##   guard   stay within the goal's movement area, whose centre is the node or the player;
##   wander  roam WANDER_RADIUS around the spawn;
##   attack  hunt the nearest enemy anywhere (the brain's guard-less roaming);
##   follow  keep within the goal's proximity of the player or a node;
##   patrol  walk the listed nodes in turn (once, or round and round);
##   enter_vehicle  walk to the vehicle's hull (AI_EnterVehicleGoal: vehicleOrTurretName, VehiclePosition = the seat) and climb in
##           (make_boarding_goal says when he is there; TVMissionRuntime boards him).
## The walking goals become an AIOrder (the order the command map, the game modes and the vehicle goals use too) whose objective the brain
## carries out.
## Every soldier starts with the implicit DEFAULT_GOAL: guard the spawn within GUARD_RADIUS. Goals of kinds the engine does
## not act on (vehicle, turret, animation, ski) were not exported. Steering is host-side; positions are engine metres.

const DEFAULT_GOAL := "DefaultGuardGoal"
const DEFAULT_PRIORITY := 10
const URGENT_PRIORITY := 60
const GUARD_RADIUS := 25.0
const MIN_AREA_RADIUS := 8.0
const MAX_AREA_RADIUS := 60.0
const WANDER_RADIUS := 60.0
const ARRIVE_RADIUS := 3.0
const PATROL_REACHED := 4.0
const PLAYER_LABEL := "player"
## A goal that gives the soldier nothing to do (the default removed, nothing added): it holds this tight area.
const IDLE_RADIUS := 2.0
const KIND_ENTER := "enter_vehicle"
## A soldier climbs into a vehicle once he is this near its hull (m), the radius of a hull included.
const BOARD_REACH_M := 2.5
## The stand-off from a vehicle that has no hull radius to read (a script position).
const BOARD_POINT_RADIUS_M := 4.0
## The soldier's stop is not exact: this much further still counts as at the hull, and no more than this far above or below it.
const ARRIVE_SLACK_M := 1.5
const BOARD_HEIGHT_M := 6.0


## Updates the goals of the NPC entry `e` ({goals: {name: goal}, default_removed: bool}) for one script op.
static func apply(e: Dictionary, mode: String, name: String, goal: Dictionary) -> void:
	var goals: Dictionary = e.goals
	if mode == "remove":
		if name == DEFAULT_GOAL:
			e["default_removed"] = true
		goals.erase(name)
		return
	if mode == "replace":
		if name == DEFAULT_GOAL:
			e["default_removed"] = true
		goals.erase(name)
	var key := str(goal.get("name", ""))
	if key == "":
		key = "%s#%d" % [goal.kind, goals.size()]
	var own := goal.duplicate()
	own["key"] = key
	goals[key] = own
	e["patrol_index"] = 0


## The goal of highest priority ({} = only the implicit default guard goal, or none after its removal).
static func make_top_goal(e: Dictionary) -> Dictionary:
	var best := {}
	for g in (e.goals as Dictionary).values():
		if best.is_empty() or int(g.get("priority", DEFAULT_PRIORITY)) > int(best.priority):
			best = g
	return best


## Writes the steering of entry `e` onto its brain. `actors`: label -> [x, y, z] of the script's named actors;
## `player`: where the player stands; `spawn`: the soldier's placed position; `find_vehicle`: Callable(label) -> the vehicle (Herc) of that
## label or null (an enter_vehicle goal walks to it, else to the actor's position).
static func steer(e: Dictionary, actors: Dictionary, player: Vector3, spawn: Vector3, find_vehicle := Callable()) -> void:
	var brain = e.get("brain")
	if brain == null or not is_instance_valid(brain) or not is_instance_valid(brain.soldier):
		return
	brain.objective = {}
	brain.guard_point = spawn
	brain.guard_radius = IDLE_RADIUS if bool(e.get("default_removed", false)) else GUARD_RADIUS
	var g := make_top_goal(e)
	if g.is_empty():
		return
	match str(g.kind):
		"move":
			_apply_order(brain, make_move_order(g, actors, player))
		KIND_ENTER:
			_apply_order(brain, make_enter_order(g, actors, player, find_vehicle))
		"guard":
			var centre := make_point(str(g.get("center", "")), actors, player)
			brain.guard_point = spawn if centre == Vector3.INF else centre
			brain.guard_radius = clampf(float(g.get("radius", 0.0)), MIN_AREA_RADIUS, MAX_AREA_RADIUS)
		"wander":
			brain.guard_radius = WANDER_RADIUS
		"attack":
			brain.guard_radius = 0.0
		"follow":
			var who := make_point(str(g.get("target", "")), actors, player)
			if who != Vector3.INF:
				brain.guard_point = who
				brain.guard_radius = clampf(float(g.get("radius", 0.0)), MIN_AREA_RADIUS, MAX_AREA_RADIUS)
		"patrol":
			_steer_patrol(e, g, brain, actors, player)


## The brain carries out `order` as its objective (no order: none).
static func _apply_order(brain, order: AIOrder) -> void:
	brain.objective = order.to_objective() if order != null else {}


## A move goal: walk to the node; urgent (ignores a fight on the way) at priority URGENT_PRIORITY and above. Null when the node is unknown.
static func make_move_order(g: Dictionary, actors: Dictionary, player: Vector3) -> AIOrder:
	var at := make_point(str(g.get("dest", "")), actors, player)
	if at == Vector3.INF:
		return null
	return AIOrder.make_plan(AIOrder.MOVE, at, int(g.get("priority", DEFAULT_PRIORITY)) >= URGENT_PRIORITY, ARRIVE_RADIUS, true)


## An enter-vehicle goal: walk, urgently, to the vehicle's hull. Null when the script knows no such vehicle.
static func make_enter_order(g: Dictionary, actors: Dictionary, player: Vector3, find_vehicle: Callable) -> AIOrder:
	var label := str(g.get("vehicle", ""))
	var vehicle: Herc = find_vehicle.call(label) if find_vehicle.is_valid() else null
	if vehicle != null:
		return AIOrder.make_plan(AIOrder.MOVE, vehicle.global_position, true, BoardingRules.make_hull_radius(vehicle) + BOARD_REACH_M, true)
	var at := make_point(label, actors, player)
	return null if at == Vector3.INF else AIOrder.make_plan(AIOrder.MOVE, at, true, BOARD_POINT_RADIUS_M, true)


## The top goal of `e` when it is an enter-vehicle goal and the soldier stands at the vehicle's hull ({} otherwise): the moment to board.
static func make_boarding_goal(e: Dictionary, find_vehicle: Callable) -> Dictionary:
	var brain = e.get("brain")
	var g := make_top_goal(e)
	if g.is_empty() or str(g.kind) != KIND_ENTER or brain == null or not is_instance_valid(brain) or not is_instance_valid(brain.soldier):
		return {}
	var vehicle: Herc = find_vehicle.call(str(g.get("vehicle", "")))
	if vehicle == null or not vehicle.alive:
		return {}
	var gap: Vector3 = brain.soldier.global_position - vehicle.global_position
	var reach := BoardingRules.make_hull_radius(vehicle) + BOARD_REACH_M + ARRIVE_SLACK_M
	return g if Vector2(gap.x, gap.z).length() <= reach and absf(gap.y) <= BOARD_HEIGHT_M else {}


static func _steer_patrol(e: Dictionary, g: Dictionary, brain, actors: Dictionary, player: Vector3) -> void:
	var points: Array = g.get("points", [])
	if points.is_empty():
		return
	var i := int(e.get("patrol_index", 0)) % points.size()
	var at := make_point(str(points[i]), actors, player)
	if at == Vector3.INF:
		e["patrol_index"] = i + 1
		return
	var flat := Vector2(at.x - brain.soldier.global_position.x, at.z - brain.soldier.global_position.z)
	if flat.length() < PATROL_REACHED:
		if bool(g.get("once", false)) and i == points.size() - 1:
			(e.goals as Dictionary).erase(g.key)
			return
		i = (i + 1) % points.size()
		e["patrol_index"] = i
		at = make_point(str(points[i]), actors, player)
	if at != Vector3.INF:
		_apply_order(brain, AIOrder.make_plan(AIOrder.MOVE, at, false, ARRIVE_RADIUS, false))


## The position of the actor `label` ("Player" = the player), Vector3.INF when unknown.
static func make_point(label: String, actors: Dictionary, player: Vector3) -> Vector3:
	if label.to_lower() == PLAYER_LABEL:
		return player
	var at: Array = actors.get(label, [])
	if at.size() < 3:
		return Vector3.INF
	return Vector3(float(at[0]), float(at[1]), float(at[2]))

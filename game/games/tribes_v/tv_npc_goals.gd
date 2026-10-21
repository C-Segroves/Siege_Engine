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
##   patrol  walk the listed nodes in turn (once, or round and round).
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
## `player`: where the player stands; `spawn`: the soldier's placed position.
static func steer(e: Dictionary, actors: Dictionary, player: Vector3, spawn: Vector3) -> void:
	var brain = e.get("brain")
	if brain == null or not is_instance_valid(brain) or not is_instance_valid(brain.soldier):
		return
	brain.objective = {}
	brain.guard_point = spawn
	brain.guard_radius = IDLE_RADIUS if bool(e.get("default_removed", false)) else GUARD_RADIUS
	var g := make_top_goal(e)
	if g.is_empty():
		return
	var priority := int(g.get("priority", DEFAULT_PRIORITY))
	match str(g.kind):
		"move":
			var at := _make_point(str(g.get("dest", "")), actors, player)
			if at != Vector3.INF:
				brain.objective = {"point": at, "urgent": priority >= URGENT_PRIORITY, "radius": ARRIVE_RADIUS, "hold": true}
		"guard":
			var centre := _make_point(str(g.get("center", "")), actors, player)
			brain.guard_point = spawn if centre == Vector3.INF else centre
			brain.guard_radius = clampf(float(g.get("radius", 0.0)), MIN_AREA_RADIUS, MAX_AREA_RADIUS)
		"wander":
			brain.guard_radius = WANDER_RADIUS
		"attack":
			brain.guard_radius = 0.0
		"follow":
			var who := _make_point(str(g.get("target", "")), actors, player)
			if who != Vector3.INF:
				brain.guard_point = who
				brain.guard_radius = clampf(float(g.get("radius", 0.0)), MIN_AREA_RADIUS, MAX_AREA_RADIUS)
		"patrol":
			_steer_patrol(e, g, brain, actors, player)


static func _steer_patrol(e: Dictionary, g: Dictionary, brain, actors: Dictionary, player: Vector3) -> void:
	var points: Array = g.get("points", [])
	if points.is_empty():
		return
	var i := int(e.get("patrol_index", 0)) % points.size()
	var at := _make_point(str(points[i]), actors, player)
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
		at = _make_point(str(points[i]), actors, player)
	if at != Vector3.INF:
		brain.objective = {"point": at, "urgent": false, "radius": ARRIVE_RADIUS, "hold": false}


## The position of the actor `label` ("Player" = the player), Vector3.INF when unknown.
static func _make_point(label: String, actors: Dictionary, player: Vector3) -> Vector3:
	if label.to_lower() == PLAYER_LABEL:
		return player
	var at: Array = actors.get(label, [])
	if at.size() < 3:
		return Vector3.INF
	return Vector3(float(at[0]), float(at[1]), float(at[2]))

class_name AAMissionRuntime
extends MissionRuntimeBase
## Runs a Tribes: Aerial Assault mission inside a Battle (docs/formats/aerial_assault.md, "Game side").
##
## The disc's scripted mission logic (campaign_logic: AddBot, AddWaypoint, objective triggers ...) lives in the PS2
## executable and is not read, so this runtime plays only what the imported map says, with ONE fallback rule:
##   reach and destroy   the targets are the map's generators (the enemy's: team != 0 when the map has any); with no
##                       generator the mission's waypoints, to be reached in order; with neither, survive
##                       SURVIVE_SECONDS. Destroying every generator (TribesBase.object_destroyed) or reaching the
##                       last waypoint ends the mission as won; the player's death loses it (Battle).
## The objectives panel shows the mission's own notes (OBJECTIVES.BIN text) followed by the progress line.
## The player is a Tribes 2 soldier (the look-alike armour); stations, generators and turrets are Tribes 2 base
## equipment (TribesBase.SPEC_PACK_FALLBACK). No enemy soldiers are spawned yet.

const PACK := "tribes_aa"
const RUNTIME_KEY := "tribes_aa"
const ARMOR := "tribes2:MEDIUM"
const CODE_SUCCESS := 1
const CODE_FAILED := 6
const CHECK_INTERVAL := 0.25
const REACH_METRES := 15.0
const SURVIVE_SECONDS := 300.0
const SPAWN_LIFT := 1.0
const TARGET_MATCH_METRES := 3.0
const PLAYER_TEAM := 0
const GOAL_GENERATORS := "generators"
const GOAL_WAYPOINTS := "waypoints"
const GOAL_SURVIVE := "survive"

var map := {}
var goal := GOAL_SURVIVE
var targets: Array[Dictionary] = []     # {pos: Vector3, done: bool}
var waypoint_index := 0
var elapsed := 0.0
var _base_hooked := false


static func is_aa(mission: Dictionary) -> bool:
	return String(mission.get("runtime", "")) == RUNTIME_KEY


static func apply_world_to_config(config: Dictionary, mission: Dictionary) -> void:
	config.map = String(mission.get("map", ""))


static func make_mission_herc(_mission: Dictionary) -> Dictionary:
	return {"vehicle": ARMOR, "loadout": []}


static func is_mission_herc_forced() -> bool:
	return true


## Which fallback goal a map gets: "generators", else "waypoints", else "survive".
static func make_goal(m: Dictionary) -> String:
	if not _make_generators(m).is_empty():
		return GOAL_GENERATORS
	if not (m.get("waypoints", []) as Array).is_empty():
		return GOAL_WAYPOINTS
	return GOAL_SURVIVE


## Generator positions the player must destroy: the enemy's (team != PLAYER_TEAM), else all of them.
static func _make_generators(m: Dictionary) -> Array[Vector3]:
	var all: Array[Vector3] = []
	var enemy: Array[Vector3] = []
	for s in m.get("stations", []):
		if str(s.get("kind", "")) != "generator":
			continue
		var p: Array = s.pos
		var v := Vector3(float(p[0]), float(p[1]), float(p[2]))
		all.append(v)
		if int(s.get("team", -1)) != PLAYER_TEAM:
			enemy.append(v)
	return enemy if not enemy.is_empty() else all


static func _make_waypoints(m: Dictionary) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for w in m.get("waypoints", []):
		var p: Array = w.pos
		out.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	return out


func setup(p_battle: Node3D, mission: Dictionary, vars := PackedInt32Array()) -> void:
	super.setup(p_battle, mission, vars)
	map = MapBuilder.load_map(String(m.get("map", "")))
	goal = make_goal(map)
	match goal:
		GOAL_GENERATORS:
			for p in _make_generators(map):
				targets.append({"pos": p, "done": false})
		GOAL_WAYPOINTS:
			for p in _make_waypoints(map):
				targets.append({"pos": p, "done": false})
	_build_markers()


func _build_markers() -> void:
	for i in targets.size():
		var n := Marker3D.new()
		n.position = targets[i].pos
		n.set_meta("label", str(i + 1))
		n.add_to_group("nav_points")
		nav_points.append(n.position)
		battle.add_child(n)


## The first infantry start of the player's team (the first start of the map without one), lifted off the ground.
func player_spawn(_k: int) -> Transform3D:
	var best := {}
	for s in map.get("spawns", []):
		if str(s.get("kind", "")) != "infantry":
			continue
		if best.is_empty():
			best = s
		if int(s.get("team", 0)) == PLAYER_TEAM:
			best = s
			break
	if best.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0, float(map.get("ground_y", 0.0)) + SPAWN_LIFT, 0))
	var p: Array = best.pos
	return Transform3D(Basis(Vector3.UP, deg_to_rad(float(best.get("yaw", 0.0)))),
		Vector3(float(p[0]), float(p[1]) + SPAWN_LIFT, float(p[2])))


func _physics_process(delta: float) -> void:
	if _over or battle == null or not multiplayer.is_server():
		return
	elapsed += delta
	if make_rules_step(delta, CHECK_INTERVAL) <= 0.0:
		return
	_hook_base()
	match goal:
		GOAL_WAYPOINTS:
			_check_waypoints()
		GOAL_SURVIVE:
			if elapsed >= SURVIVE_SECONDS:
				end_mission(true, CODE_SUCCESS, "Mission complete.")


## TribesBase is built after the runtime: connect to it on the first tick it exists.
func _hook_base() -> void:
	if _base_hooked or goal != GOAL_GENERATORS:
		return
	var base := TribesBase.of(battle)
	if base == null:
		return
	_base_hooked = true
	base.object_destroyed.connect(_on_object_destroyed)


func _on_object_destroyed(obj: TribesBaseObject, _killer: Node) -> void:
	if _over or obj.kind != TribesBaseObject.KIND_GENERATOR:
		return
	for t in targets:
		if not t.done and (t.pos as Vector3).distance_to(obj.global_position) < TARGET_MATCH_METRES:
			t.done = true
			break
	if targets.all(func(t: Dictionary) -> bool: return t.done):
		end_mission(true, CODE_SUCCESS, "Generators destroyed. Mission complete.")


func _check_waypoints() -> void:
	var p: Herc = battle.player
	if p == null or not is_instance_valid(p) or waypoint_index >= targets.size():
		return
	if p.global_position.distance_to(targets[waypoint_index].pos) <= REACH_METRES:
		targets[waypoint_index].done = true
		waypoint_index += 1
		nav_index = waypoint_index
		if waypoint_index >= targets.size():
			end_mission(true, CODE_SUCCESS, "Final waypoint reached. Mission complete.")


## The mission's own objective notes, then the fallback goal's progress.
func make_objective_lines() -> Array:
	var out := []
	for line in String(m.get("texts", {}).get("objective_notes", "")).split("\n", false):
		out.append({"text": line.strip_edges(), "done": false})
	var done := targets.filter(func(t: Dictionary) -> bool: return t.done).size()
	match goal:
		GOAL_GENERATORS:
			out.append({"text": "Destroy the enemy generators (%d of %d)" % [done, targets.size()], "done": done == targets.size()})
		GOAL_WAYPOINTS:
			out.append({"text": "Reach the waypoints in order (%d of %d)" % [done, targets.size()], "done": done == targets.size()})
		_:
			out.append({"text": "Survive (%d s left)" % maxi(0, int(SURVIVE_SECONDS - elapsed)), "done": false})
	return out


func make_debriefing_text(_code: int, text: String) -> String:
	return text if text != "" else "Mission over."

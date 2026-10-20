class_name RaidTasks
extends Node
## The pre-raid tasks during a raid (playtest X8; RaidTaskBoard; child "Tasks" of the ExtractionDirector).
## Host-authoritative:
##   start     each player's tasks come with his roster kit. Before the squads spawn, every generator / flag task
##             claims a base of the map (its game-mode objects, map.json "mode_objects": a team's generators and
##             flag) for its faction, whose squad is then placed at the loot area nearest that base
##             (make_site_claims, ExtractionSquads). The host binds the tasks: the faction's soldiers / vehicles (a
##             kill count is cut to what the faction fields), the Tribes base generator nearest its area
##             (TribesBase), the faction flag (a "flag" loot container holding the flag item, in the map flag's
##             shape) at the map flag nearest its area. A task the raid cannot hold is void (no gain, no loss).
##   progress  kills by the player (on foot or in a vehicle he sits in) of the faction's soldiers / vehicles count;
##             the generator is done when it is destroyed; the flag when he extracts carrying it
##   payout    extracting pays every done task's reward on top of what he carries (ExtractionDirector.apply_extract)
## Each owner sees his own tasks (objective lines, ObjectivesPanel), sent on every change.

const NODE_NAME := "Tasks"
const FLAG_ITEM := "valuable/faction_flag"
const FLAG_CONTAINER := "flag"
## A generator / flag belongs to a faction when it lies this close to one of its loot areas (metres).
const BASE_REACH := 300.0

var director: ExtractionDirector
## Host: peer -> [task state]; task state = the task + {progress, done, void}.
var by_peer := {}
## Every peer: the local player's task states.
var mine: Array = []
var response: FlagResponse
var _generator_of := {}      # host: task id -> TribesBaseObject
## Host: task key ("<peer>:<task id>") -> the task's Objective (KillCount, Destroy or Carry); a void task has none.
var _objectives := {}
var _world := RaidTaskWorld.new()


func _init(p_director: ExtractionDirector) -> void:
	director = p_director
	response = FlagResponse.new(p_director)
	name = NODE_NAME


## Every faction any roster player has a task against (the squads place them first).
static func make_required_factions(roster: Dictionary) -> Array:
	var out := []
	for peer in roster:
		var kit: Dictionary = roster[peer].get("kit", {}) if roster[peer].get("kit") is Dictionary else {}
		for t in kit.get("tasks", []):
			if t is Dictionary and not out.has(str(t.get("faction", ""))):
				out.append(str(t.get("faction", "")))
	return out


## The bases of map `m` (engine-schema map): per map team the centre of its generators and flag (mode objects).
static func make_base_sites(m: Dictionary) -> Array:
	var by_team := {}
	for d in m.get("mode_objects", []):
		var o := ModeObject.from_map(d)
		if o.kind in [ModeObject.KIND_GENERATOR, ModeObject.KIND_FLAG]:
			if not by_team.has(o.team):
				by_team[o.team] = []
			by_team[o.team].append(o.home)
	var out := []
	for team in by_team:
		var sum := Vector3.ZERO
		for p in by_team[team]:
			sum += p
		out.append(sum / float(by_team[team].size()))
	return out


## {faction id: base site} for the generator / flag tasks of the roster (one base per faction, first come first
## served; a task with no base left is voided later).
static func make_site_claims(roster: Dictionary, m: Dictionary) -> Dictionary:
	var sites := make_base_sites(m)
	var claims := {}
	for peer in roster:
		var kit: Dictionary = roster[peer].get("kit", {}) if roster[peer].get("kit") is Dictionary else {}
		for t in kit.get("tasks", []):
			if not (t is Dictionary) or not str(t.get("kind", "")) in [RaidTaskBoard.KIND_GENERATOR, RaidTaskBoard.KIND_FLAG]:
				continue
			var fid := str(t.get("faction", ""))
			if not claims.has(fid) and claims.size() < sites.size():
				claims[fid] = sites[claims.size()]
	return claims


# ------------------------------------------------------------------ host: binding

## Host, after the squads are placed (`faction_areas`: faction id -> [area points]).
func start_host(faction_areas: Dictionary) -> void:
	var base := _find_base()
	if base:
		base.object_destroyed.connect(_on_base_object_destroyed)
	for peer in director.battle.config.get("roster", {}):
		var kit: Dictionary = director.battle.config.roster[peer].get("kit", {}) if director.battle.config.roster[peer].get("kit") is Dictionary else {}
		var states := []
		for t in kit.get("tasks", []).slice(0, RaidTaskBoard.make_max_picked()):
			if t is Dictionary:
				states.append(_bind(t.duplicate(), faction_areas))
				_add_objective(int(peer), states.back())
		by_peer[int(peer)] = states
		_send_state(int(peer))


func _process(delta: float) -> void:
	if not is_inside_tree() or not multiplayer.is_server() or by_peer.is_empty():
		return
	for peer in by_peer:
		response.apply_tick(by_peer[peer], delta)


func _bind(task: Dictionary, faction_areas: Dictionary) -> Dictionary:
	task["progress"] = 0
	task["done"] = false
	task["void"] = false
	task["count"] = int(task.get("count", 1))
	var areas: Array = faction_areas.get(str(task.faction), [])
	match str(task.kind):
		RaidTaskBoard.KIND_KILL_INFANTRY, RaidTaskBoard.KIND_KILL_VEHICLES:
			task["count"] = mini(int(task.count), _count_units(task))
		RaidTaskBoard.KIND_GENERATOR:
			var gen := _find_generator(areas)
			if gen:
				_generator_of[str(task.id)] = gen
				task["target"] = gen.global_position
			task["count"] = 1 if gen else 0
		RaidTaskBoard.KIND_FLAG:
			var flag_at = _place_flag(areas)
			task["count"] = 1 if flag_at != null else 0
			if flag_at != null:
				task["target"] = flag_at
	task["void"] = int(task.count) <= 0
	task["reward"] = RaidTaskBoard.make_reward(task) if not task.void else 0
	return task


## The faction's units of the task's kind in the raid.
func _count_units(task: Dictionary) -> int:
	var n := 0
	for h in director.battle.vehicles.values():
		if is_instance_valid(h) and _is_task_target(task, h):
			n += 1
	return n


func _is_task_target(task: Dictionary, h: Herc) -> bool:
	if str(director.faction_teams.get(h.team, "")) != str(task.faction) or h.has_meta("transport"):
		return false
	return (h is Infantry) == (str(task.kind) == RaidTaskBoard.KIND_KILL_INFANTRY)


func _find_base() -> Node:
	var base := director.battle.get_node_or_null("TribesBase")
	return base if base != null and base.has_signal("object_destroyed") else null


## The live generator nearest one of `areas` within BASE_REACH (null when none).
func _find_generator(areas: Array) -> Node3D:
	var base := _find_base()
	if base == null:
		return null
	var best: Node3D = null
	var best_d := BASE_REACH
	for o in base.get("objects"):
		if str(o.get("kind")) != "generator" or _generator_of.values().has(o):
			continue
		var d := _distance_to_areas((o as Node3D).global_position, areas)
		if d < best_d:
			best_d = d
			best = o
	return best


## Puts the faction's flag (a loot container holding FLAG_ITEM) at the map flag nearest one of `areas`; false when
## the map has no flag within BASE_REACH. Returns the flag's place (Vector3), null when there is none.
func _place_flag(areas: Array):
	var m: Dictionary = director.built.get("map", {}) if director.built.get("map") is Dictionary else {}
	var best: ModeObject = null
	var best_d := BASE_REACH
	for d in m.get("mode_objects", []):
		var o := ModeObject.from_map(d)
		if o.kind == ModeObject.KIND_FLAG and _distance_to_areas(o.home, areas) < best_d:
			best_d = _distance_to_areas(o.home, areas)
			best = o
	if best == null:
		return null
	director.add_container({"kind": FLAG_CONTAINER, "stacks": [[FLAG_ITEM, 1]], "money": 0, "shape": best.shape}, best.home)
	return best.home


static func _distance_to_areas(p: Vector3, areas: Array) -> float:
	var best := INF
	for a in areas:
		best = minf(best, Vector2(p.x - a.x, p.z - a.z).length())
	return best


# ------------------------------------------------------------------ host: progress

static func make_key(peer: int, task: Dictionary) -> String:
	return "%d:%s" % [peer, str(task.id)]


## The objective a bound task is judged by: kill N (KillCount), destroy the generator (Destroy), carry the flag out
## (Carry; anywhere, because the payout happens at the extraction).
func _add_objective(peer: int, task: Dictionary) -> void:
	if bool(task.void):
		return
	var key := make_key(peer, task)
	var text := RaidTaskBoard.make_text(task)
	match str(task.kind):
		RaidTaskBoard.KIND_GENERATOR:
			_objectives[key] = DestroyObjective.new(key, text, [key] as Array[String])
		RaidTaskBoard.KIND_FLAG:
			_objectives[key] = CarryObjective.new(key, text, FLAG_ITEM, AreaShape.make_circle(Vector3.ZERO, INF))
		_:
			_objectives[key] = KillCountObjective.new(key, text, key, int(task.count))


## Ticks the task's objective against the raid facts; the task is done once its objective is.
func _apply_objective(peer: int, task: Dictionary) -> void:
	var objective: Objective = _objectives.get(make_key(peer, task))
	if objective != null:
		objective.apply_tick(_world, 0.0)
		var was_done := bool(task.done)
		task.done = objective.is_done()
		if task.done and not was_done:
			director.callins.points.apply_task_done(peer, task)

## Host (ExtractionDirector._on_destroyed): `h` was destroyed by `killer`.
func on_unit_destroyed(h: Herc, killer: Node) -> void:
	var peer := _peer_of_killer(killer)
	if peer == 0 or not by_peer.has(peer):
		return
	var changed := false
	for task in by_peer[peer]:
		if not task.done and not task.void and str(task.kind) in [RaidTaskBoard.KIND_KILL_INFANTRY, RaidTaskBoard.KIND_KILL_VEHICLES] \
				and _is_task_target(task, h):
			task.progress = int(task.progress) + 1
			_world.kills[make_key(peer, task)] = int(task.progress)
			_apply_objective(peer, task)
			changed = true
	if changed:
		_send_state(peer)


## The raid player whose soldier is `killer` or who sits in the vehicle `killer` (0: none).
func _peer_of_killer(killer: Node) -> int:
	return director.peer_of_unit(killer)


func _on_base_object_destroyed(obj: Node, killer: Node) -> void:
	if director.site_spawner != null and obj is Node3D:
		director.site_spawner.apply_object_destroyed((obj as Node3D).global_position)
	if str(obj.get("kind")) == "generator":
		director.callins.points.apply_generator_destroyed(killer)
	for peer in by_peer:
		for task in by_peer[peer]:
			if _generator_of.get(str(task.id)) == obj and not task.done:
				task.progress = 1
				_world.destroyed[make_key(int(peer), task)] = true
				_apply_objective(int(peer), task)
				_send_state(int(peer))


## Host: what `peer`'s done tasks pay when he extracts carrying `stacks` (a carried flag completes a flag task; flags
## are handed in, never stashed: without_flags).
func make_payout(peer: int, stacks: Array) -> int:
	var carried := ExtractionInventory.new()
	carried.apply_merge(stacks)
	var flags := carried.count(FLAG_ITEM)
	var total := 0
	for task in by_peer.get(peer, []):
		if str(task.kind) == RaidTaskBoard.KIND_FLAG and not task.void and not task.done and flags > 0:
			flags -= 1
			task.progress = 1
			_world.flags_carried = 1
			_apply_objective(peer, task)
			_world.flags_carried = 0
		if task.done and not task.void:
			total += int(task.reward)
	_send_state(peer)
	return total


func _send_state(peer: int) -> void:
	director.send_to(peer, self, "_task_state", [by_peer.get(peer, [])])


@rpc("authority", "reliable", "call_local")
func _task_state(states: Array) -> void:
	mine = states


# ------------------------------------------------------------------ every peer

## Objective lines of the local player's tasks ({text, done}).
func make_objective_lines() -> Array:
	var out := []
	for task in mine:
		var text := RaidTaskBoard.make_text(task)
		if bool(task.get("void", false)):
			out.append({"text": "%s  (not on this map)" % text, "done": false})
			continue
		var progress := "  %d / %d" % [int(task.progress), int(task.count)] if int(task.count) > 1 else ""
		var marker := _make_marker(task)
		var where := "  [%d m]" % int(_player_distance(marker.pos)) if not marker.is_empty() else ""
		out.append({"text": "%s%s%s  -  %s" % [text, progress, where, ExtractionRules.make_money_text(int(task.reward))],
			"done": bool(task.done)})
	return out


## Markers for the local player's open tasks that have a place: [{pos, label}] (the compass waypoint, the command
## map and the objectives line). A flag already carried points at the nearest extraction zone instead.
func make_markers() -> Array:
	var out := []
	for task in mine:
		var m := _make_marker(task)
		if not m.is_empty():
			out.append(m)
	return out


func _make_marker(task: Dictionary) -> Dictionary:
	if bool(task.get("void", false)) or bool(task.get("done", false)) or not task.has("target"):
		return {}
	var kind := str(task.kind)
	var label := "Generator" if kind == RaidTaskBoard.KIND_GENERATOR else "%s flag" % str(task.get("faction", "")).capitalize()
	var pos: Vector3 = task.target
	if kind == RaidTaskBoard.KIND_FLAG and director.my_inventory.count(FLAG_ITEM) > 0 and not director.zones.is_empty():
		var at = _player_position()
		pos = director.zones[director.zones.size() - 1 if at == null else _nearest_zone(at)]
		label = "Exfil with flag"
	return {"pos": pos, "label": label}


func _nearest_zone(p: Vector3) -> int:
	var best := 0
	for i in director.zones.size():
		if (director.zones[i] as Vector3).distance_to(p) < (director.zones[best] as Vector3).distance_to(p):
			best = i
	return best


func _player_position():
	var s = director.battle.player
	return s.global_position if s != null else null


func _player_distance(p: Vector3) -> float:
	var at = _player_position()
	return 0.0 if at == null else Vector2(p.x - at.x, p.z - at.z).length()


## `stacks` without the faction flags (handed in at extraction: worth nothing in a stash).
static func without_flags(stacks: Array) -> Array:
	return stacks.filter(func(st: Array) -> bool: return str(st[0]) != FLAG_ITEM)

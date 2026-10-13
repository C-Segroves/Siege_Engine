class_name Tribes2MissionRuntime
extends TribesMissionRuntime
## A Tribes 2 training mission (docs/formats/tribes2.md section 8). The scripts are TorqueScript: the
## single-player game (SinglePlayerGame.cs, which execs spDialog.cs: the voice clips and texts of every line)
## loads first, then the mission file builds the object tree (`new SimGroup(MissionGroup) { ... }`) and execs
## the mission's script (TrainingN.cs: package TrainingN, activated at once).
## The engine flow of the original, kept here: the ScriptObject Game (class SinglePlayerGame, superClass
## DefaultGame) gets missionLoadDone, then clientMissionDropReady(player's client): the script connects the
## enemies and teammates (AIConnect -> game.spawnPlayer -> pickPlayerSpawn -> createPlayer -> playerSpawned
## -> equip), spawns the player the same way and starts the mission (startCurrentMission); Training 1 also
## needs PlayGui::onWake. The lines go through doText's queue (processText: messageClient text + alxPlay voice,
## timed by alxGetWaveLen). Message boxes are answered by the engine after MESSAGE_BOX_SECONDS (OK; the "No"
## of missionFailed's Yes/No): missionComplete's box (title VICTORY_TITLE) makes the mission a success, and
## forceFinish -> Disconnect() ends it (end_session). AI tasks a script defines (addTask) are run: assume once, then weight
## and monitor every TASK_SECONDS.

const PLAYER_TEAM := 1
## The training missions' teams (Game.numTeams): the player's and the enemy's.
const TEAM_COUNT := 2
const DROP_GROUP := "MissionGroup/Teams/team%d/DropPoints"
const RESPAWN_GROUP := "MissionGroup/Teams/team%d/DropPoints/Respawns"
## missionComplete's message box (SinglePlayerGame.cs) - its title marks a won mission.
const VICTORY_TITLE := "victory"
const MESSAGE_BOX_SECONDS := 4.0
## $pref::TrainingDifficulty: the easy setting.
const TRAINING_DIFFICULTY := 1
const TASK_SECONDS := 0.5
const OBJECTIVE_TAGS := {"msgspcurrentobjective1": 0, "msgspcurrentobjective2": 1}
const CLEAR_OBJECTIVES_TAG := "msgclearobjhud"
const WAYPOINT_CLASS := "waypoint"
const VEHICLE_CLASSES := ["hovervehicle", "flyingvehicle", "wheeledvehicle"]
const AREA_CLASS := "missionarea"
const DAMAGE_STATES := ["Enabled", "Disabled", "Destroyed"]
## Training 1-3 redefine the client's command-map key (controlDefaults.cs C -> toggleCommanderMap) to refuse it:
## "You are not yet cleared for Command Circuit use." (spDialog.cs miscMsg[noCC]).
const COMMAND_MAP_FUNCTION := "toggleCommanderMap"

var game_id := 0
var transforms: Tribes2Transforms
var _won := false
var _boxes: Array = []          # [sim time, callback code]
var _tasks: Array = []          # [task id, client id, next sim time]
var _steps := {}                # client id -> AI step name


## True when the mission's script owns the command-map key (the command circuit is closed in this training).
func is_command_map_taken() -> bool:
	return vm != null and vm.has_function(COMMAND_MAP_FUNCTION)


## Presses the key the script owns: its own function answers (the noCC message).
func run_command_map_key() -> void:
	vm.call_script(COMMAND_MAP_FUNCTION, [1])


func _make_dialect() -> int:
	return DarkstarLexer.Dialect.TORQUE


func _make_functions() -> DarkstarFunctionTable:
	return Tribes2Functions.new(self)


func _link_datablock(key: String, record: Dictionary) -> void:
	Tribes2Classes.link_datablock(vm, key, record)


## The engine's objects before the mission: Game (SinglePlayerGame : DefaultGame), MissionCleanup,
## ClientGroup, the training preferences, then the single-player game scripts.
func _prepare_globals() -> void:
	transforms = Tribes2Transforms.new(self)
	Tribes2Classes.link_classes(vm)
	game_id = sim.create("ScriptObject", "Game", 0, {"class": "SinglePlayerGame", "superclass": "DefaultGame",
		"numteams": TEAM_COUNT})
	vm.namespace_parents["singleplayergame"] = "defaultgame"
	vm.namespace_parents["defaultgame"] = "scriptobject"
	sim.create("SimGroup", "MissionCleanup", 0)
	actors.client_group = sim.create("SimGroup", "ClientGroup", 0)
	vm.globals["pref::trainingdifficulty"] = TRAINING_DIFFICULTY
	vm.globals["currentmission"] = String(m.get("id", ""))
	vm.globals["firstperson"] = 1
	var own := (String(m.get("id", "")) + ".cs").to_lower()
	for rel in m.get("scripts", []):
		if String(rel).get_file().to_lower() != own:
			exec_script(String(rel).get_file())


func player_spawn(_k: int) -> Transform3D:
	var drops := _drop_points(PLAYER_TEAM, false)
	return transforms.make_object_transform(drops[0]) if not drops.is_empty() else Transform3D.IDENTITY


func make_battle_team(script_team: int) -> int:
	return script_team - 1


func make_script_team(battle_team: int) -> int:
	return battle_team + 1


func _start_game() -> void:
	sim.objects[actors.human_client].fields["team"] = PLAYER_TEAM
	for id in sim.ids_of_class(AREA_CLASS):
		var r := DarkstarStdLib.make_parts(DarkstarScript.to_str(sim.objects[id].fields.get("area", "")), " ")
		if r.size() >= 4:
			contacts.set_area(Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3])))
	vm.call_method(game_id, "missionloaddone", [])
	vm.call_method(game_id, "clientmissiondropready", [actors.human_client])
	if vm.has_function("playgui::onwake"):
		vm.call_script("playgui::onwake", ["PlayGui"])


# ------------------------------------------------------------------ spawning

## The team's drop points (respawn: the Respawns group), the objects that are not groups, in order.
func _drop_points(team: int, respawn: bool) -> Array:
	var group := sim.resolve((RESPAWN_GROUP if respawn else DROP_GROUP) % team)
	return sim.children_of(group).filter(func(c: int) -> bool: return String(sim.objects[c].class).to_lower() != "simgroup")


## DefaultGame::pickTeamSpawn(client, respawn): a drop point's transform string.
func make_team_spawn(client: int, respawn: bool) -> String:
	var team := int(DarkstarScript.num(sim.get_record(client).get("fields", {}).get("team", PLAYER_TEAM)))
	var drops := _drop_points(team, respawn)
	if drops.is_empty():
		drops = _drop_points(team, false)
	return transforms.make_transform_string(drops[randi() % drops.size()]) if not drops.is_empty() else ""


## DefaultGame::createPlayer(client, spawn transform, respawn): the client's soldier there, then
## game.playerSpawned(player).
func create_player(client: int, spawn: String, _respawn: bool) -> int:
	if spawn.strip_edges() == "":
		spawn = make_team_spawn(client, false)
	var pid := actors.spawn_player(client, transforms.make_transform(spawn))
	if pid > 0:
		sim.objects[pid].datablock = _armor_datablock(pid)
		vm.call_method(game_id, "playerspawned", [pid])
	return pid


func _armor_datablock(pid: int) -> String:
	var s := actors.soldier_of(pid)
	var size := String(s.armor.get("size", "light")).to_upper() if s else "LIGHT"
	return String(Tribes2Methods.ARMOR_DATABLOCKS.get(size, Tribes2Methods.ARMOR_DATABLOCKS.LIGHT))


# ------------------------------------------------------------------ objects

## `new` objects: waypoints become the nav point, vehicles real vehicles; a datablock copies its parent's
## fields; a new object's datablock gets onAdd (a mission's scriptlet may define it).
func ss_new_object(spec: Dictionary) -> int:
	var cls := String(spec.class).to_lower()
	if bool(spec.datablock):
		return _new_datablock(spec)
	var id := super.ss_new_object(spec)
	var rec: Dictionary = sim.objects[id]
	if cls == WAYPOINT_CLASS:
		output.set_waypoint(sim.position_of(id), DarkstarScript.to_str(rec.fields.get("name", spec.name)))
		rec["waypoint"] = true
	elif cls in VEHICLE_CLASSES:
		actors.spawn_vehicle(id, String(rec.datablock), transforms.make_object_transform(id), int(DarkstarScript.num(rec.fields.get("team", 0))))
	if String(rec.datablock) != "":
		raise_datablock_callback(id, "onadd", [])
	return id


func _new_datablock(spec: Dictionary) -> int:
	var key := String(spec.name).to_lower()
	var fields := {}
	var parent := String(spec.copy_of).to_lower()
	if datablock_ids.has(parent):
		fields = (sim.objects[datablock_ids[parent]].fields as Dictionary).duplicate()
	fields.merge(spec.fields, true)
	var record := {"type": spec.class, "name": spec.name, "fields": fields}
	datablocks[key] = record
	var id := sim.create(String(spec.class), String(spec.name), 0, fields)
	sim.objects[id]["is_datablock"] = true
	datablock_ids[key] = id
	_link_datablock(key, record)
	return id


func datablock_of(id: int) -> int:
	var rec := sim.get_record(id)
	var db := String(rec.get("datablock", ""))
	if db == "" and String(rec.get("class", "")) == TribesActors.PLAYER_CLASS:
		db = _armor_datablock(id)
	return int(datablock_ids.get(db, 0))


## <datablock>.<event>(object, args...): the first script function along the datablock's namespaces, else the
## engine's (Tribes2Methods); nothing when neither exists.
func raise_datablock_callback(obj: int, event: String, args: Array):
	var data := datablock_of(obj)
	if data == 0:
		return ""
	for ns in ss_namespaces(str(data)):
		var fn := "%s::%s" % [ns, event]
		if vm.has_function(fn):
			return vm.call_script(fn, [data, obj] + args)
		if functions.has_function(fn):
			return functions.call_function(fn, [data, obj] + args)
	return ""


func delete_object(id: int) -> void:
	if bool(sim.get_record(id).get("waypoint", false)):
		output.clear_waypoint()
	actors.remove_node(id)
	super.delete_object(id)


func mounted_image(id: int) -> int:
	var s := actors.soldier_of(id)
	if s == null or s.current_weapon() == null:
		return 0
	for key in datablocks:
		if items.weapon_of(key) == s.current_weapon().weapon_id:
			var image := String(datablocks[key].get("fields", {}).get("image", "")).to_lower()
			return int(datablock_ids.get(image, 0))
	return 0


func damage_state(id: int) -> String:
	return DarkstarScript.to_str(sim.get_record(id).get("fields", {}).get("damagestate", "Enabled"))


func set_damage_state(id: int, state: String) -> void:
	if sim.exists(id) and state in DAMAGE_STATES:
		sim.objects[id].fields["damagestate"] = state


# ------------------------------------------------------------------ clients and AI

func set_client_team(client: int, team: int) -> void:
	if sim.exists(client):
		sim.objects[client].fields["team"] = team
		actors.apply_field(client, "team", team)


func ai_step(client: int, step: String) -> void:
	_steps[client] = step


func ai_step_name(client: int) -> String:
	return String(_steps.get(client, ""))


## addTask(name): a task object of class `name`; script-defined tasks run (assume, then weight / monitor).
func add_task(client: int, task_name: String) -> int:
	var task := sim.create("ScriptObject", "", 0, {"class": task_name})
	var ns := task_name.to_lower()
	if not vm.has_function(ns + "::monitor") and not vm.has_function(ns + "::assume"):
		return task
	if vm.has_function(ns + "::assume"):
		vm.call_script(ns + "::assume", [task, client])
	_tasks.append([task, client, sim_time])
	return task


func _run_tasks() -> void:
	for t in _tasks.duplicate():
		if not sim.exists(int(t[1])) or not sim.exists(int(t[0])):
			_tasks.erase(t)
			continue
		if sim_time < float(t[2]):
			continue
		t[2] = sim_time + TASK_SECONDS
		var ns := DarkstarScript.to_str(sim.objects[int(t[0])].fields.get("class", "")).to_lower()
		for step in ["weight", "monitor"]:
			if vm.has_function(ns + "::" + step):
				vm.call_script(ns + "::" + step, [t[0], t[1]])


func on_player_killed(player: int, killer: int) -> void:
	var victim := actors.client_of(player)
	vm.call_method(game_id, "onclientkilled", [victim, actors.client_of(killer), "", ""])


# ------------------------------------------------------------------ messages, boxes, end

## A tagged message the engine handles itself: the training objective HUD lines. True when handled.
func apply_message_tag(tag: String, args: Array) -> bool:
	if OBJECTIVE_TAGS.has(tag):
		var text := TribesText.make_plain(DarkstarScript.to_str(args[0]) if not args.is_empty() else "")
		set_objective(int(OBJECTIVE_TAGS[tag]), text)
		return true
	if tag == CLEAR_OBJECTIVES_TAG:
		output.clear_objectives()
		return true
	return tag.begins_with("msg")


## MessageBoxOk / MessageBoxYesNo: shown, then answered after MESSAGE_BOX_SECONDS with `callback` (OK, or
## the Yes/No box's "No").
func message_box(title: String, text: String, callback: String) -> void:
	output.show_message("%s: %s" % [TribesText.make_plain(title), text], MESSAGE_BOX_SECONDS)
	if title.to_lower() == VICTORY_TITLE:
		_won = true
	_boxes.append([sim_time + MESSAGE_BOX_SECONDS, callback])


## Disconnect(): the mission ends (won when missionComplete's box came up).
func end_session() -> void:
	debrief(_won, output.objectives[0] if not output.objectives.is_empty() else "")


func _update_game(_delta: float) -> void:
	for b in _boxes.duplicate():
		if sim_time >= float(b[0]):
			_boxes.erase(b)
			vm.eval_string(String(b[1]))
	_run_tasks()


# ------------------------------------------------------------------ contacts

func is_carried(id: int) -> bool:
	return bool(sim.get_record(id).get("hidden", false))


## Shapes whose datablock answers onCollision (a script, or the flip-flop's engine callback).
func is_touchable(id: int) -> bool:
	var rec := sim.get_record(id)
	if String(rec.get("class", "")).to_lower() in ["item", "simgroup"] or String(rec.get("datablock", "")) == "":
		return false
	for ns in ss_namespaces(str(datablock_of(id))):
		var fn := "%s::oncollision" % ns
		if vm.has_function(fn) or (functions.has_function(fn) and ns == "flipflop"):
			return true
	return false


func on_shape_touched(shape: int, player: int) -> void:
	raise_datablock_callback(shape, "oncollision", [player])


func on_item_touched(item: int, player: int) -> void:
	raise_datablock_callback(item, "oncollision", [player])


func on_mission_area(player: int, inside: bool) -> void:
	vm.call_method(game_id, "entermissionarea" if inside else "leavemissionarea", [datablock_of(player), player])


## ItemData::onCollision: the item joins the inventory (a repair patch heals) and is gone.
func pick_up(item: int, player: int) -> void:
	var s := actors.soldier_of(player)
	var db := String(sim.get_record(item).get("datablock", ""))
	if s == null or db == "" or is_carried(item):
		return
	if db == "repairpatch":
		InfantryPack.apply_repair(s, float(s.components[0].max) * Tribes2Methods.REPAIR_PATCH_SHARE)
	elif items.weapon_of(db) != "" or items.gear_of(db) != "" or items.ammo_weapon_of(db) != "":
		var n := int(DarkstarScript.num(sim.get_record(item).fields.get("count", 1)))
		actors.set_item(player, db, actors.item_count(player, db) + maxi(n, 1))
	hide_object(item, true)
	log_debug("picked up %s" % db)


## FlipFlop::playerTouch of defaultGame.cs: the switch goes to the toucher's team (false when it already is).
func claim_flipflop(flipflop: int, player: int):
	var team := int(DarkstarScript.num(sim.get_record(actors.client_of(player)).get("fields", {}).get("team", PLAYER_TEAM)))
	if int(DarkstarScript.num(sim.get_record(flipflop).get("fields", {}).get("team", 0))) == team:
		return 0
	sim.objects[flipflop].fields["team"] = team
	log_debug("flip-flop %d claimed for team %d" % [flipflop, team])
	return 1


## containerRayCast(start, end, ...): "object x y z nx ny nz" of the first thing hit, 0 for none.
func ray_cast(from: Vector3, to: Vector3):
	var q := PhysicsRayQueryParameters3D.create(TribesSimObjects.to_engine(from), TribesSimObjects.to_engine(to))
	var exclude: Array[RID] = []
	var s := actors.soldier_of(actors.human_client)
	if s:
		exclude.append(s.get_rid())
	q.exclude = exclude
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return 0
	var obj := sim.id_of_node(hit.collider)
	return "%d %s %s" % [obj if obj > 0 else 1, DarkstarStdLib.make_vector_string(TribesSimObjects.to_original(hit.position)),
		DarkstarStdLib.make_vector_string(TribesSimObjects.to_original(hit.normal))]


## The living players within `r` of `c` (engine frame), nearest first.
func make_players_within(c: Vector3, r: float) -> Array:
	var out := []
	for client in actors.clients():
		var pid := actors.player_of(client)
		if actors.is_alive(pid) and sim.position_of(pid).distance_to(c) <= r:
			out.append(pid)
	out.sort_custom(func(a: int, b: int) -> bool: return sim.position_of(a).distance_to(c) < sim.position_of(b).distance_to(c))
	return out


# ------------------------------------------------------------------ DarkstarScript host interface

func ss_namespaces(k: String) -> Array:
	var id := int(k) if k.is_valid_int() else 0
	if id == 0 or not sim.exists(id):
		return []
	return Tribes2Classes.make_namespaces(sim.objects[id], datablocks)


## An object's engine method: along its namespaces in the method table; presentation methods are accepted;
## a call on an object that does not exist is a warning (the original prints an error and goes on).
## A name that is no mission object is one of the original's client-side objects (GUI controls, key maps, the
## canvas, the server connection): every method on it is presentation.
func ss_method(k: String, method: String, args: Array):
	var id := int(k) if k.is_valid_int() else 0
	if id == 0 or not sim.exists(id):
		if k == "" or k.is_valid_int():
			add_warning("%s() on a missing object" % method)
		return TribesPresentation.TRIBES2_QUERY_RESULTS.get(method, "")
	for ns in ss_namespaces(k):
		var fn := "%s::%s" % [ns, method]
		if functions.has_function(fn):
			return functions.call_function(fn, [id] + args)
	if method in TribesPresentation.TRIBES2_METHODS:
		return ""
	if TribesPresentation.TRIBES2_QUERY_RESULTS.has(method):
		return TribesPresentation.TRIBES2_QUERY_RESULTS[method]
	return null

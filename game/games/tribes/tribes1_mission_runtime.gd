class_name Tribes1MissionRuntime
extends TribesMissionRuntime
## A Tribes (1998) training mission (docs/formats/tribes.md section 8). The .mis is Darkstar script: its
## `instant` objects build the mission tree and its last lines exec the training script (Training_*.cs, which
## execs Training_AI.cs). The engine flow of the original server, kept here:
##   Mission::init(), then the client drops in: Game::initialMissionDrop(2049) (the training scripts define it:
##   team, Game::playerSpawn, the objective page, the scheduled bottomprint lines);
##   Game::playerSpawn(client, respawn), unless the script defines it: the team's DropPoints/Start marker (Random
##   on a respawn), then Game::playerSpawned(player, client, armor, respawn);
##   callbacks <datablock>::<event> (else the datablock's className, else the object's class): onCollision
##   (switches, flags, items), GroupTrigger::onEnter / onLeave, Player::leaveMissionArea / enterMissionArea,
##   AI::onDroneKilled(name) when an AI dies; the player respawns RESPAWN_SECONDS after dying;
##   EndGame() ends the mission successfully (Training::missionComplete -> remoteTrainingEndMission).
## Items lying in the world are picked up natively (Item::onCollision of item.cs) unless a script handles the
## touch: weapons, ammunition, packs and hand items join the inventory, a repair patch heals.

const START_GROUP := "MissionGroup/Teams/team%d/DropPoints/Start"
const RANDOM_GROUP := "MissionGroup/Teams/team%d/DropPoints/Random"
const AREA_CLASS := "missioncenterpos"
const PLAYER_TEAM := 0
## The training AI fight the player unless a script puts them on his team (GameBase::setTeam).
const AI_TEAM := 1
const RESPAWN_SECONDS := 3.0
## The objective page's lines that start with this are bullets; the first one is the mission's goal.
const GOAL_BULLET := "-"
## A repair patch's share of the soldier's health (RepairPatch repairs 0.125 of a light armour's 0.66 damage).
const REPAIR_PATCH_SHARE := 0.19
const TOUCH_CLASSES := ["staticshape", "sensor", "turret", "moveable"]

var _ai_by_name := {}           # lower AI name -> client id


func _make_dialect() -> int:
	return DarkstarLexer.Dialect.DARKSTAR


func _make_functions() -> DarkstarFunctionTable:
	return Tribes1Functions.new(self)


func player_spawn(_k: int) -> Transform3D:
	return _make_drop_point(PLAYER_TEAM, false)


## The first marker of team `team`'s Start drop points (a random one of Random for a respawn), on the ground.
func _make_drop_point(team: int, respawn: bool) -> Transform3D:
	var group := sim.resolve((RANDOM_GROUP if respawn else START_GROUP) % team)
	if group == 0:
		group = sim.resolve(START_GROUP % team)
	var markers := sim.children_of(group)
	if markers.is_empty():
		return Transform3D.IDENTITY
	var marker: int = markers[randi() % markers.size()] if respawn else markers[0]
	return make_marker_transform(marker)


func make_marker_transform(marker: int) -> Transform3D:
	var rot := DarkstarStdLib.make_vector(DarkstarScript.to_str(sim.get_record(marker).fields.get("rotation", "0 0 0")))
	var p: Vector3 = battle.infantry.make_on_ground(sim.position_of(marker))
	return Transform3D(Basis(Vector3.UP, rot.z), p)


func _start_game() -> void:
	_set_mission_area()
	if vm.has_function("mission::init"):
		vm.call_script("mission::init", [])
	var client := actors.human_client
	if vm.has_function("game::initialmissiondrop"):
		vm.call_script("game::initialmissiondrop", [client])
	else:
		spawn_client(client, false)


func _set_mission_area() -> void:
	for id in sim.ids_of_class(AREA_CLASS):
		var f: Dictionary = sim.objects[id].fields
		contacts.set_area(Rect2(DarkstarScript.num(f.get("x", 0)), DarkstarScript.num(f.get("y", 0)),
			DarkstarScript.num(f.get("w", 0)), DarkstarScript.num(f.get("h", 0))))


# ------------------------------------------------------------------ spawning

## Game::playerSpawn(client, respawn) of game.cs: the drop point, then Game::playerSpawned.
func spawn_client(client: int, respawn: bool) -> void:
	var team := team_of(client)
	var pid := actors.spawn_player(client, _make_drop_point(maxi(team, 0), respawn))
	if pid > 0 and vm.has_function("game::playerspawned"):
		vm.call_script("game::playerspawned", [pid, client, "larmor", 1 if respawn else 0])


## spawnPlayer(armor, position, rotation) for the player's client (a script's own Game::playerSpawn).
func spawn_human_at(pos: Vector3, rot: Vector3):
	var xf := Transform3D(Basis(Vector3.UP, rot.z), battle.infantry.make_on_ground(TribesSimObjects.to_engine(pos)))
	var pid := actors.spawn_player(actors.human_client, xf)
	return pid if pid > 0 else -1


func on_player_killed(player: int, _killer: int) -> void:
	var client := actors.client_of(player)
	if actors.is_ai(client):
		var ai_name := DarkstarScript.to_str(sim.get_record(client).fields.get("ai_name", ""))
		if vm.has_function("ai::ondronekilled"):
			vm.call_script("ai::ondronekilled", [ai_name])
		return
	schedule_game(RESPAWN_SECONDS, func() -> void: vm.call_fn("game::playerspawn", [client, 1]))


# ------------------------------------------------------------------ AI

## createAI(name, path group, armor, display name): an AI client whose bot walks the group's path markers.
func create_ai(ai_name: String, group_path: String, armor: String, display: String) -> void:
	var client := actors.make_client(display if display != "" else ai_name, AI_TEAM, true)
	sim.objects[client].fields["ai_name"] = ai_name
	_ai_by_name[ai_name.to_lower()] = client
	var points: Array[Vector3] = []
	for marker in sim.children_of(sim.resolve(group_path)):
		points.append(battle.infantry.make_on_ground(sim.position_of(int(marker))))
	var xf := Transform3D(Basis.IDENTITY, points[0]) if not points.is_empty() else player_spawn(0)
	var pid := actors.spawn_player(client, xf)
	actors.set_armor(pid, armor)
	var brain := actors.brain_of(client)
	if brain and points.size() > 1:
		brain.apply_patrol(points)


func ai_client(ai_name: String) -> int:
	return int(_ai_by_name.get(ai_name.to_lower(), 0))


## The AI clients `ai_name` means ("*" = all of them).
func ai_clients(ai_name: String) -> Array:
	if ai_name == "*":
		return _ai_by_name.values().filter(func(c: int) -> bool: return sim.exists(c))
	var c := ai_client(ai_name)
	return [c] if c > 0 else []


## AI::DirectiveTarget(name, target client): the bot hunts the target.
func ai_engage(ai_name: String, target: int) -> void:
	actors.order_engage(ai_client(ai_name), target)


# ------------------------------------------------------------------ objects, teams, end

func team_of(id: int) -> int:
	var client := actors.client_of(id)
	if client > 0:
		return int(DarkstarScript.num(sim.get_record(client).fields.get("team", PLAYER_TEAM)))
	return sim.team_of(id)


## GameBase::setTeam(object or client, team).
func set_team(id: int, team: int) -> void:
	var client := actors.client_of(id)
	var target := client if client > 0 else id
	if sim.exists(target):
		sim.objects[target].fields["team"] = team
		actors.apply_field(target, "team", team)


func team_name(team: int) -> String:
	var v = vm.globals.get("server::teamname%d" % team, "")
	return DarkstarScript.to_str(v) if DarkstarScript.to_str(v) != "" else "Team %d" % team


func end_game() -> void:
	debrief(true, make_goal())


## The objective page's goal: its first bullet line ("-Collision with control switch" under "Mission
## Completion:"; every training script's page has the goal as its first "-" line).
func make_goal() -> String:
	for line in output.objectives:
		if line.begins_with(GOAL_BULLET):
			return line.trim_prefix(GOAL_BULLET).strip_edges()
	return ""


## The goal of the objective page is announced when it changes (the page itself is the original's objectives
## screen: kept, not shown).
func set_objective(index: int, text: String) -> void:
	var goal := make_goal()
	output.store_objective(index, text)
	if make_goal() != goal and make_goal() != "":
		output.show_message("Objective: " + make_goal())


## calcRadiusDamage(object, position, radius, damage, ...): soldiers within the radius take the damage.
func radius_damage(pos: Vector3, radius: float, amount: float) -> void:
	var c := TribesSimObjects.to_engine(pos)
	for h in battle.vehicles.values():
		if h is Infantry and (h as Infantry).alive and (h as Infantry).global_position.distance_to(c) <= radius:
			KillText.apply_caused_hit(h, [0.0, amount * TRIBES_DAMAGE_SCALE, null], KillText.CAUSE_SCRIPTED)


## The item name of an infantry weapon id (Player::getMountedItem).
func item_of_weapon(weapon_id: String) -> String:
	for key in datablocks:
		if items.weapon_of(key) == weapon_id:
			return String(datablocks[key].get("name", key))
	return ""


# ------------------------------------------------------------------ callbacks and contacts

## The callback namespaces of an object: its datablock, the datablock's className, its class.
func _namespaces(id: int) -> Array:
	var rec := sim.get_record(id)
	var db := String(rec.get("datablock", ""))
	var out := []
	if db != "":
		out.append(db)
		var cn := String(datablocks.get(db, {}).get("fields", {}).get("classname", "")).to_lower()
		if cn != "":
			out.append(cn)
	out.append(String(rec.get("class", "")).to_lower())
	return out


## The script function `<namespace>::<event>` along the object's namespaces ("" when none).
func _callback(id: int, event: String) -> String:
	for ns in _namespaces(id):
		var fn := "%s::%s" % [ns, event]
		if vm.has_function(fn):
			return fn
	return ""


func is_carried(id: int) -> bool:
	return bool(sim.get_record(id).get("hidden", false))


func is_touchable(id: int) -> bool:
	return String(sim.get_record(id).class).to_lower() in TOUCH_CLASSES and _callback(id, "oncollision") != ""


func on_shape_touched(shape: int, player: int) -> void:
	var fn := _callback(shape, "oncollision")
	if fn != "":
		vm.call_script(fn, [shape, player])


func on_trigger(trigger: int, player: int, entered: bool) -> void:
	var fn := _callback(trigger, "onenter" if entered else "onleave")
	if fn != "":
		vm.call_script(fn, [trigger, player])


func on_mission_area(player: int, inside: bool) -> void:
	var fn := "player::entermissionarea" if inside else "player::leavemissionarea"
	if vm.has_function(fn):
		vm.call_script(fn, [player])


func on_item_touched(item: int, player: int) -> void:
	var fn := _callback(item, "oncollision")
	if fn != "":
		vm.call_script(fn, [item, player])
		return
	_pick_up(item, player)


## Item::onCollision of item.cs: the item joins the inventory (a repair patch heals instead) and is gone.
func _pick_up(item: int, player: int) -> void:
	var db := String(sim.get_record(item).datablock)
	var classname := String(datablocks.get(db, {}).get("fields", {}).get("classname", "")).to_lower()
	var s := actors.soldier_of(player)
	if s == null:
		return
	if classname == "repair":
		InfantryPack.apply_repair(s, float(s.components[0].max) * REPAIR_PATCH_SHARE)
	elif items.ammo_weapon_of(db) != "":
		var rounds := int(DarkstarScript.num(sim.get_record(item).fields.get("count", Tribes1Functions.AMMO_PICKUP_ROUNDS)))
		actors.set_item(player, db, actors.item_count(player, db) + rounds)
	elif items.weapon_of(db) != "" or items.gear_of(db) != "":
		actors.set_item(player, db, actors.item_count(player, db) + 1)
	else:
		return
	hide_object(item, true)
	log_debug("picked up %s" % db)

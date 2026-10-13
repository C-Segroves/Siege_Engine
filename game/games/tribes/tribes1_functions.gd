class_name Tribes1Functions
extends DarkstarFunctionTable
## The engine functions the Tribes (1998) training scripts call, by lower-case name: Tribes' function table of
## the shared Darkstar script runtime (docs/formats/tribes.md section 8). Objects and clients are ids of the
## mission's TribesSimObjects; a client id stands for its player where a function wants a player (as the
## original's GameBase functions accept both).
## Presentation-only calls (HUD icons, GUI modes, sounds, shield flashes) are accepted and ignored
## (TribesPresentation); everything else not listed is an unknown function (a script error).

## Group::objectCount / nameToId of a missing object.
const NONE := -1
## Player::getArmor of the soldier's armour size (the original's armour datablock names).
const ARMOR_NAMES := {"LIGHT": "larmor", "MEDIUM": "marmor", "HEAVY": "harmor"}
## Rounds an ammunition item lying in the world gives when picked up (the item's count field when it has one).
const AMMO_PICKUP_ROUNDS := 10

var rt: Tribes1MissionRuntime
var sim: TribesSimObjects
var actors: TribesActors


func _init(runtime: Tribes1MissionRuntime) -> void:
	rt = runtime
	sim = runtime.sim
	actors = runtime.actors
	include(DarkstarStdLib.new())
	_register_messages()
	_register_objects()
	_register_players()
	_register_clients()
	_register_ai()
	_register_game()
	for n in TribesPresentation.TRIBES_FUNCTIONS:
		_on([n], _no_op)


func _register_messages() -> void:
	_on(["bottomprint", "centerprint", "topprint"], func(_n, a): return _print(a))
	_on(["messageall"], func(_n, a): return _message(_s(a, 1)))
	_on(["client::sendmessage"], func(_n, a): return _message(_s(a, 2)))
	_on(["team::setobjective"], _set_objective)
	_on(["team::clearobjectives"], func(_n, _a): rt.output.clear_objectives(); return "")
	_on(["issuecommand"], _issue_command)
	_on(["issuetargcommand"], _issue_target_command)


func _register_objects() -> void:
	_on(["nametoid"], func(_n, a): var id := sim.resolve(_arg(a, 0)); return id if id > 0 else NONE)
	_on(["group::getobject"], _group_object)
	_on(["group::objectcount"], func(_n, a): var g := sim.resolve(_arg(a, 0)); return sim.children_of(g).size() if g > 0 else 0)
	_on(["getobjecttype"], func(_n, a): return String(sim.get_record(_id(a, 0)).get("class", "")))
	_on(["gamebase::getdataname", "item::getitemdata"], func(_n, a): return _datablock_name(_id(a, 0)))
	_on(["gamebase::getposition", "getboxcenter"], func(_n, a): return _position(_id(a, 0)))
	_on(["gamebase::setposition"], _set_position)
	_on(["gamebase::getrotation"], func(_n, a): return DarkstarScript.to_str(sim.get_record(_id(a, 0)).get("fields", {}).get("rotation", "0 0 0")))
	_on(["gamebase::getteam"], func(_n, a): return rt.team_of(_id(a, 0)))
	_on(["gamebase::setteam"], _set_team)
	_on(["gamebase::getcontrolclient"], func(_n, a): var c := actors.client_of(_id(a, 0)); return c if c > 0 else NONE)
	_on(["gamebase::getdamagelevel"], func(_n, a): return rt.damage_level(_id(a, 0)))
	_on(["gamebase::setdamagelevel"], func(_n, a): rt.set_damage_level(_id(a, 0), _f(a, 1)); return "")
	_on(["gamebase::getenergy"], func(_n, a): var s := actors.soldier_of(_id(a, 0)); return s.capacitor if s else 0)
	_on(["gamebase::setenergy"], _set_energy)
	_on(["newobject"], _new_object)
	_on(["deleteobject", "item::pop"], func(_n, a): rt.delete_object(_id(a, 0)); return "")
	_on(["addtoset"], func(_n, a): sim.add_child(sim.resolve(_arg(a, 0)), _id(a, 1)); return "")
	_on(["item::hide"], func(_n, a): rt.hide_object(_id(a, 0), DarkstarScript.truthy(_arg(a, 1, 1))); return "")
	_on(["containerboxfillset"], _box_fill)
	_on(["exec"], func(_n, a): rt.exec_script(_s(a, 0)); return "")
	_on(["control::getvisible"], func(_n, _a): return 1)


func _register_players() -> void:
	_on(["player::setitemcount"], func(_n, a): actors.set_item(_player(a), _s(a, 1), int(_f(a, 2))); return "")
	_on(["player::getitemcount"], func(_n, a): return actors.item_count(_player(a), _s(a, 1)))
	_on(["player::incitemcount"], func(_n, a): return _add_items(a, int(_f(a, 2, 1))))
	_on(["player::decitemcount"], func(_n, a): return _add_items(a, -int(_f(a, 2, 1))))
	_on(["player::mountitem"], func(_n, a): actors.use_item(_player(a), _s(a, 1)); return "")
	_on(["player::getmounteditem"], _mounted_item)
	_on(["player::getclient"], func(_n, a): var c := actors.client_of(_id(a, 0)); return c if c > 0 else NONE)
	_on(["player::isdead"], func(_n, a): return 0 if actors.is_alive(_player(a)) else 1)
	_on(["player::getarmor"], _armor_name)
	_on(["player::isexposed"], func(_n, _a): return 1)
	_on(["player::iscrouching", "player::getlastcontactcount", "player::getdamageflash"], _zero)
	_on(["spawnplayer"], _spawn_player)


func _register_clients() -> void:
	_on(["client::getfirst"], func(_n, _a): var c := actors.clients(); return c[0] if not c.is_empty() else NONE)
	_on(["client::getnext"], _next_client)
	_on(["getnumclients"], func(_n, _a): return actors.clients().size())
	_on(["getclientbyindex"], func(_n, a): var c := actors.clients(); var i := int(_f(a, 0)); return c[i] if i < c.size() else NONE)
	_on(["client::getteam"], func(_n, a): return rt.team_of(_id(a, 0)))
	_on(["client::getname"], func(_n, a): return DarkstarScript.to_str(sim.get_record(actors.client_of(_id(a, 0))).get("fields", {}).get("name", "")))
	_on(["client::getgender"], func(_n, _a): return "Male")
	_on(["client::getownedobject"], func(_n, a): var p := actors.player_of(_id(a, 0)); return p if p > 0 and actors.is_alive(p) else NONE)
	_on(["client::setownedobject"], func(_n, _a): return "")


func _register_ai() -> void:
	_on(["createai"], func(_n, a): rt.create_ai(_s(a, 0), _s(a, 1), _s(a, 2), _s(a, 3)); return "")
	_on(["ai::getid"], func(_n, a): var c := rt.ai_client(_s(a, 0)); return c if c > 0 else NONE)
	_on(["ai::directivetarget"], func(_n, a): rt.ai_engage(_s(a, 0), _id(a, 1)); return "")
	_on(["ai::callwithid"], _ai_call_with_id)
	_on(["ai::setvar", "ai::directivetargetlaser", "ai::soundhelper", "ai::directivewaypoint"], _no_op)


func _register_game() -> void:
	_on(["getsimtime"], func(_n, _a): return rt.sim_time)
	_on(["schedule"], func(_n, a): rt.schedules.add_code(rt.sim_time + _f(a, 1), _s(a, 0)); return "")
	_on(["remoteeval"], func(_n, a): return rt.vm.call_fn("remote" + _s(a, 1), [_arg(a, 0)] + a.slice(2)))
	_on(["endgame"], func(_n, _a): rt.end_game(); return "")
	_on(["getteamname"], func(_n, a): return rt.team_name(int(_f(a, 0))))
	_on(["radnomitems"], func(_n, a): return _arg(a, 1 + randi() % maxi(int(_f(a, 0)), 1)))
	_on(["game::playerspawn"], func(_n, a): rt.spawn_client(_id(a, 0), DarkstarScript.truthy(_arg(a, 1, 0))); return "")
	# game.cs's default Game::playerSpawned hands out the spawn kit: the soldier already spawns with it
	_on(["game::playerspawned"], _no_op)
	_on(["calcradiusdamage"], func(_n, a): rt.radius_damage(DarkstarStdLib.make_vector(_s(a, 1)), _f(a, 2), _f(a, 3)); return "")


# ------------------------------------------------------------------ helpers

static func _s(a: Array, i: int) -> String:
	return DarkstarStdLib._s(a, i)


static func _f(a: Array, i: int, default := 0.0) -> float:
	return DarkstarStdLib._f(a, i, default)


func _id(a: Array, i: int) -> int:
	return sim.resolve(_arg(a, i))


## The player a function's first argument means (a client stands for its player).
func _player(a: Array) -> int:
	return actors.player_of(_id(a, 0))


func _position(id: int) -> String:
	var obj := actors.player_of(id) if actors.is_client(id) else id
	return DarkstarStdLib.make_vector_string(TribesSimObjects.to_original(sim.position_of(obj))) if obj > 0 else "0 0 0"


func _datablock_name(id: int) -> String:
	var db := String(sim.get_record(id).get("datablock", ""))
	return String(rt.datablocks.get(db, {}).get("name", db))


# ------------------------------------------------------------------ messages

## bottomprint(client, text, seconds): the training line, for the player's client.
func _print(a: Array):
	if actors.client_of(_id(a, 0)) == actors.human_client:
		rt.output.queue_text(_s(a, 1))
	return ""


func _message(text: String):
	rt.output.queue_text(text)
	return ""


## Team::setObjective(team, line, text): line 0.. of the player team's objective page (line 0: the picture).
func _set_objective(_n: String, a: Array):
	if int(_f(a, 0)) == rt.make_script_team(rt.battle.player.team if rt.battle.player else 0):
		rt.set_objective(int(_f(a, 1)), _s(a, 2))
	return ""


## issueCommand(commander, client, icon, text, x, y): a waypoint at x y (on the ground there).
func _issue_command(_n: String, a: Array):
	var p := TribesSimObjects.to_engine(Vector3(_f(a, 4), _f(a, 5), 0.0))
	p.y = MapBuilder.ground_height(rt.battle, p)
	rt.output.set_waypoint(p, TribesText.make_plain(_s(a, 3)))
	return ""


## issueTargCommand(commander, client, icon, text, target index): a waypoint on client 2048 + index.
func _issue_target_command(_n: String, a: Array):
	var target := TribesSimObjects.FIRST_CLIENT_ID - 1 + int(_f(a, 4))
	var p := actors.player_of(target)
	if p > 0:
		rt.output.set_waypoint(sim.position_of(p), TribesText.make_plain(_s(a, 3)))
	return ""


# ------------------------------------------------------------------ objects

func _group_object(_n: String, a: Array):
	var kids := sim.children_of(_id(a, 0))
	var i := int(_f(a, 1))
	return kids[i] if i >= 0 and i < kids.size() else NONE


func _set_position(_n: String, a: Array):
	rt.move_object(_id(a, 0), TribesSimObjects.to_engine(DarkstarStdLib.make_vector(_s(a, 1))))
	return ""


func _set_team(_n: String, a: Array):
	rt.set_team(_id(a, 0), int(_f(a, 1)))
	return ""


func _set_energy(_n: String, a: Array):
	var s := actors.soldier_of(_id(a, 0))
	if s:
		s.capacitor = clampf(_f(a, 1), 0.0, s.capacitor_max)
	return ""


## newObject(name, class, args...): a SimSet / SimGroup, or an Item (class, datablock, count, ...).
func _new_object(_n: String, a: Array):
	var cls := _s(a, 1)
	var fields := {"datablock": _s(a, 2)} if cls.to_lower() == "item" else {}
	return sim.create(cls, _s(a, 0), 0, fields)


## containerBoxFillSet(set, mask, position, x, y, z, ...): the number of soldiers within the box.
func _box_fill(_n: String, a: Array):
	var c := DarkstarStdLib.make_vector(_s(a, 2))
	var half := Vector3(_f(a, 3), _f(a, 4), _f(a, 5))
	var n := 0
	for h in rt.battle.vehicles.values():
		if is_instance_valid(h) and (h as Herc).alive:
			var d := (TribesSimObjects.to_original((h as Herc).global_position) - c).abs()
			if d.x <= half.x and d.y <= half.y and d.z <= half.z:
				n += 1
	return n


# ------------------------------------------------------------------ players and clients

func _add_items(a: Array, delta: int):
	var pid := _player(a)
	actors.set_item(pid, _s(a, 1), actors.item_count(pid, _s(a, 1)) + delta)
	return ""


## Player::getMountedItem(player, slot): the item of the weapon in hand (slot 0), -1 for none.
func _mounted_item(_n: String, a: Array):
	var s := actors.soldier_of(_player(a))
	if s == null or int(_f(a, 1)) != 0 or s.current_weapon() == null:
		return NONE
	return rt.item_of_weapon(s.current_weapon().weapon_id)


func _armor_name(_n: String, a: Array):
	var s := actors.soldier_of(_player(a))
	return String(ARMOR_NAMES.get(String(s.armor.get("size", "light")).to_upper(), "larmor")) if s else "larmor"


## spawnPlayer(armor, position, rotation): the player's soldier there (Game::playerSpawn scripts call it for him).
func _spawn_player(_n: String, a: Array):
	return rt.spawn_human_at(DarkstarStdLib.make_vector(_s(a, 1)), DarkstarStdLib.make_vector(_s(a, 2)))


func _next_client(_n: String, a: Array):
	var c := actors.clients()
	var i := c.find(_id(a, 0))
	return c[i + 1] if i >= 0 and i + 1 < c.size() else NONE


## AI::callWithId(name or "*", function, args...): function(ai client, args...) for each AI meant.
func _ai_call_with_id(_n: String, a: Array):
	for c in rt.ai_clients(_s(a, 0)):
		rt.vm.call_fn(_s(a, 1), [c] + a.slice(2))
	return ""

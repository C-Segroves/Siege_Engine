class_name Tribes2Methods
extends DarkstarFunctionTable
## The engine methods of Tribes 2's objects, registered as "<namespace>::<method>" with the object first
## (Torque passes %this first): what `object.method(args)` finds along the object's namespaces
## (Tribes2Classes) when no script function answers, and what parent:: and static calls such as
## DefaultGame::missionLoadDone(%game) reach. Includes the DefaultGame and datablock callbacks the single-player
## game relies on (defaultGame.cs, item.cs and staticShape.cs are the engine's part in the remake).

## A repair patch's share of the soldier's health (RepairPatch repairAmount 0.4 of a light armour's 0.66 ... ).
const REPAIR_PATCH_SHARE := 0.25
const ARMOR_DATABLOCKS := {"LIGHT": "lightmalehumanarmor", "MEDIUM": "mediummalehumanarmor",
	"HEAVY": "heavymalehumanarmor"}
const STATE_DEAD := "Dead"
const STATE_MOVE := "Move"

var rt: Tribes2MissionRuntime
var sim: TribesSimObjects
var actors: TribesActors


func _init(runtime: Tribes2MissionRuntime) -> void:
	rt = runtime
	sim = runtime.sim
	actors = runtime.actors
	_register_simobject()
	_register_scene()
	_register_shapebase()
	_register_clients()
	_register_game()
	_register_datablocks()


func _register_simobject() -> void:
	_on(["simobject::getname"], func(_n, a): return String(sim.get_record(_id(a)).get("name", "")))
	_on(["simobject::getid"], func(_n, a): return _id(a))
	_on(["simobject::getclassname"], func(_n, a): return String(sim.get_record(_id(a)).get("class", "")))
	_on(["simobject::getgroup"], func(_n, a): return int(sim.get_record(_id(a)).get("parent", 0)))
	_on(["simobject::delete"], func(_n, a): rt.delete_object(_id(a)); return "")
	_on(["simobject::schedule"], func(_n, a): return rt.schedules.add_method(rt.sim_time + _f(a, 1) / 1000.0, _id(a), _s(a, 2), a.slice(3)))
	_on(["simobject::getdatablock", "gamebase::getdatablock"], func(_n, a): return rt.datablock_of(_id(a)))
	_on(["simobject::setname"], func(_n, a): sim.set_name(_id(a), _s(a, 1)); return "")
	_on(["simset::getcount"], func(_n, a): return sim.children_of(_id(a)).size())
	_on(["simset::getobject"], func(_n, a): var c := sim.children_of(_id(a)); var i := int(_f(a, 1)); return c[i] if i >= 0 and i < c.size() else -1)
	_on(["simset::add"], _set_add)
	_on(["simset::remove"], func(_n, a): sim.remove_child(_id(a), sim.resolve(_arg(a, 1))); return "")
	_on(["simset::clear"], _set_clear)


func _register_scene() -> void:
	_on(["sceneobject::gettransform"], func(_n, a): return rt.transforms.make_transform_string(_id(a)))
	_on(["sceneobject::settransform"], func(_n, a): rt.transforms.apply_transform(_id(a), _s(a, 1)); return "")
	_on(["sceneobject::getposition"], func(_n, a): return rt.transforms.make_position_string(_id(a)))
	_on(["sceneobject::getworldboxcenter"], func(_n, a): return rt.transforms.make_box_center_string(_id(a)))
	_on(["sceneobject::getforwardvector"], func(_n, a): return rt.transforms.make_forward_string(_id(a)))
	_on(["gamebase::gettarget"], func(_n, a): return _id(a))
	_on(["gamebase::setteam"], func(_n, a): sim.objects[_id(a)].fields["team"] = int(_f(a, 1)); return "")


func _register_shapebase() -> void:
	_on(["shapebase::setinventory"], func(_n, a): actors.set_item(_id(a), _s(a, 1), int(_f(a, 2))); return "")
	_on(["shapebase::getinventory"], func(_n, a): return actors.item_count(_id(a), _s(a, 1)))
	_on(["shapebase::clearinventory"], func(_n, a): actors.clear_items(_id(a)); return "")
	_on(["shapebase::use"], func(_n, a): actors.use_item(_id(a), _s(a, 1)); return "")
	_on(["shapebase::getmountedimage"], func(_n, a): return rt.mounted_image(_id(a)))
	_on(["shapebase::getdamagelevel"], func(_n, a): return rt.damage_level(_id(a)))
	_on(["shapebase::setdamagelevel"], func(_n, a): rt.set_damage_level(_id(a), _f(a, 1)); return "")
	_on(["shapebase::applydamage"], func(_n, a): rt.apply_damage(_id(a), _f(a, 1) * TribesMissionRuntime.TRIBES_DAMAGE_SCALE); return "")
	_on(["shapebase::getstate"], func(_n, a): return STATE_MOVE if actors.is_alive(_id(a)) or actors.soldier_of(_id(a)) == null else STATE_DEAD)
	_on(["shapebase::hide"], func(_n, a): rt.hide_object(_id(a), DarkstarScript.truthy(_arg(a, 1, 1))); return "")
	_on(["shapebase::isdisabled"], func(_n, a): return 1 if rt.damage_state(_id(a)) != "Enabled" else 0)
	_on(["shapebase::isenabled", "shapebase::ispowered"], func(_n, a): return 1 if rt.damage_state(_id(a)) == "Enabled" else 0)
	_on(["shapebase::setdamagestate"], func(_n, a): rt.set_damage_state(_id(a), _s(a, 1)); return "")
	_on(["shapebase::getvelocity"], func(_n, a): return rt.transforms.make_velocity_string(_id(a)))
	_on(["shapebase::setvelocity"], func(_n, a): rt.transforms.apply_velocity(_id(a), DarkstarStdLib.make_vector(_s(a, 1))); return "")
	_on(["shapebase::mountobject"], func(_n, a): actors.mount(_id(a), sim.resolve(_arg(a, 1))); return "")
	_on(["shapebase::unmount"], func(_n, a): actors.unmount(_id(a)); return "")
	_on(["player::setarmor"], func(_n, a): actors.set_armor(_id(a), _s(a, 1)); return "")


func _register_clients() -> void:
	_on(["gameconnection::setteam"], func(_n, a): rt.set_client_team(_id(a), int(_f(a, 1))); return "")
	_on(["gameconnection::isaicontrolled"], func(_n, a): return 1 if actors.is_ai(_id(a)) else 0)
	_on(["gameconnection::drop", "aiconnection::drop"], func(_n, a): actors.drop_client(_id(a)); return "")
	_on(["aiconnection::stepengage"], func(_n, a): rt.ai_step(_id(a), "AIStepEngage"); actors.order_engage(_id(a), sim.resolve(_arg(a, 1))); return "")
	_on(["aiconnection::stepmove"], _step_move)
	_on(["aiconnection::getstepname"], func(_n, a): return rt.ai_step_name(_id(a)))
	_on(["aiconnection::addtask"], func(_n, a): return rt.add_task(_id(a), _s(a, 1)))
	_on(["aiconnection::setpilotdestination"], _pilot_destination)


func _register_game() -> void:
	_on(["defaultgame::createplayer"], func(_n, a): return rt.create_player(sim.resolve(_arg(a, 1)), _s(a, 2), DarkstarScript.truthy(_arg(a, 3, 0))))
	_on(["defaultgame::playerspawned"], func(_n, a): rt.vm.call_method(_id(a), "equip", [_arg(a, 1)]); return "")
	_on(["defaultgame::pickteamspawn"], func(_n, a): return rt.make_team_spawn(sim.resolve(_arg(a, 1)), DarkstarScript.truthy(_arg(a, 2, 0))))
	_on(["defaultgame::onclientkilled"], _client_killed)
	_on(["defaultgame::cleanword"], func(_n, a): return _s(a, 1))
	# defaultGame.cs: a loaded mission starts the game's AI (SinglePlayerGame::AIInit makes the objective queues)
	_on(["defaultgame::missionloaddone"], func(_n, a): rt.vm.call_method(_id(a), "aiinit", []); return "")
	for m in ["clientmissiondropready", "cleardeployablemaxes", "gameover", "onaikilled",
			"onclientdamaged", "onaidamaged", "leavemissionarea", "entermissionarea", "friendlyfiremessage",
			"sensoronrepaired", "equip", "onairespawn", "aiinit", "aihasjoined", "notifymatchstart", "assignclientteam"]:
		_on(["defaultgame::" + m], _no_op)


func _register_datablocks() -> void:
	_on(["itemdata::oncollision"], func(_n, a): rt.pick_up(sim.resolve(_arg(a, 1)), sim.resolve(_arg(a, 2))); return "")
	_on(["flipflop::oncollision"], func(_n, a): return rt.vm.call_method(_id(a), "playertouch", [_arg(a, 1), _arg(a, 2)]))
	_on(["flipflop::playertouch"], func(_n, a): return rt.claim_flipflop(sim.resolve(_arg(a, 1)), sim.resolve(_arg(a, 2))))


# ------------------------------------------------------------------ helpers

static func _s(a: Array, i: int) -> String:
	return DarkstarStdLib._s(a, i)


static func _f(a: Array, i: int, default := 0.0) -> float:
	return DarkstarStdLib._f(a, i, default)


## The object a method runs on (its first argument).
func _id(a: Array) -> int:
	return sim.resolve(_arg(a, 0))


## SimSet.add(objects...): they join the set (a SimGroup takes them out of their old group).
func _set_add(_n: String, a: Array):
	for o in a.slice(1):
		sim.add_child(_id(a), sim.resolve(o))
	return ""


func _set_clear(_n: String, a: Array):
	for c in sim.children_of(_id(a)):
		sim.remove_child(_id(a), int(c))
	return ""


## stepMove(position[, tolerance, mode]): the bot walks there.
func _step_move(_n: String, a: Array):
	rt.ai_step(_id(a), "AIStepMove")
	actors.order_move(_id(a), TribesSimObjects.to_engine(DarkstarStdLib.make_vector(_s(a, 1))))
	return ""


## setPilotDestination(position): the vehicle the client's soldier is mounted in flies there.
func _pilot_destination(_n: String, a: Array):
	var vehicle := actors.mounted_vehicle(_id(a))
	if vehicle > 0:
		actors.fly_to(vehicle, TribesSimObjects.to_engine(DarkstarStdLib.make_vector(_s(a, 1))))
	return ""


## DefaultGame::onClientKilled(game, victim, killer, ...): an AI victim goes on to game.onAIKilled.
func _client_killed(_n: String, a: Array):
	var victim := sim.resolve(_arg(a, 1))
	if actors.is_ai(victim):
		rt.vm.call_method(_id(a), "onaikilled", a.slice(1))
	return ""

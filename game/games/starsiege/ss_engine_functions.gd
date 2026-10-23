class_name SSEngineFunctions
extends DarkstarFunctionTable
## The Darkstar engine functions Starsiege mission scripts call (schedule, getObjectId, getDistance,
## order, say, setNavMarker, damageObject, forceToDebrief, playerManager::*, ...), dispatched by
## lower-case name: Starsiege's function table of the shared Darkstar script runtime.
## `call_function` returns null for names that are not engine functions.

## Presentation-only engine calls (camera, sound, music, HUD timers, squad command menu, radar,
## inventory UI): accepted and ignored. Matched as name prefixes after the explicit table.
const IGNORED_PREFIXES := ["focus", "fade", "set", "play", "stop", "cdaudio", "preload", "force", "kill",
	"addgeneral", "removegeneral", "addsquad", "removesquad", "clear", "lock", "camera", "cinematic",
	"movecinematic", "hud", "scanx", "encyclopedia", "squawk", "artillery", "localnav", "reload", "updateorder",
	"selectturret", "getturret", "directturret", "vehiclemay", "orbit", "addtoset", "awardbonus", "removeorder",
	"drop", "getcomponent", "getweapon", "componentis", "addcomponent", "addweapon"]
## getDistance of an unknown object.
const FAR_AWAY := 1e9
const DEFAULT_SAFE_RADIUS := 1000.0
## say / say3D: the who / text / wav arguments (both take channel, who, text, wav first).
const SAY_WHO_ARG := 1
const SAY_TEXT_ARG := 2
const SAY_WAV_ARG := 3

var rt: StarsiegeMissionRuntime
var tree: SSObjectTree
var cameras: SSCameraFunctions


func _init(runtime: StarsiegeMissionRuntime) -> void:
	rt = runtime
	tree = runtime.tree
	cameras = SSCameraFunctions.new(runtime)
	_register_handlers()
	_handlers.merge(cameras.make_handlers())


func _register_handlers() -> void:
	_on(["schedule"], _schedule)
	_on(["getobjectid", "mygetobjectid_native"], _get_object_id)
	_on(["getobjectname"], _get_object_name)
	_on(["getgroup"], _get_group)
	_on(["getnextobject"], _get_next_object)
	_on(["getleader"], _get_leader)
	_on(["getdistance", "getgroupdistance"], _get_distance)
	_on(["getposition"], _get_position)
	_on(["setposition", "positionset"], _set_position)
	_on(["getterrainheight"], _get_terrain_height)
	_on(["order"], _order)
	_on(["newformation"], _new_formation)
	_on(["say", "say3d", "playsound"], _say)
	_on(["randomint"], _random_int)
	_on(["randomfloat"], _random_float)
	_on(["setnavmarker", "enablenavmarker_native"], _set_nav_marker)
	_on(["selectnavmarker_native"], _no_op)
	_on(["forcetodebrief"], _force_to_debrief)
	_on(["getteam"], _get_team)
	_on(["setteam"], _set_team)
	_on(["setvehicleradarvisible"], _set_vehicle_radar_visible)
	_on(["issafe"], _is_safe)
	_on(["isgroupdestroyed"], _is_group_destroyed)
	_on(["pick"], _pick)
	_on(["damageobject"], _damage_object)
	_on(["damagearea"], _damage_area)
	_on(["healobject"], _heal_object)
	_on(["playermanager::playernumtovehicleid"], _player_num_to_vehicle)
	_on(["playermanager::vehicleidtoplayernum"], _vehicle_to_player_num)
	_on(["playermanager::getplayercount"], _player_count)
	_on(["ismultiplayer"], _zero)
	_on(["exec"], _exec)
	_on(["datastore"], _data_store)
	_on(["dataretrieve"], _data_retrieve)
	_on(["echo", "dbecho"], _echo)
	_on(["strcat"], _strcat)
	_on(["strlen"], _strlen)
	_on(["getvehiclehudname"], _get_vehicle_hud_name)
	_on(["getplanet"], _get_planet)
	_on(["gettime", "getsimtime"], _get_time)


## Runs engine function `name` (lower case) with evaluated arguments; null = not an engine function.
func call_function(name: String, a: Array):
	if _handlers.has(name):
		return _handlers[name].call(name, a)
	if name.begins_with("inventory"):
		rt.inventory_changes.append([name] + a)
		return ""
	for prefix in IGNORED_PREFIXES:
		if name.begins_with(prefix):
			return ""
	return null


## Original-frame point (x, y, z) from the arguments starting at `first`.
static func _orig_point(a: Array, first: int) -> Vector3:
	return StarsiegeMissionRuntime.orig_to_eng(SSScript.num(_arg(a, first)), SSScript.num(_arg(a, first + 1)),
		SSScript.num(_arg(a, first + 2)))


# ------------------------------------------------------------------ simple queries

func _get_object_id(_n: String, a: Array):
	return tree.resolve(_arg(a, 0))


func _get_object_name(_n: String, a: Array):
	return String(tree.get_record(tree.resolve(_arg(a, 0))).get("name", ""))


func _get_group(_n: String, a: Array):
	return int(tree.get_record(tree.resolve(_arg(a, 0))).get("parent", 0))


func _random_float(_n: String, a: Array):
	return randf_range(SSScript.num(_arg(a, 0)), SSScript.num(_arg(a, 1, 1)))


func _get_team(_n: String, a: Array):
	return _team_name(tree.resolve(_arg(a, 0)))


func _is_group_destroyed(_n: String, a: Array):
	return 1 if tree.is_group_destroyed(tree.resolve(_arg(a, 0))) else 0


func _player_num_to_vehicle(_n: String, a: Array):
	return int(tree.player_objs.get(int(SSScript.num(_arg(a, 0))), 0))


func _player_count(_n: String, _a: Array):
	return tree.player_objs.size()


func _data_retrieve(_n: String, a: Array):
	return rt.vm.get_field(_arg(a, 0), SSScript.to_str(_arg(a, 1)).to_lower())


func _strlen(_n: String, a: Array):
	return SSScript.to_str(_arg(a, 0)).length()


func _get_planet(_n: String, _a: Array):
	return String(rt.m.get("planet_set", ""))


func _get_time(_n: String, _a: Array):
	return rt.sim_time


# ------------------------------------------------------------------ objects

func _schedule(_n: String, a: Array):
	rt.schedule(SSScript.to_str(_arg(a, 0)), SSScript.num(_arg(a, 1, 0)))
	return ""


func _get_terrain_height(_n: String, a: Array):
	var p := StarsiegeMissionRuntime.orig_to_eng(SSScript.num(_arg(a, 0)), SSScript.num(_arg(a, 1)), 0.0)
	return rt.ground_height_at(p)


func _order(_n: String, a: Array):
	rt.units.order(_arg(a, 0), SSScript.to_str(_arg(a, 1)), a.slice(2))
	return ""


func _new_formation(_n: String, a: Array):
	rt.units.define_formation(SSScript.to_str(_arg(a, 0)), a.slice(1))
	return ""


func _get_next_object(_n: String, a: Array):
	var kids: Array = tree.get_record(tree.resolve(_arg(a, 0))).get("children", [])
	var i := kids.find(tree.resolve(_arg(a, 1, 0)))
	return kids[i + 1] if i + 1 < kids.size() else 0


func _get_leader(_n: String, a: Array):
	var alive := tree.alive_units_in(tree.resolve(_arg(a, 0)))
	for u in alive:
		if tree.objects[u].get("leader", false):
			return u
	return alive[0] if not alive.is_empty() else 0


func _get_distance(_n: String, a: Array):
	var x := tree.resolve(_arg(a, 0))
	var y := tree.resolve(_arg(a, 1))
	if x == 0 or y == 0:
		return FAR_AWAY
	return tree.position_of(x).distance_to(tree.position_of(y))


func _get_position(_n: String, a: Array):
	var p := StarsiegeMissionRuntime.eng_to_orig(tree.position_of(tree.resolve(_arg(a, 0))))
	match SSScript.to_str(_arg(a, 1, "x")).to_lower():
		"y": return p.y
		"z": return p.z
		"rot", "r": return 0
	return p.x


## setPosition(obj, x, y, z): groups move as a block, nobody ends up below the terrain.
func _set_position(_n: String, a: Array):
	var sid := tree.resolve(_arg(a, 0))
	var pt := _orig_point(a, 1)
	var movers := [sid] if tree.node_of(sid) != null else tree.alive_units_in(sid)
	rt.log_debug("setPosition %s -> %s (%s)" % [tree.get_record(sid).get("path", sid), pt, a])
	var ref := Vector3.ZERO
	for i in movers.size():
		var mn := tree.node_of(movers[i])
		if mn == null:
			continue
		if i == 0:
			ref = mn.global_position
		var q := pt + (mn.global_position - ref)
		q.y = maxf(q.y, rt.ground_height_at(q) + 0.5)
		mn.global_position = q
	return ""


func _pick(_n: String, a: Array):
	var alive := tree.alive_units_in(tree.resolve(_arg(a, 0)))
	return alive[randi() % alive.size()] if not alive.is_empty() else 0


func _vehicle_to_player_num(_n: String, a: Array):
	var vid := tree.resolve(_arg(a, 0))
	for p in tree.player_objs:
		if tree.player_objs[p] == vid:
			return p
	return 0


func _get_vehicle_hud_name(_n: String, a: Array):
	var n := tree.node_of(tree.resolve(_arg(a, 0)))
	return String(n.display_name) if n != null and n.get("display_name") != null else ""


# ------------------------------------------------------------------ messages, nav, mission end

## say(channel, who, text, wav) / say3D(channel, who, text, wav, profile, x, y, z) speak their text on the
## campaign radio with the wav (SSRadio; missionStdLib.cs; say3D with an empty text is an ambient sound, and a
## wav in place of the text is a voice-only line: both stay silent here); playSound is silent here.
func _say(name: String, a: Array):
	if name == "playsound":
		return ""
	var text := SSScript.to_str(_arg(a, SAY_TEXT_ARG))
	if text.begins_with("IDSTR") or text.begins_with("IDPLT"):
		text = String(rt.vm.tag(text))
	if text != "" and not text.to_lower().ends_with(".wav"):
		var line := SSRadio.make_line(text, _speaker_name(_arg(a, SAY_WHO_ARG)), SSScript.to_str(_arg(a, SAY_WAV_ARG)))
		var wav := str(line.voice)
		rt.kit.announcer.apply_say(MissionMessage.make_message(str(line.text), 0.0, MissionMessage.CHANNEL_RADIO,
			str(line.speaker), MissionVoice.make_voice(wav) if wav != "" else null))
		rt.log_debug("say: %s" % text)
	return ""


## The name of the AI vehicle a say() `who` names ("" for the player, numbers and unknown objects).
func _speaker_name(who) -> String:
	var n := tree.node_of(tree.resolve(who))
	if n == null or not n.has_meta("ai") or n.get("display_name") == null:
		return ""
	return String(n.display_name)


func _random_int(_n: String, a: Array):
	var lo := int(SSScript.num(_arg(a, 0)))
	var hi := int(SSScript.num(_arg(a, 1)))
	return lo + randi() % maxi(1, hi - lo + 1)


## setNavMarker(marker, on[, select]): a third argument also makes it the selected nav point.
func _set_nav_marker(_n: String, a: Array):
	var nid := tree.resolve(_arg(a, 0))
	if tree.kind_of(nid) != "nav_marker":
		return ""
	var rec: Dictionary = tree.objects[nid]
	rec.nav_on = SSScript.truthy(_arg(a, 1, 1))
	if rec.nav_on and a.size() >= 3:
		for k in tree.ids_of_kind("nav_marker"):
			tree.objects[k].nav_selected = false
		rec.nav_selected = true
	rt.refresh_nav()
	return ""


## forceToDebrief([*IDSTR_MISSION_SUCCESSFUL | *IDSTR_MISSION_FAILED]); without one the primary
## objectives decide.
func _force_to_debrief(_n: String, a: Array):
	var how := SSScript.to_str(_arg(a, 0)).to_lower()
	if how != "" and how == String(rt.vm.strings.get("IDSTR_MISSION_SUCCESSFUL", "")).to_lower():
		rt.debrief(true)
	elif how != "" and how == String(rt.vm.strings.get("IDSTR_MISSION_FAILED", "")).to_lower():
		rt.debrief(false)
	else:
		rt.debrief(rt.objectives_done())
	return ""


# ------------------------------------------------------------------ teams

func _team_name(id: int) -> String:
	var t := String(tree.get_record(tree.player_objs.get(id, id)).get("team", "neutral"))
	var n := tree.node_of(id)
	if n != null and n.get("team") != null:
		for k in StarsiegeMissionRuntime.TEAM_OF:
			if StarsiegeMissionRuntime.TEAM_OF[k] == int(n.team):
				t = k
	var tag := String(StarsiegeMissionRuntime.TEAM_TAGS.get(t, ""))
	return String(rt.vm.strings.get(tag, t)) if tag != "" else "neutral"


static func _team_from_value(v) -> String:
	var s := SSScript.to_str(v).to_lower()
	for k in StarsiegeMissionRuntime.TEAM_OF:
		if s.find(k) >= 0:
			return k
	return "neutral"


func _set_team(_n: String, a: Array):
	var tid := tree.resolve(_arg(a, 0))
	var n := tree.node_of(tid)
	var t := _team_from_value(_arg(a, 1))
	if tree.objects.has(tid):
		tree.objects[tid].team = t
	if n != null and n.get("team") != null:
		n.team = StarsiegeMissionRuntime.TEAM_OF.get(t, SSTeams.NEUTRAL)
	if tree.is_vehicle(tid):
		rt.units.apply_team_stance(tid)
	return ""


## setVehicleRadarVisible(obj, bool): the mission hides one unit from radar (a story's stealthy or unseen
## vehicle; HA1, HA3, CA0, ...): RadarContacts leaves it off radars and the command map.
func _set_vehicle_radar_visible(_n: String, a: Array):
	var n := tree.node_of(tree.resolve(_arg(a, 0)))
	if n != null:
		ContactTable.apply_hidden(n, not SSScript.truthy(_arg(a, 1, "true")))
	return ""


## isSafe(team, obj, radius): no living non-neutral vehicle of another team within the radius.
func _is_safe(_n: String, a: Array):
	var team := _team_from_value(_arg(a, 0))
	var c := tree.position_of(tree.resolve(_arg(a, 1)))
	var r := SSScript.num(_arg(a, 2, DEFAULT_SAFE_RADIUS))
	var own_team: int = StarsiegeMissionRuntime.TEAM_OF.get(team, 0)
	for nid in rt.battle.vehicles:
		var h: Herc = rt.battle.vehicles[nid]
		if h.alive and h.team != own_team and not SSTeams.is_neutral(h.team) and h.global_position.distance_to(c) < r:
			return 0
	return 1


# ------------------------------------------------------------------ damage

func _damage_object(_n: String, a: Array):
	var amount := SSScript.num(_arg(a, 1, 0))
	_damage(tree.node_of(tree.resolve(_arg(a, 0))), amount * rt.damage_factor)
	return ""


## damageArea(obj, dx, dy, dz, radius, amount): linear falloff with distance from the blast centre
## (approximation).
func _damage_area(_n: String, a: Array):
	var did := tree.resolve(_arg(a, 0))
	var amount := SSScript.num(_arg(a, 5, 0))
	var c := tree.position_of(did) + _orig_point(a, 1)
	var r := SSScript.num(_arg(a, 4))
	var nodes: Array = []
	for k in tree.objects:
		nodes.append(tree.node_of(k))
	ScriptedDamage.apply_area(nodes, c, r, amount * rt.damage_factor, true, _damage)
	return ""


## Scripted damage: Hercs take it spread over their components, structures take it directly.
static func _damage(n: Node, amount: float) -> void:
	if n == null or not n.has_method("apply_hit") or not n.get("alive"):
		return
	if n is Herc:
		ScriptedDamage.apply_spread(n as Herc, amount)
	else:
		ScriptedDamage.apply(n, amount)


func _heal_object(_n: String, a: Array):
	var n := tree.node_of(tree.resolve(_arg(a, 0)))
	if n is Herc:
		(n as Herc).shield_front = (n as Herc).shield_max * 0.5
		(n as Herc).shield_rear = (n as Herc).shield_max * 0.5
	return ""


# ------------------------------------------------------------------ data and strings

func _exec(_n: String, a: Array):
	rt.load_script("scripts/" + SSScript.to_str(_arg(a, 0)))
	return ""


func _echo(_n: String, a: Array):
	rt.log_echo(a)
	return ""


func _data_store(_n: String, a: Array):
	rt.vm.set_field(_arg(a, 0), SSScript.to_str(_arg(a, 1)).to_lower(), _arg(a, 2))
	return ""


func _strcat(_n: String, a: Array):
	var s := ""
	for x in a:
		s += SSScript.to_str(x)
	return s

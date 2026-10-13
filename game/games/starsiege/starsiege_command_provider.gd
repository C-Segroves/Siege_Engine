class_name StarsiegeCommandProvider
extends CommandProvider
## The squad orders of Starsiege on the command map (docs/COMMAND_MAP.md section 3.2), read at import from the
## user's scripts (gameplay/squad_orders.json, tools/export_starsiege_squad.py: missionStdLib.cs
## addSquadmateOrders, the IDSTR_SQORDER labels, the pilots' voice sets) and laid out as the game had them:
##   the squad menu (F1-F4 then 1-7) on the player himself ("self"): Attack My Target (Attack $Order::Target),
##   Join On Me (Formation), Defend My Target (Guard $Order::Target), Go To Nav Point (Guard the selected nav point),
##   Halt! (Clear + HoldPosition); Hold Fire / Fire At Will have no remake behaviour and are not offered;
##   the map screen's clicks (Starsiege.exe 0x6dda27..: a squadmate, then) a point: guard it ("go to"), the player:
##   formation, a friendly: guard it, an enemy: attack it.
## Outside the map, F1-F3 call up squadmate 1-3 and F4 the squad (he answers CR), then 1-7 give the order (SquadKeys).
## Replies are the squadmate's own clips (his pilot's sm_<set> voice; Starsiege.exe order code): AT attack (WT and
## refused without a hostile target), FM join, GD guard, GO go to, GN halt; the map's attack and formation orders
## (plain order(), not orderSquadMate) are silent, as in the original.

const ORDERS_FILE := "gameplay/squad_orders.json"
## Generic voice sets when a unit's pilot has none (human male / Cybrid).
const HUMAN_VOICE := "hm1"
const CYBRID_VOICE := "cy1"
const PILOT_META := "ss_pilot"
## Squad menu functions -> [CommandGoal kind, reply code].
const MENU_GOALS := {"onAttackMyTarget": [CommandGoal.ATTACK, "at"], "onJoinOnMe": [CommandGoal.FORMATION, "fm"],
	"onDefendMyTarget": [CommandGoal.DEFEND, "gd"], "onGoToNavPoint": [CommandGoal.DEFEND, "go"],
	"onHalt": [CommandGoal.HOLD, "gn"]}
const REPLY_COUNTS := {"at": 2, "fm": 2, "gd": 2, "go": 2, "gn": 4, "wt": 1, "cr": 2}
const REFUSED_REPLY := "wt"
## A squadmate called up (F1-F4) answers CR before the order.
const CALL_UP_REPLY := "cr"
const CALL_UP_TEXT := "Standing by."

var _data: Dictionary = {}


static func make() -> StarsiegeCommandProvider:
	var p := StarsiegeCommandProvider.new()
	var j = Assets.load_json(ORDERS_FILE, "starsiege")
	p._data = j if j is Dictionary else {}
	return p


func make_title() -> String:
	return "MAP"


func make_menus() -> Dictionary:
	var squad := []
	for e in _data.get("menu", []):
		var goal: Array = MENU_GOALS.get(str(e.function), [])
		if not goal.is_empty():
			squad.append({"key": str(e.key), "label": str(e.label), "kind": goal[0], "task": str(e.function),
				"message": str(e.label), "ack": goal[1]})
	if squad.is_empty():
		return super.make_menus()
	return {"self": squad,
		"location": [{"key": "g", "label": "Go To", "kind": CommandGoal.DEFEND, "task": "map_guard_point", "message": "Go to", "ack": "go"}],
		"nav": [{"key": "g", "label": "Go To", "kind": CommandGoal.DEFEND, "task": "map_guard_point", "message": "Go to", "ack": "go"}],
		"player_friend": [{"key": "g", "label": "Guard", "kind": CommandGoal.ESCORT, "task": "map_guard_unit", "message": "Guard", "ack": "gd"}],
		"object_friend": [{"key": "g", "label": "Guard", "kind": CommandGoal.DEFEND, "task": "map_guard_unit", "message": "Guard", "ack": "gd"}],
		"player_enemy": [{"key": "a", "label": "Attack", "kind": CommandGoal.ATTACK, "task": "map_attack", "message": "Attack", "ack": ""}],
		"object_enemy": [{"key": "a", "label": "Attack", "kind": CommandGoal.ATTACK, "task": "map_attack", "message": "Attack", "ack": ""}]}


## $Order::Target is the player's target, $Order::NavPos his selected nav point (the exe sets them before running
## the menu item); Attack refuses a missing or friendly target (WT).
func resolve_order(battle: Node, commander: Node, _unit: Node, entry: Dictionary, where: Array) -> Dictionary:
	var reply := str(entry.get("ack", ""))
	match str(entry.task):
		"onAttackMyTarget", "onDefendMyTarget":
			var t = commander.get("target")
			if not (t is Node3D) or not bool(t.get("alive")):
				return {"where": where, "refused": true, "reply": REFUSED_REPLY}
			if str(entry.task) == "onAttackMyTarget" and not TeamRelations.is_hostile(int(commander.team), int(t.team)):
				return {"where": where, "refused": true, "reply": REFUSED_REPLY}
			return {"where": [t.global_position, int(t.get("net_id")), ""], "refused": false, "reply": reply}
		"onGoToNavPoint":
			var nav := _selected_nav(battle, commander)
			if nav == Vector3.INF:
				return {"where": where, "refused": true, "reply": ""}      # the script does nothing without a nav point
			return {"where": [nav, 0, ""], "refused": false, "reply": reply}
		"onHalt":
			return {"where": [_unit.global_position, 0, ""], "refused": false, "reply": reply}
	return {"where": where, "refused": false, "reply": reply}


## The nav point the player has selected (the mission's current one, else the nearest).
func _selected_nav(battle: Node, commander: Node) -> Vector3:
	var mission = battle.get("mission")
	var points: Array = mission.get("nav_points") if mission and mission.get("nav_points") is Array else []
	var index := int(mission.get("nav_index")) if mission and mission.get("nav_index") != null else 0
	if index >= 0 and index < points.size():
		return points[index]
	var best := Vector3.INF
	for n in battle.get_tree().get_nodes_in_group("nav_points"):
		var p: Vector3 = (n as Node3D).global_position
		if best == Vector3.INF or p.distance_to(commander.global_position) < best.distance_to(commander.global_position):
			best = p
	return best


## The squadmate's clip (his pilot's voice set; a generic one when the pilot has none).
func make_ack_line(unit: Node, entry: Dictionary, outcome := {}) -> Dictionary:
	var code := str(outcome.get("reply", entry.get("ack", "")))
	if code == "":
		return {}
	var voice := make_voice_set(unit)
	var clip := "squad/%s/%s%d.wav" % [voice, code, randi() % int(REPLY_COUNTS.get(code, 1)) + 1]
	return RadioLine.make(str(unit.get("display_name")), str(entry.get("label", "")) if code != REFUSED_REPLY else "No target",
		RadioLine.make_voice_name("starsiege", clip))


func make_call_up_line(unit: Node) -> Dictionary:
	return RadioLine.make(str(unit.get("display_name")), CALL_UP_TEXT, RadioLine.make_voice_name("starsiege",
		"squad/%s/%s%d.wav" % [make_voice_set(unit), CALL_UP_REPLY, randi() % int(REPLY_COUNTS[CALL_UP_REPLY]) + 1]))


## Starsiege's squad keys: F1-F3 a squadmate, F4 the squad, then 1-7 the order (SquadKeys).
func has_squad_keys() -> bool:
	return true


func make_voice_set(unit: Node) -> String:
	var pilot := str(unit.get_meta(PILOT_META, ""))
	var voice_set := str(_data.get("pilots", {}).get(pilot, ""))
	if voice_set != "":
		return voice_set
	return CYBRID_VOICE if str(unit.get("vehicle_id")).contains("cy") else HUMAN_VOICE

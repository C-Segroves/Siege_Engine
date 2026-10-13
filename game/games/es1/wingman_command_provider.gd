class_name WingmanCommandProvider
extends CommandProvider
## The wingman orders of Earthsiege 1 and Earthsiege 2 on the command map (docs/COMMAND_MAP.md section 3.1).
## The command map stands in for the cockpit's Command Display (HDD F7: pick a pilot, an order, then a target or a
## gridpoint) and FlashComm (MFD F2: orders to the whole squad); names are the cockpit's own (STRINGS0 group 0), keys
## the original hotkeys (DBSIM.EXE key tables: ES1 0x94084 FlashComm A G H O C E F, 0x948a4 Command Display
## D A F T G O C E), and every answer is the pilot's own line from the order handler (ES1 DBSIM.EXE 0x1a1cc, ES2
## 0x420aa0: same cases), spoken from his pilot table (WingmanRadio slot; audio/tables/pilot<n>_voice.json):
##   Attack my target (A)  17 engaging; 18 "what's your target?" without a live hostile target
##   Help me out! (H)      11 on my way, at the nearest enemy targeting the player; 29 "what?!" when there is none
##   Join on me (O) / Disengage (D)   30 affirmative within 25000 units of the leader, else 20 joining on your position
##   Attack enemy (A, a picked unit)  17; 29 when it is dead
##   Defend position (F)   23 switching to defensive mode (Earthsiege 2 also on a friendly unit)
##   Patrol gridpoint (T)  42 en route (the handler's line; 25 "patrolling" is never used)
##   Go to gridpoint (G)   42
## Orders with no remake behaviour (Ignore my target, Fire at will / Hold your fire, Scan, EMCON) are not offered.

## The orders' remake goals, by original order code (STRINGS0 group 0 slot) - see the table above.
const ES2_PACK := "es2"
## Original distances in world units (ES1 0x1a1cc: join within 25000, help-me-out search 60000).
const JOIN_NEAR_UNITS := 25000.0
const HELP_RANGE_UNITS := 60000.0
## Pilot table messages (pilot<n>_voice.json).
const MSG_ON_MY_WAY := 11
const MSG_ENGAGING := 17
const MSG_NO_TARGET := 18
const MSG_JOINING := 20
const MSG_DEFENSIVE := 23
const MSG_WHAT := 29
const MSG_AFFIRMATIVE := 30
const MSG_EN_ROUTE := 42
const STRINGS_FILE := "cockpit/strings0.json"
## STRINGS0 group 0 slots of the offered orders.
const SLOT_ATTACK_MY_TARGET := 0
const SLOT_HELP_ME_OUT := 2
const SLOT_JOIN_ON_ME := 3
const SLOT_DISENGAGE := 10
const SLOT_ATTACK_ENEMY := 11
const SLOT_DEFEND := 12
const SLOT_PATROL := 13
const SLOT_GOTO := 14

var pack := ""
var _names: Array = []
var _tables: Array[RadioTable] = []


static func make(p_pack: String) -> WingmanCommandProvider:
	var p := WingmanCommandProvider.new()
	p.pack = p_pack
	var strings = Assets.load_json(STRINGS_FILE, p_pack)
	p._names = strings[0] if strings is Array and not strings.is_empty() and strings[0] is Array else []
	for n in WingmanRadio.PILOT_TABLES:
		var t := RadioTable.load_table(p_pack, "pilot%d" % n)
		if not t.is_empty():
			p._tables.append(t)
	return p


func make_title() -> String:
	return "COMMAND DISPLAY"


## The cockpit's own name of order slot `slot` (the remake's label when the strings are missing).
func make_name(slot: int, fallback: String) -> String:
	var name := str(_names[slot]).strip_edges() if slot < _names.size() else ""
	return name if name != "" else fallback


func _entry(key: String, slot: int, fallback: String, kind: String, reply: int) -> Dictionary:
	var label := make_name(slot, fallback)
	return {"key": key, "label": label, "kind": kind, "task": "es_order_%d" % slot, "message": label, "ack": reply}


func make_menus() -> Dictionary:
	var place := [_entry("f", SLOT_DEFEND, "DEFEND POSITION", CommandGoal.DEFEND, MSG_DEFENSIVE),
		_entry("t", SLOT_PATROL, "PATROL GRIDPOINT", CommandGoal.DEFEND, MSG_EN_ROUTE),
		_entry("g", SLOT_GOTO, "GOTO GRIDPOINT", CommandGoal.MOVE, MSG_EN_ROUTE)]
	var attack := [_entry("a", SLOT_ATTACK_ENEMY, "ATTACK ENEMY", CommandGoal.ATTACK, MSG_ENGAGING)]
	var out := {
		"self": [_entry("a", SLOT_ATTACK_MY_TARGET, "ATTACK MY TARGET", CommandGoal.ATTACK, MSG_ENGAGING),
			_entry("h", SLOT_HELP_ME_OUT, "HELP ME OUT!", CommandGoal.ATTACK, MSG_ON_MY_WAY),
			_entry("o", SLOT_JOIN_ON_ME, "JOIN ON ME", CommandGoal.FORMATION, MSG_AFFIRMATIVE),
			_entry("d", SLOT_DISENGAGE, "DISENGAGE", CommandGoal.FORMATION, MSG_AFFIRMATIVE)],
		"location": place, "nav": place, "player_enemy": attack, "object_enemy": attack,
	}
	if pack == ES2_PACK:      # Earthsiege 2: Defend Position also takes a friendly unit (ES2GUIDE.HLP)
		out["player_friend"] = [_entry("f", SLOT_DEFEND, "DEFEND POSITION", CommandGoal.ESCORT, MSG_DEFENSIVE)]
	return out


## The order handler's checks: the player's own target for Attack my target, the nearest enemy after the player
## for Help me out, a live target for Attack enemy; Join on me answers by distance.
func resolve_order(battle: Node, commander: Node, unit: Node, entry: Dictionary, where: Array) -> Dictionary:
	var slot := int(str(entry.task).get_slice("_", 2))
	match slot:
		SLOT_ATTACK_MY_TARGET:
			var t = commander.get("target")
			if not (t is Herc) or not t.alive or not TeamRelations.is_hostile(int(commander.team), int(t.team)):
				return {"where": where, "refused": true, "reply": MSG_NO_TARGET}
			return {"where": [t.global_position, int(t.net_id), ""], "refused": false, "reply": MSG_ENGAGING}
		SLOT_HELP_ME_OUT:
			var e := _find_attacker_of(battle, commander)
			if e == null:
				return {"where": where, "refused": true, "reply": MSG_WHAT}
			return {"where": [e.global_position, int(e.net_id), ""], "refused": false, "reply": MSG_ON_MY_WAY}
		SLOT_ATTACK_ENEMY:
			var target = battle.vehicles.get(int(where[1]))
			if int(where[1]) != 0 and (not is_instance_valid(target) or not target.alive):
				return {"where": where, "refused": true, "reply": MSG_WHAT}
		SLOT_JOIN_ON_ME, SLOT_DISENGAGE:
			var near: bool = unit.global_position.distance_to(commander.global_position) <= JOIN_NEAR_UNITS * _metres_per_unit()
			return {"where": where, "refused": false, "reply": MSG_AFFIRMATIVE if near else MSG_JOINING}
	return {"where": where, "refused": false, "reply": int(entry.get("ack", 0))}


## The nearest live enemy whose target is the commander, within the original's search range.
func _find_attacker_of(battle: Node, commander: Node) -> Node3D:
	var best: Node3D = null
	var best_d := HELP_RANGE_UNITS * _metres_per_unit()
	for v in battle.vehicles.values():
		if is_instance_valid(v) and v.alive and v.get("target") == commander and TeamRelations.is_hostile(int(commander.team), int(v.team)):
			var d: float = v.global_position.distance_to(commander.global_position)
			if d < best_d:
				best_d = d
				best = v
	return best


func _metres_per_unit() -> float:
	return Packs.metres_per_unit(pack)


## The pilot's own line for the reply (his pilot table: the WingmanRadio slot, else the first table).
func make_ack_line(unit: Node, entry: Dictionary, outcome := {}) -> Dictionary:
	if _tables.is_empty():
		return super.make_ack_line(unit, entry, outcome)
	var slot := maxi(WingmanRadio.slot_of(unit), 0)
	var table := _tables[WingmanRadio.slot_table_index(slot, _tables.size())]
	var line := table.make_random_line(int(outcome.get("reply", entry.get("ack", 0))))
	if line.is_empty():
		return super.make_ack_line(unit, entry, outcome)
	return RadioLine.make(str(unit.get("display_name")), str(line.text), str(line.voice))

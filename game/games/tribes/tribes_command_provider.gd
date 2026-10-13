class_name TribesCommandProvider
extends CommandProvider
## The command map of Tribes 1 and Tribes 2 (docs/COMMAND_MAP.md section 3, docs/TRIBES_BASE_EQUIPMENT.md): the
## orders of the game's own menus (base_equipment.json "commands": Tribes 1 chatmenu.cs Command Menu with
## Commander::StarCommand's messages, Tribes 2 commanderMap.cs $CommandTask), by the original task tags:
##   Attack*  -> attack       Defend* -> defend      Meet* -> move        Escort* -> escort
##   Repair*  -> move (go and repair there)          Capture* / Return* -> move (to the flag)
## Tasks the remake's units cannot do (deploy, laze, mortar, bomb, waypoints) are left out.
## Where it opens: anywhere in both games (Tribes 1 sae.cs binds C to ToggleCommandMode, game.cs
## remoteCommandMode; Tribes 2 controlDefaults.cs binds C to toggleCommanderMap), and at a command station (Tribes 1
## CommandStation::onResupply switches the client to the command GUI; turret control, station-only in the original,
## is not modelled).
## Acknowledgement: Tribes 1 bots say nothing (ai.cs AI::onCommand only sets the waypoint); a Tribes 2 bot accepts a
## task from the commander map at once (aiHumanTasks.cs serverCmdAcceptTask) and the commander hears its voice's
## cmd.acknowledge (serverTasks.cs MsgTaskCompleted '~wvoice/<voice>/cmd.acknowledge.wav'; bots: voice Bot1).

const TASK_KINDS := {"Attack": CommandGoal.ATTACK, "Defend": CommandGoal.DEFEND, "Meet": CommandGoal.MOVE,
	"Escort": CommandGoal.ESCORT, "Repair": CommandGoal.MOVE, "Capture": CommandGoal.MOVE, "Return": CommandGoal.MOVE}
const T1_PACK := "tribes"
## The bots' voice (Tribes 2 aiBotProfiles: the Bot voice set).
const BOT_VOICE := "bot1"
const ACK_TEXT := "Command acknowledged."

var pack := ""
var _menus := {}


static func make(p_pack: String) -> TribesCommandProvider:
	var p := TribesCommandProvider.new()
	p.pack = p_pack
	var commands: Dictionary = TribesBase.load_specs(p_pack).get("commands", {})
	for menu in commands.get("menus", {}):
		var entries := []
		for e in commands.menus[menu]:
			var kind := make_kind(str(e.task))
			if kind != "":
				entries.append((e as Dictionary).merged({"kind": kind}))
		p._menus[menu] = entries
	return p


## The CommandGoal kind of an original task tag ("" when the remake's units cannot do it).
static func make_kind(task: String) -> String:
	for prefix in TASK_KINDS:
		if task.begins_with(prefix):
			return TASK_KINDS[prefix]
	return ""


func make_title() -> String:
	return "COMMAND MAP" if pack == T1_PACK else "COMMAND CIRCUIT"


func make_menus() -> Dictionary:
	return _menus if not _menus.is_empty() else super.make_menus()


func make_ack_line(unit: Node, _entry: Dictionary, _outcome := {}) -> Dictionary:
	var commands: Dictionary = TribesBase.load_specs(pack).get("commands", {})
	var reply := str(commands.get("replies", {}).get("ack", ""))
	if reply == "":
		return {}       # Tribes 1: bots do not answer
	var voice := ""
	if (commands.get("reply_voices", []) as Array).has(BOT_VOICE):
		voice = RadioLine.make_voice_name(pack, "%s/%s.wav" % [BOT_VOICE, reply])
	return RadioLine.make(str(unit.get("display_name")), ACK_TEXT, voice)

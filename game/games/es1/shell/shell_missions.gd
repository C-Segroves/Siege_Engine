class_name ShellMissions
extends RefCounted
## Missions from the shell: picking a single mission, briefing texts, launching (through
## EsShell.launch_handler or a stock skirmish Battle), the career's PROCEED chain and the
## debriefing after a battle.

const BATTLE_SCRIPT := "res://games/es1/battle.gd"
const BATTLE_SCENE := "res://games/es1/battle.tscn"
const PILOTING := "YOU ARE PILOTING: "
const UNARMED_WARNING_MENU := 3000  # original: "One or more Hercs in your squad is unarmed."
const GENERIC_BRIEFING_LINE := 8
const BRIEFING_LINES := 9           # commander lines per campaign (mission slots)
const DEBRIEF_SUCCESS_LINE := 1
## Career key: the campaign whose general transmission the pilot has heard.
const GENERAL_HEARD_KEY := "general_campaign"
const DEBRIEF_FAILURE_LINE := 4
## Campaign index -> terrain world index (GO table 0x80f14: terrain 1,2,2,0,0,3,3,3; world = terrain*6)
const CAMPAIGN_TERRAIN := [1, 2, 2, 0, 0, 3, 3, 3]
const ZONE_FOR_TERRAIN := [0, 1000, 1100, 1500]
const TERRAIN_COUNT := 4
const WORLDS_PER_TERRAIN := 6
const TIME_OF_DAY_STEP := 2

var shell: EsShell


func _init(p_shell: EsShell) -> void:
	shell = p_shell


# ------------------------------------------------------------------ single missions

func start_instant_action() -> void:
	var m: String = EsShell.SINGLE_MISSIONS[randi() % EsShell.SINGLE_MISSIONS.size()]
	shell.abort_requested = false
	await shell.sequences.play_briefing_transmission(0, make_briefing_line(m))
	start_mission(m, {"mode": "instant", "campaign": 0})


func _single_type() -> Array:
	return EsShell.SINGLE_TYPES[clampi(int(EsShell.single.type), 0, EsShell.SINGLE_TYPES.size() - 1)]


## A random disc mission of the selected SINGLE MISSION type.
func make_single_mission_name() -> String:
	var code: String = _single_type()[1]
	var pool := EsShell.SINGLE_MISSIONS.filter(func(n): return n.substr(3, 3) == code)
	return pool[randi() % pool.size()] if not pool.is_empty() else EsShell.SINGLE_MISSIONS[0]


static func make_briefing_line(mission_name: String) -> int:
	for t in EsShell.SINGLE_TYPES:
		if mission_name.substr(3, 3) == t[1]:
			return int(t[2])
	return GENERIC_BRIEFING_LINE


func make_single_briefing() -> String:
	var t := _single_type()
	var texts := ShellData.strings("C0_TEXT")
	return "%s\n\n%s" % [t[0], texts[int(t[2])] if int(t[2]) < texts.size() else ""]


# ------------------------------------------------------------------ briefing texts

## Career briefing map text: the commander's transmission for the next mission.
func make_career_briefing() -> String:
	var career := EsShell.career
	if career.is_empty():
		return shell.briefing_text
	var c := clampi(int(career.get("campaign", 0)), 0, 3)
	var texts := ShellData.strings("C%d_TEXT" % c)
	var line := int(career.get("slot", 0)) % BRIEFING_LINES
	return "MISSION %s\n\n%s" % [str(career.get("next_mission", "")), texts[line] if line < texts.size() else ""]


## Prefixes the briefing with the Herc the player will drive (replacing an earlier prefix).
func make_briefing_with_herc(text: String, use_career: bool) -> String:
	if text.begins_with(PILOTING):
		var k := text.find("\n\n")
		text = text.substr(k + 2) if k >= 0 else ""
	var entry := _make_player_entry(use_career)
	return "%s%s\n%s\n\n%s" % [PILOTING, str(entry.name).to_upper(),
		GaragePicker.make_weapons_text(entry.loadout).to_upper(), text]


func _make_player_entry(use_career: bool) -> Dictionary:
	if use_career and not EsShell.career.is_empty():
		return shell.hangar.career_campaign().garage.make_battle_entry()
	var v := Packs.vehicle(MissionLaunch.HERC_FOR_CAMPAIGN)
	return {"vehicle": MissionLaunch.HERC_FOR_CAMPAIGN, "name": str(v.get("name", "")), "loadout": v.get("loadout", [])}


# ------------------------------------------------------------------ launching

## BEGIN MISSION: the single mission or the career's next one; a career warns first when the
## selected Herc is unarmed.
func launch_current() -> void:
	if EsShell.flow == "career" and not EsShell.career.is_empty() and not _is_selected_herc_armed():
		shell.open_menu(UNARMED_WARNING_MENU)
		return
	launch_current_anyway()


## BEGIN MISSION without the unarmed-Herc warning.
func launch_current_anyway() -> void:
	if EsShell.flow == "single" or EsShell.career.is_empty():
		var p := {}
		for k in EsShell.single.params:
			p[str(k)] = EsShell.single.params[k]
		start_mission(make_single_mission_name(), {"mode": "single", "params": p})
	else:
		var st := EsShell.career.duplicate(true)
		st["mode"] = "career"
		start_mission(str(EsShell.career.get("next_mission", "")), st)


func _is_selected_herc_armed() -> bool:
	return Garage.make_armed_count(shell.hangar.selected_entry()) > 0


## Starts a mission. The mission runtime can take over via EsShell.launch_handler; the default starts a
## Battle with the stock skirmish setup on the campaign's terrain.
func start_mission(mission_name: String, campaign_state: Dictionary) -> void:
	if shell.launching:
		return
	shell.launching = true
	shell.show_launching(mission_name, campaign_state)
	await shell.get_tree().process_frame
	await shell.get_tree().process_frame
	if EsShell.launch_handler.is_valid():
		EsShell.launch_handler.call(shell, mission_name, campaign_state)
		return
	var battle: Node = load(BATTLE_SCENE).instantiate()
	battle.config = make_skirmish_config(mission_name, campaign_state)
	shell.replace_with(battle)


## Stock skirmish on the campaign's terrain (random terrain outside a career).
static func make_skirmish_config(mission_name: String, campaign_state: Dictionary) -> Dictionary:
	# loaded dynamically so the shell keeps working while battle.gd is being edited
	var cfg: Dictionary = load(BATTLE_SCRIPT).default_config()
	var camp := int(campaign_state.get("campaign", 0))
	var terrain: int = CAMPAIGN_TERRAIN[camp % CAMPAIGN_TERRAIN.size()]
	if campaign_state.get("mode", "") != "career":
		terrain = randi() % TERRAIN_COUNT
	var tod := int(campaign_state.get("params", {}).get("1120", 0))
	cfg.world = terrain * WORLDS_PER_TERRAIN + clampi(tod, 0, 2) * TIME_OF_DAY_STEP
	cfg.zone = ZONE_FOR_TERRAIN[terrain]
	cfg["mission"] = mission_name
	cfg["campaign_state"] = campaign_state
	return cfg


# ------------------------------------------------------------------ career / debriefing

## Career PROCEED / NEXT MISSION: General Gierling's transmission when a campaign begins (his welcome for a new
## pilot, his verdict on the last tour after that), then the commander's briefing transmission, then the hangar
## hub (MENU1700).
func career_proceed() -> void:
	var career := EsShell.career
	shell.abort_requested = false
	if needs_general_transmission(career):
		career.erase("new")
		career[GENERAL_HEARD_KEY] = int(career.get("campaign", 0))
		shell.careers.save(career)
		await shell.sequences.play_general_for_campaign(int(career.get("campaign", 0)))
	if not shell.abort_requested:
		await shell.sequences.play_briefing_transmission(int(career.get("campaign", 0)), int(career.get("slot", 0)) % BRIEFING_LINES)
	shell.history = [EsShell.MAIN_MENU, EsShell.CAREER_MENU]
	shell.goto_menu(EsShell.HANGAR_HUB)


## The general speaks at the first mission of a campaign the pilot has not heard him for (a new pilot: campaign 0).
static func needs_general_transmission(career: Dictionary) -> bool:
	var campaign := int(career.get("campaign", 0))
	if career.get("new", false):
		return true
	return int(career.get("slot", 0)) == 0 and int(career.get(GENERAL_HEARD_KEY, -1)) != campaign


## Back from the simulator with EsShell.mission_result set. A career mission whose pilot was killed is not
## counted: the death scene, then the replay prompt (show_pilot_killed). Otherwise the mission is recorded
## and autosaved at once; a career that ended plays its ending (GO.EXE 0x3ba93), else the debriefing
## officer, then the debriefing screen (MENU1520 career / MENU1510 single).
func show_debriefing() -> void:
	var res := EsShell.mission_result
	EsShell.mission_result = {}
	var state: Dictionary = EsShell.last_launch.get("state", {})
	var career := EsShell.career
	var is_career: bool = state.get("mode", "") == "career" and not career.is_empty()
	if is_career and Session.is_pilot_killed(res):
		await show_pilot_killed(career)
		return
	if is_career:
		_record_career_mission(career)
		var ending := make_career_ending(career)
		if ending != "":
			apply_career_end(career, ending)
			await shell.sequences.play_career_ending(ending)
			return
	var ok := bool(res.get("success", true))
	shell.debrief_text = str(res.get("text", "MISSION %s\n\n%s" % [EsShell.last_launch.get("mission", ""),
		"OBJECTIVES COMPLETED" if ok else "OBJECTIVES FAILED"]))
	shell.abort_requested = false
	await shell.sequences.play_debriefing(int(state.get("campaign", career.get("campaign", 0))),
		DEBRIEF_SUCCESS_LINE if ok else DEBRIEF_FAILURE_LINE)
	if is_career:
		career["debriefed"] = true
		shell.careers.save(career)
		shell.goto_menu(EsShell.CAREER_DEBRIEF_MENU)
	else:
		shell.history = [EsShell.MAIN_MENU, EsShell.SINGLE_MENU]
		shell.goto_menu(EsShell.SINGLE_DEBRIEF_MENU)


## A flown career mission: counted and autosaved (every finished mission, win or loss).
func _record_career_mission(career: Dictionary) -> void:
	career.missions = int(career.get("missions", 0)) + 1
	shell.careers.save(career)


## How a career mission ended the career ("" = it goes on): the campaign was won (status 99) or lost (-1)
## (GO.EXE 0x3ba93). A killed pilot does not end it any more: see show_pilot_killed.
static func make_career_ending(career: Dictionary) -> String:
	if bool(career.get("over", false)):
		return "campaign_won" if bool(career.get("victory", false)) else "campaign_lost"
	return ""


## Records the end in the career's save (it is over, and why) and lets the career go: the next PROCEED
## registers a new pilot (0x3b3db resets the current career name [M]); the finished career stays listed and
## its PROCEED shows CAREER OVER (MENU1260).
func apply_career_end(career: Dictionary, ending: String) -> void:
	career["over"] = true
	career["ending"] = ending
	shell.careers.save(career)
	EsShell.career = {}


# ------------------------------------------------------------------ pilot killed

## The pilot was killed (GO.EXE 0x3bc94: death song + ENDFA). The original marked the career dead until a
## backup was restored (MENU1250 "You were killed in action in this game. Please restore a backup to
## continue this career."); here the career goes back to its restore point (the save written at launch,
## also listed under CAREER BACKUPS) and the warning offers REPLAY next to DONE (the main menu; the career
## stays at that save).
func show_pilot_killed(career: Dictionary) -> void:
	var restored := ShellCareers.load_restore_point(str(career.name))
	if not restored.is_empty():
		EsShell.career = restored
		shell.careers.save(restored)
	await shell.sequences.play_pilot_killed()


## REPLAY: the career's mission again, from its restore point.
func replay_mission() -> void:
	EsShell.flow = "career"
	launch_current()

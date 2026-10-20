class_name MissionLaunch
extends RefCounted
## Connects the original shell (EsShell) to the mission compiler, campaign progression and battles.
##
## Career: the shell's career record carries "campaign_state" (Campaign.to_dict(), with the career's
## garage); the mission it launches is the campaign's current mission, compiled like the original
## shell did, flown in the garage's selected Herc with the crew's wingmen; the battle's result advances
## the campaign (success/failure branching, any-lists, next campaign) and reaches the garage.

const HERC_FOR_CAMPAIGN := "es1:RAPTOR"
const SHELL_SCENE := "res://es1_shell.tscn"


static func install() -> void:
	EsShell.launch_handler = Callable(MissionLaunch, "launch")


## The career's campaign (a new one for a career that has none yet, see ensure_campaign_state).
static func campaign_for(career: Dictionary) -> Campaign:
	ensure_campaign_state(career)
	return Campaign.from_dict(career.campaign_state)


## Gives `career` its campaign state (with the start garage) when it has none yet. Careers saved with
## the shell's own hangar (career.hangar, before the garage) keep their Hercs and armory.
static func ensure_campaign_state(career: Dictionary) -> void:
	var st = career.get("campaign_state")
	if not (st is Dictionary and not (st as Dictionary).is_empty()):
		career["campaign_state"] = Campaign.start(0).to_dict()
	var old = career.get("hangar")
	if old is Dictionary:
		career.campaign_state["garage"] = Garage.from_dict({"vehicles": old.get("hercs", []),
			"selected": old.get("selected", 0), "stock": old.get("armory", {})}).to_dict()
		career.erase("hangar")


static func launch(shell: Node, mission_name: String, state: Dictionary) -> void:
	var mode: String = state.get("mode", "single")
	# the player's Herc: the career garage's selected Herc and its loadout, else the default
	var herc := {"vehicle": str(state.get("herc", HERC_FOR_CAMPAIGN)), "loadout": [], "name": ""}
	if mode == "career" and not EsShell.career.is_empty():
		herc = make_career_battle_entry(EsShell.career)
	var vdef := Packs.vehicle(str(herc.get("vehicle", "")))
	if vdef.is_empty():
		herc = {"vehicle": HERC_FOR_CAMPAIGN, "loadout": [], "name": ""}
		vdef = Packs.vehicle(HERC_FOR_CAMPAIGN)
	if str(herc.name) == "":
		herc.name = str(vdef.get("name", herc.vehicle))
	var cfg := {"mode": "mission", "respawn": false, "herc_name": str(herc.name),
		"roster": {1: {"name": Net.player_name, "vehicle": herc.vehicle, "team": 0, "loadout": herc.loadout,
			"garage": herc.get("garage", {})}}}
	if mode == "career":
		ShellCareers.save_restore_point(EsShell.career)
		var c := campaign_for(EsShell.career)
		Session.campaign = c
		cfg["mission"] = c.load_current({"resolve_texts": true})
		cfg["mission_vars"] = c.prepared_vars()
		cfg["economy_pack"] = c.pack_id()
		cfg["squad"] = Session.make_squad_config(c, c.garage, cfg.mission)
	else:
		# single mission: shell options (ammo, damage, difficulty, visibility, time of day)
		var p: Dictionary = state.get("params", {})
		var opts := {"resolve_texts": true, "ammo": int(p.get("1116", 0)), "damage": int(p.get("1117", 0)),
			"difficulty": int(p.get("1118", 1)), "visibility": int(p.get("1119", 0)), "time_of_day": int(p.get("1120", 0))}
		var m := MissionCompiler.load_mission(mission_name, PackedInt32Array(), randi() & 0x7fffffff, -2, opts)
		if m.is_empty():
			m = MissionCompiler.load_mission("SM_SCR01", PackedInt32Array(), randi() & 0x7fffffff, -2, opts)
		cfg["mission"] = m
		Session.campaign = null
	Session.last_result = {}
	Session.front_end = SHELL_SCENE
	var battle: Node = load("res://games/es1/battle.tscn").instantiate()
	battle.config = cfg
	var tree := shell.get_tree()
	tree.root.add_child(battle)
	tree.current_scene = battle
	shell.queue_free()


## Called by Battle when returning to the shell: hands the result to the shell, gives it to the
## career's garage (a won mission's weapons, salvage tonnage, damage, losses) and advances the campaign.
## A career launch first writes the career's "before mission" restore point (ShellCareers); a killed
## pilot's mission is not recorded.
static func on_battle_finished(result: Dictionary) -> void:
	if Session.front_end != SHELL_SCENE:
		return   # an app battle: its campaign records the result at the debriefing (Session.finish_mission)
	EsShell.mission_result = result.duplicate()
	if Session.is_pilot_killed(result):
		return   # not counted: the career goes back to its restore point (ShellMissions.show_pilot_killed)
	if Session.campaign != null and not EsShell.career.is_empty():
		Session.apply_battle_result(Session.campaign, result)
		var vars: PackedInt32Array = result.get("vars", PackedInt32Array())
		Session.campaign.record_result(bool(result.get("success", false)), vars)
		EsShell.career["campaign_state"] = Session.campaign.to_dict()
		EsShell.career["campaign"] = Session.campaign.campaign
		EsShell.career["slot"] = Session.campaign.slot
		EsShell.career["next_mission"] = Session.campaign.current_mission()
		EsShell.career["over"] = Session.campaign.is_over()
		EsShell.career["victory"] = Session.campaign.is_victory()


## The career's battle Herc; a Classic career never takes a weapon Classic forbids into battle (those hardpoints stay empty).
static func make_career_battle_entry(career: Dictionary) -> Dictionary:
	var c := campaign_for(career)
	var entry := c.garage.make_battle_entry()
	if entry.is_empty() or not bool(career.get("classic", false)):
		return entry
	var ctx := c.availability_context()
	ctx["classic"] = true
	entry["loadout"] = (entry.loadout as Array).map(func(wid) -> String:
		return str(wid) if CampaignAvailability.make_weapon_count(ctx, str(wid)) != 0 else "")
	return entry

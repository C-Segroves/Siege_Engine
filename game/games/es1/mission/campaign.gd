class_name Campaign
extends RefCounted
## Earthsiege campaign progression (docs/formats/mission.md §9), data from
## gamedata/es1/missions/campaign.json (tools/export_missions.py).
##
##   var c := Campaign.start(0)                  # battle set btlset_0.dat
##   var m := c.load_current()                   # resolved mission (MissionCompiler)
##   ... play ...
##   c.record_result(success, mission_vars_after_sim)
##   if c.is_over(): c.is_victory() / c.is_game_over()
##   save: c.to_dict()  /  load: Campaign.from_dict(d)
##
## Rules: a battle set has campaigns 0..7, each a list of slots; a slot has variants, index 0 is
## played after a successful previous mission, index 1 after a failure. A variant that is not an
## .MSN names an any_*.dat list, one entry is picked at random. After the last slot the next
## campaign is chosen by the last result (next_campaign table: -1 game over, 99 victory).
## Mission vars carry over between missions; before each mission var1 = campaign, var2 = slot,
## var3 = time-of-day option, var4..6 = random(12) (GO 0x359d9).

const STATE_PLAYING := "playing"
const STATE_GAME_OVER := "game_over"
const STATE_VICTORY := "victory"
const PACK := "es1"

var battle_set := 0               ## index into campaign.json battle_set_files
var battle_set_file := ""
var campaign := 0
var slot := 0
var last_success := true
var state := STATE_PLAYING
var mission := ""                 ## current mission base name (any-list already resolved)
var mission_vars := PackedInt32Array()
var history := []                 ## [{mission, campaign, slot, success}]
var base_seed := 0                    ## base seed: any-list picks and per-mission compile seeds
var garage: Garage                     ## owned Hercs + armory stock (CAR_INIT.DAT, C_ARMORY.DAT, salvage)


## Shell dialogs (imported string lists) of the end-of-mission pages: killed in action, career over.
const KILLED_DIALOG := "shell/strings/MENU1250.json"
const CAREER_OVER_DIALOG := "shell/strings/MENU1260.json"

static func data() -> Dictionary:
	var j = MissionCompiler._load("campaign.json")
	return j if j != null else {}


## Start a new campaign game. battle_set: index into battle_set_files (0 = btlset_0.dat), or
## the file name itself (e.g. "test_btl.dat"). seed < 0 -> random.
static func start(p_battle_set: Variant = 0, p_seed := -1) -> Campaign:
	var c := Campaign.new()
	var d := data()
	var files: Array = d.get("battle_set_files", [])
	if p_battle_set is String:
		c.battle_set_file = p_battle_set
		c.battle_set = files.find(p_battle_set)
	else:
		c.battle_set = int(p_battle_set)
		c.battle_set_file = files[c.battle_set] if c.battle_set >= 0 and c.battle_set < files.size() else ""
	if p_seed < 0:
		var r := RandomNumberGenerator.new()
		r.randomize()
		p_seed = r.randi() & 0x7fffffff
	c.base_seed = p_seed
	c.mission_vars.resize(100)
	c.mission_vars.fill(0)
	c.garage = Es1Tech.make_start_garage()
	c.garage.apply_campaign_start(economy(), p_seed)
	c._enter_slot()
	return c


## The career's salvage economy (GarageEconomy: GO.EXE prices, CFG/DAMAGE.DAT repair costs).
static func economy() -> GarageEconomy:
	return GarageEconomy.make_for_pack(PACK)


func campaigns() -> Array:
	return data().get("battle_sets", {}).get(battle_set_file, [])


func slot_count(p_campaign := -1) -> int:
	var cs := campaigns()
	var ci := campaign if p_campaign < 0 else p_campaign
	return cs[ci].size() if ci >= 0 and ci < cs.size() else 0


func current_mission() -> String:
	return mission


func is_over() -> bool:
	return state != STATE_PLAYING


func is_victory() -> bool:
	return state == STATE_VICTORY


func is_game_over() -> bool:
	return state == STATE_GAME_OVER


## Deterministic compile seed for the current mission.
func mission_seed() -> int:
	return hash([base_seed, campaign, slot, history.size(), "msn"]) & 0x7fffffff


## Mission vars as the shell prepares them for the current mission.
func prepared_vars(options := {}) -> PackedInt32Array:
	var v := mission_vars.duplicate()
	v.resize(100)
	var rng := MissionCompiler.Rng.new(hash([base_seed, campaign, slot, history.size(), "vars"]) & 0x7fffffff)
	v[1] = campaign
	v[2] = slot
	v[3] = int(options.get("time_of_day", 0))
	v[4] = rng.call_n(12)
	v[5] = rng.call_n(12)
	v[6] = rng.call_n(12)
	return v


## Compile the current mission (campaign mode).
func load_current(options := {}) -> Dictionary:
	if is_over() or mission == "":
		return {}
	return MissionCompiler.load_mission(mission, prepared_vars(options), mission_seed(), campaign, options)


## Original rule (GO.EXE 0x159e9): a mission failed if its debriefing code (mission var 0) exceeds the
## threshold of its mission type (campaign.json "outcome_threshold", imported from the disc). A type outside
## the table uses the nearest entry. The one place both the battle (MissionRuntime) and the campaign ask.
static func is_failure(debrief_code: int, mission_type: int) -> bool:
	var th: Array = data().get("outcome_threshold", [])
	if th.is_empty():
		push_error("Campaign: campaign.json has no outcome_threshold; re-import Earthsiege")
		return false
	return debrief_code > int(th[clampi(mission_type, 0, th.size() - 1)])


## Record the result of the current mission and advance. vars: mission.var after the sim
## (empty = keep the current ones).
func record_result(success: bool, vars := PackedInt32Array()) -> void:
	if is_over():
		return
	if vars.size() > 0:
		mission_vars = vars.duplicate()
		mission_vars.resize(100)
	history.append({"mission": mission, "campaign": campaign, "slot": slot, "success": success})
	last_success = success
	slot += 1
	if slot >= slot_count():
		var nxt: Array = data().get("next_campaign", [])
		var n: int = -1
		if campaign >= 0 and campaign < nxt.size():
			n = nxt[campaign][0 if success else 1]
		if n == int(data().get("victory", 99)):
			state = STATE_VICTORY
		elif n < 0:
			state = STATE_GAME_OVER
		else:
			campaign = n
			slot = 0
	if is_over():
		mission = ""
	else:
		_enter_slot()


## Resolve the mission name of the current slot (variant by last result, any-list pick).
func _enter_slot() -> void:
	var cs := campaigns()
	if campaign < 0 or campaign >= cs.size() or slot >= cs[campaign].size():
		state = STATE_GAME_OVER
		mission = ""
		return
	var variants: Array = cs[campaign][slot]
	if variants.is_empty():
		mission = ""
		return
	var v: String = variants[mini(0 if last_success else 1, variants.size() - 1)]
	if not v.to_upper().ends_with(".MSN"):
		var lst: Array = data().get("any_lists", {}).get(v.to_lower(), [])
		if lst.is_empty():
			push_error("Campaign: empty mission list " + v)
			mission = ""
			return
		var r := RandomNumberGenerator.new()
		r.seed = hash([base_seed, campaign, slot, history.size(), "any"])
		v = lst[r.randi_range(0, lst.size() - 1)]
	mission = MissionCompiler.normalize_name(v)


## What the hangar may offer (CampaignAvailability context): tech released after the missions flown
## so far (Es1Tech); the stock is the garage's armory.
func availability_context() -> Dictionary:
	return Es1Tech.make_context(history.size(), last_success, garage.stock)


## Weapons recovered from destroyed enemies join the armory.
func apply_salvage(weapon_ids: Array) -> void:
	CampaignAvailability.apply_salvage(garage.stock, weapon_ids)


## A finished mission's result in the garage (before record_result): a won mission's weapons, the
## salvage tonnage, the squad's damage and losses (GarageReport). Returns the debriefing summary.
func apply_battle_result(result: Dictionary) -> Dictionary:
	if bool(result.get("success", false)):
		apply_salvage(result.get("salvage", []))
	return GarageReport.apply(garage, availability_context(), result)


## Wingmen the squad may take into a mission (SquadRoster): up to three in every mission.
func wingman_slots(_mission: Dictionary) -> int:
	return economy().make_squad_max()


## End-of-mission page texts (CampaignPresentation): the killed pilot's warning is the shell's MENU1250 dialog,
## the lost war its CAREER OVER dialog MENU1260 (imported string lists; the button label is dropped).
func make_presentation() -> Dictionary:
	return {"killed_prompt": CampaignPresentation.make_or(
			CampaignPresentation.make_dialog_text(PACK, KILLED_DIALOG, 1), "You were killed in action. Replay the mission?"),
		"victory_text": "VICTORY - Earth is free of the Cybrid threat.",
		"defeat_text": CampaignPresentation.make_or(
			CampaignPresentation.make_dialog_text(PACK, CAREER_OVER_DIALOG, 0, -1, "\n"), "GAME OVER - The Cybrids have won.")}


## The original shell's talking heads (CampaignPresentation, ShellTalkPanel), as the shell plays them
## (ShellMissions): the campaign's commander briefs the mission (MENU1499, line = slot by the shell's rule), the
## debriefing officer gives the verdict (MENU1510 / 1520).
func make_talks(moment: String, context: Dictionary) -> Array:
	var c := clampi(campaign, 0, ShellSequences.COMMANDER_COUNT - 1)
	match moment:
		CampaignPresentation.MOMENT_BRIEFING:
			return [{"speaker": "C%d" % c, "line": slot % ShellMissions.BRIEFING_LINES,
				"region": ShellTalkPanel.BRIEFING_REGION, "campaign": c}]
		CampaignPresentation.MOMENT_DEBRIEF:
			var ok := bool((context.get("result", {}) as Dictionary).get("success", false))
			return [{"speaker": "D%d" % c, "line": ShellMissions.DEBRIEF_SUCCESS_LINE if ok else ShellMissions.DEBRIEF_FAILURE_LINE,
				"region": ShellTalkPanel.DEBRIEFING_REGION, "campaign": c}]
	return []


## The game whose campaign this is (recorded in saves, Session.make_save_dict).
func pack_id() -> String:
	return PACK


func to_dict() -> Dictionary:
	return {"battle_set": battle_set, "battle_set_file": battle_set_file, "campaign": campaign, "slot": slot,
		"last_success": last_success, "state": state, "mission": mission,
		"mission_vars": Array(mission_vars), "history": history.duplicate(true), "seed": base_seed,
		"garage": garage.to_dict()}


static func from_dict(d: Dictionary) -> Campaign:
	var c := Campaign.new()
	c.battle_set = int(d.get("battle_set", 0))
	c.battle_set_file = str(d.get("battle_set_file", ""))
	c.campaign = int(d.get("campaign", 0))
	c.slot = int(d.get("slot", 0))
	c.last_success = bool(d.get("last_success", true))
	c.state = str(d.get("state", STATE_PLAYING))
	c.mission = str(d.get("mission", ""))
	var mv := PackedInt32Array()
	for x in d.get("mission_vars", []):
		mv.append(int(x))
	mv.resize(100)
	c.mission_vars = mv
	c.history = []
	for h in d.get("history", []):
		c.history.append({"mission": str(h["mission"]), "campaign": int(h["campaign"]), "slot": int(h["slot"]),
			"success": bool(h["success"])})
	c.base_seed = int(d.get("seed", 0))
	c.garage = _make_saved_garage(d)
	return c


## The saved garage; saves from before the garage get the start garage (with their armory stock).
static func _make_saved_garage(d: Dictionary) -> Garage:
	if d.get("garage") is Dictionary:
		return Garage.from_saved(d.garage, economy(), int(d.get("seed", 0)))
	var g := Es1Tech.make_start_garage()
	g.apply_campaign_start(economy(), int(d.get("seed", 0)))
	if d.get("armory") is Dictionary:
		g.stock = (d.armory as Dictionary).duplicate()
	return g

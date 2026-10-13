class_name CampaignES2
extends RefCounted
## Earthsiege 2 campaign progression (docs/formats/es2.md section 10), data from
## gamedata/es2/missions/campaign.json (python tools/mission_es2.py export). Same API as Campaign
## (ES1) so a saga front end can drive either:
##
##   var c := CampaignES2.start()
##   var m := c.load_current()            # resolved mission (MissionCompilerES2)
##   ... Battle with {"mode": "mission", "mission": m, "mission_vars": c.prepared_vars()} ...
##   c.record_result(success, battle_result.vars)
##
## Rules (docs/formats/es2_campaign_flow.md): careers 1..5 (theaters Alpha, Delta, Omicron, Bravo, Luna)
## of ten missions, played in order whatever the result; failing a must-win mission loses the war;
## mission variables carry over (var0 success, var1 career, var2 mission index). After every mission
## the shell's tech unlocks update `unlocks` and its weapon awards the garage's armory (Es2Tech); they
## decide what the hangar offers (availability_context()). The garage starts with HERCS.DAT's Hercs.

const STATE_PLAYING := "playing"
const STATE_GAME_OVER := "game_over"
const STATE_VICTORY := "victory"
const PACK := "es2"
## Mission var counting the squad's dead pilots (VSHELL 0x40eae7: "Losses").
const LOSSES_VAR := 9
## VSHELL clip table indices (0x470e74, docs/formats/es2_campaign_flow.md): campaign intros c1..c5, the five theater
## clips (in career order), the Luna dropship, the killed pilot, victory and credits.
const CLIP_CAMPAIGN_INTRO := 70
const CLIP_THEATER := 75
const CLIP_DROPSHIP := 85
const CLIP_DEATH := 82
const CLIP_VICTORY := 83
const CLIP_CREDITS := 84
const LUNA_CAMPAIGN := 5

var campaign := 1
var slot := 0
var last_success := true
var state := STATE_PLAYING
var mission := ""
var mission_vars := PackedInt32Array()
var history := []
var base_seed := 0
var unlocks := {}                 ## Es2Tech state: {vehicles, weapons}
var garage: Garage                ## owned Hercs + armory stock (HERCS.DAT, awards, salvage)


static func data() -> Dictionary:
	return MissionCompilerES2.campaign_data()


static func start(first_campaign := 1, p_seed := -1) -> CampaignES2:
	var c := CampaignES2.new()
	if p_seed < 0:
		var r := RandomNumberGenerator.new()
		r.randomize()
		p_seed = r.randi() & 0x7fffffff
	c.base_seed = p_seed
	c.campaign = first_campaign
	c.mission_vars.resize(MissionCompilerES2.NVARS)
	c.unlocks = Es2Tech.make_start_state()
	c.garage = Es2Tech.make_start_garage()
	c.garage.apply_campaign_start(economy(), p_seed)
	c._enter_slot()
	return c


## The campaign's salvage economy (GarageEconomy: HERC_INF / WEAPONS / DAMAGE.DAT).
static func economy() -> GarageEconomy:
	return GarageEconomy.make_for_pack(PACK)


func campaign_missions(ci := -1) -> Array:
	var want := campaign if ci < 0 else ci
	for e in data().get("campaigns", []):
		if int(e.get("index", -1)) == want:
			return e.get("missions", [])
	return []


func current_mission() -> String:
	return mission


func is_over() -> bool:
	return state != STATE_PLAYING


func is_victory() -> bool:
	return state == STATE_VICTORY


func is_game_over() -> bool:
	return state == STATE_GAME_OVER


func mission_seed() -> int:
	return hash([base_seed, campaign, slot, history.size(), "es2"]) & 0x7fffffff


## Mission vars before compiling: var1 = campaign, var2 = slot, var4..6 random (as Earthsiege 1).
func prepared_vars(_options := {}) -> PackedInt32Array:
	var v := mission_vars.duplicate()
	v.resize(MissionCompilerES2.NVARS)
	var rng := MissionCompiler.Rng.new(hash([base_seed, campaign, slot, history.size(), "vars"]) & 0x7fffffff)
	v[1] = campaign
	v[2] = slot
	v[4] = rng.call_n(12)
	v[5] = rng.call_n(12)
	v[6] = rng.call_n(12)
	return v


func load_current(_options := {}) -> Dictionary:
	if is_over() or mission == "":
		return {}
	return MissionCompilerES2.load_mission(mission, prepared_vars(), mission_seed(), campaign)


## Advance (VSHELL 0x412dc7): m++, wrapping to the next career; failing a must-win mission (each
## career's last mission, every Luna/C5 mission) loses the war; success after the last career = victory.
## A failed ordinary mission is not replayed. replay() restores the state before the last mission.
func record_result(success: bool, vars := PackedInt32Array()) -> void:
	if is_over():
		return
	_before = to_dict()
	if vars.size() > 0:
		mission_vars = vars.duplicate()
		mission_vars.resize(MissionCompilerES2.NVARS)
	mission_vars[0] = 1 if success else 0
	Es2Tech.apply_mission_vars(unlocks, garage.stock, mission_vars)
	history.append({"mission": mission, "campaign": campaign, "slot": slot, "success": success})
	last_success = success
	var must_win: Array = []
	for e in data().get("campaigns", []):
		if int(e.get("index", -1)) == campaign:
			must_win = e.get("must_win", [])
	var was_must_win := must_win.has(slot)
	slot += 1
	if slot >= campaign_missions().size():
		slot = 0
		campaign += 1
	if not success and was_must_win:
		state = STATE_GAME_OVER
	elif campaign_missions().is_empty():
		state = STATE_VICTORY if success else STATE_GAME_OVER
	if is_over():
		mission = ""
	else:
		_enter_slot()


var _before := {}


## "The war is lost. Replay the mission?" / "You were killed. Replay?": back to before the last result.
func replay() -> void:
	if _before.is_empty():
		return
	var c := CampaignES2.from_dict(_before)
	campaign = c.campaign
	slot = c.slot
	state = c.state
	mission = c.mission
	mission_vars = c.mission_vars
	history = c.history
	unlocks = c.unlocks
	garage = c.garage
	last_success = c.last_success
	_before = {}


func _enter_slot() -> void:
	var ms := campaign_missions()
	if slot >= ms.size():
		state = STATE_GAME_OVER if ms.is_empty() and history.is_empty() else STATE_VICTORY
		mission = ""
		return
	mission = String(ms[slot])


## What the hangar may offer (CampaignAvailability context); the stock is the garage's armory.
func availability_context() -> Dictionary:
	return Es2Tech.make_context(unlocks, garage.stock)


## Weapons recovered from destroyed enemies (results.dat list) join the armory.
func apply_salvage(weapon_ids: Array) -> void:
	CampaignAvailability.apply_salvage(garage.stock, weapon_ids)


## A finished mission's result in the garage (before record_result, VSHELL 0x40eae7): a won mission's
## weapons, the results.dat tonnage plus mission var 20's bonus, the squad's damage, write-offs and
## losses (GarageReport); dead pilots are added to mission var 9 ("Losses"). Returns the summary.
func apply_battle_result(result: Dictionary) -> Dictionary:
	if bool(result.get("success", false)):
		apply_salvage(result.get("salvage", []))
	var vars: PackedInt32Array = result.get("vars", PackedInt32Array())
	var bonus := GarageEconomy.BONUS_PER_POINT_KG * (vars[GarageEconomy.BONUS_VAR] if vars.size() > GarageEconomy.BONUS_VAR else 0)
	var summary := GarageReport.apply(garage, availability_context(), result, bonus)
	if vars.size() > LOSSES_VAR:
		vars[LOSSES_VAR] += (summary.killed as Array).size()
		result["vars"] = vars
	return summary


## Wingmen `mission` (resolved) gives the squad: its MSN group 0 Hercs besides the player.
func wingman_slots(mission: Dictionary) -> int:
	return MissionRuntimeES2.wingman_slots(mission)


## End-of-mission page texts (CampaignPresentation): the killed pilot is asked to replay (VSHELL game state 3;
## its dialog string is not among the imported tables, so the wording is the remake's).
func make_presentation() -> Dictionary:
	return {"killed_prompt": "Your Herc was destroyed. Fly the mission again?",
		"victory_text": "VICTORY - The Cybrids are driven from Earth and Luna.",
		"defeat_text": "GAME OVER - The Cybrids have won."}


## The shell's movies (CampaignPresentation): a campaign's first briefing opens with its intro and theater clips
## (Luna also the dropship), every briefing / debriefing plays the clip its MSN record names, a killed pilot the
## death clip, the won war victory and credits (es2_campaign_flow.md).
func make_movies(moment: String, context: Dictionary) -> Array:
	match moment:
		CampaignPresentation.MOMENT_BRIEFING:
			return _make_briefing_movies(context.get("mission", {}))
		CampaignPresentation.MOMENT_DEBRIEF:
			return _clips([int((context.get("result", {}) as Dictionary).get("debrief_clip", -1))])
		CampaignPresentation.MOMENT_KILLED:
			return _clips([CLIP_DEATH])
		CampaignPresentation.MOMENT_VICTORY:
			return _clips([CLIP_VICTORY, CLIP_CREDITS])
	return []


func _make_briefing_movies(m: Dictionary) -> Array:
	var ids := []
	if slot == 0:
		ids.append_array([CLIP_CAMPAIGN_INTRO + campaign - 1, CLIP_THEATER + campaign - 1])
		if campaign == LUNA_CAMPAIGN:
			ids.append(CLIP_DROPSHIP)
	ids.append(int((m.get("texts", {}) as Dictionary).get("briefing_clip", -1)))
	return _clips(ids)


static func _clips(ids: Array) -> Array:
	return ids.map(func(i): return CampaignPresentation.make_clip_file(PACK, int(i))).filter(func(f): return f != "")


## The game whose campaign this is (recorded in saves, Session.make_save_dict).
func pack_id() -> String:
	return PACK


func to_dict() -> Dictionary:
	return {"game": "es2", "campaign": campaign, "slot": slot, "last_success": last_success, "state": state,
		"mission": mission, "mission_vars": Array(mission_vars), "history": history.duplicate(true), "seed": base_seed,
		"unlocks": unlocks.duplicate(true), "garage": garage.to_dict()}


static func from_dict(d: Dictionary) -> CampaignES2:
	var c := CampaignES2.new()
	c.campaign = int(d.get("campaign", 1))
	c.slot = int(d.get("slot", 0))
	c.last_success = bool(d.get("last_success", true))
	c.state = str(d.get("state", STATE_PLAYING))
	c.mission = str(d.get("mission", ""))
	var mv := PackedInt32Array()
	for x in d.get("mission_vars", []):
		mv.append(int(x))
	mv.resize(MissionCompilerES2.NVARS)
	c.mission_vars = mv
	c.history = d.get("history", []).duplicate(true)
	c.base_seed = int(d.get("seed", 0))
	c.unlocks = _make_unlocks(d.get("unlocks"))
	c.garage = _make_saved_garage(d)
	return c


## Saved unlock state, or a fresh one for saves made before unlocks existed.
static func _make_unlocks(saved: Variant) -> Dictionary:
	var fresh := Es2Tech.make_start_state()
	if not saved is Dictionary:
		return fresh
	for k in fresh:
		if (saved as Dictionary).has(k):
			fresh[k] = saved[k]
	return fresh


## The saved garage; saves from before the garage get the start garage plus their old unlock stock.
static func _make_saved_garage(d: Dictionary) -> Garage:
	if d.get("garage") is Dictionary:
		return Garage.from_saved(d.garage, economy(), int(d.get("seed", 0)))
	var g := Es2Tech.make_start_garage()
	g.apply_campaign_start(economy(), int(d.get("seed", 0)))
	var old = d.get("unlocks", {}).get("stock") if d.get("unlocks") is Dictionary else null
	if old is Dictionary:
		g.stock = (old as Dictionary).duplicate()
	return g

extends Node
## Cross-scene game session state: the active campaign (single player or co-op host),
## the last battle result, and save/load of campaign progress.
##
## Flow: start_campaign() -> mission_config() -> (battle runs) -> Battle stores last_result ->
## menu calls finish_mission() -> campaign advances -> mission_config() for the next one ...
##
## Campaigns: one game's campaign alone (start_stage_campaign: Earthsiege, Earthsiege 2, Starsiege
## human / cybrid, run by the game's provider, Saga.PROVIDERS) or the saga (start_saga), each flown by a
## named pilot (start_new_campaign). Saves go to the shared store (SaveGames): the pilot's autosave after
## every finished mission and hangar change, a restore point when a mission is launched (a killed pilot
## replays the mission from it: replay_from_restore_point), and named saves between missions
## (save_manual). A save records which provider runs the campaign ("pack"), so loading restores the right
## game. Loading is always explicit (load_save); nothing loads a save as a side effect, and a finished
## campaign is not loaded. A co-op client never uses its own campaign: it plays the host's
## (clear_campaign() when it joins).

var campaign = null              # active stage campaign (Earthsiege Campaign or another game's provider object)
var saga: Saga = null             # series campaign (ES1 -> ES2 -> Starsiege) when playing the saga
const ES1_PACK := "es1"

var coop := false
## Classic campaign: only weapons the campaign's own game has released so far, earlier games' weapons, similar
## Battledrome weapons and basic infantry weapons (CampaignAvailability "classic"). Kept in the save.
var classic := false
## The pilot (and save) name the campaign is flown under.
var pilot_name := SaveGames.DEFAULT_PILOT
var last_result := {}            # {success, code, vars, mission, text}
var last_mission := {}           # the resolved mission dict of the battle just played
## Message for the front end's status line after a battle was left (e.g. "The host left the match.").
var front_end_status := ""
## The library home tab to open on next (set when a match or the launcher is left; "" keeps the last tab shown).
var front_end_tab := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--snap="):
			_snap(a.substr(7))


## Test helper: screenshot any scene after it settles, then quit.
func _snap(path: String) -> void:
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


## Scene to return to after a battle: the original Earthsiege shell when it launched the battle,
## else the app library / launcher.
## The app's main menu (game library); "Quit" in a game or campaign returns here, never to the desktop.
const MAIN_MENU_SCENE := "res://library.tscn"

var front_end := MAIN_MENU_SCENE


## The library home opens on its Play tab the next time (after leaving a match).
func show_play_tab() -> void:
	front_end_tab = "play"


func front_end_scene() -> String:
	return front_end


## Where the launcher's Back leads: the front end that opened it (library or original shell), kept
## while battles started from the launcher return to the launcher itself.
var launcher_home := "res://library.tscn"


func start_campaign(battle_set := 0, p_coop := false) -> void:
	saga = null
	campaign = Campaign.start(battle_set)
	classic = false
	coop = p_coop
	last_result = {}
	SaveGames.reset_clock(0.0)


## New campaign flown by `pilot`: `choice` is a MatchFlow.make_new_campaign_choices() entry (the saga, or
## one game's campaign); written to the pilot's autosave at once.
func start_new_campaign(choice: Dictionary, pilot: String, p_classic := false) -> void:
	if bool(choice.get("saga", false)):
		start_saga()
	else:
		start_stage_campaign(str(choice.pack), str(choice.get("variant", "")))
	classic = p_classic
	pilot_name = pilot if pilot.strip_edges() != "" else SaveGames.DEFAULT_PILOT
	autosave()


## Starts one game's campaign on its own: `pack` "es1" / "es2" / "starsiege" (variant "human" /
## "cybrid"), through the game's saga provider.
func start_stage_campaign(pack: String, variant := "") -> void:
	if not Saga.PROVIDERS.has(pack):
		push_error("Session: no campaign provider for '%s'" % pack)
		return
	saga = null
	campaign = load(Saga.PROVIDERS[pack]).start(variant)
	classic = false
	coop = false
	last_result = {}
	last_mission = {}
	SaveGames.reset_clock(0.0)


## Forgets the running campaign (a co-op client plays the host's campaign, never its own).
func clear_campaign() -> void:
	saga = null
	campaign = null
	last_mission = {}


func start_saga() -> void:
	saga = Saga.start_new()
	campaign = saga.campaign
	coop = false
	classic = false
	last_result = {}
	SaveGames.reset_clock(0.0)


func has_campaign() -> bool:
	if saga != null:
		return not saga.is_complete()
	return campaign != null and not campaign.is_over()


## Battle config for the campaign's current mission (resolved once, on the host, so every peer
## receives the identical mission). Single player: the garage's wingmen fly along ("squad") and the
## campaign's economy values the wrecks ("economy_pack").
func mission_config(roster := {}) -> Dictionary:
	var m := current_mission()
	var cfg := {"mode": "mission", "mission": m, "mission_vars": campaign.prepared_vars(),
		"respawn": false, "economy_pack": campaign_pack(campaign)}
	if not roster.is_empty():
		cfg["roster"] = roster
	if not coop and garage() != null:
		cfg["squad"] = make_squad_config(campaign, garage(), m)
	return cfg


## Wingman slots of the campaign's current mission (0 without a campaign or slots).
func wingman_slots() -> int:
	if campaign == null or not campaign.has_method("wingman_slots"):
		return 0
	return campaign.wingman_slots(current_mission())


## The wingmen `c`'s garage sends into mission `m` (SquadRoster; none when the provider has no slots).
static func make_squad_config(c: Object, g: Garage, m: Dictionary) -> Array:
	var slots: int = c.call("wingman_slots", m) if c.has_method("wingman_slots") else 0
	return SquadRoster.make_squad_config(g, slots)


func briefing() -> Dictionary:
	return current_mission().get("texts", {})


var _mission_key := ""


## The campaign's current mission, resolved once (briefing, pre-mission hangar and launch agree).
func current_mission() -> Dictionary:
	if campaign == null:
		return {}
	var key := "%d|%s" % [campaign.get_instance_id(), str(campaign.current_mission())]
	if last_mission.is_empty() or key != _mission_key:
		last_mission = campaign.load_current({"resolve_texts": true})
		_mission_key = key
	return last_mission


## The player Herc the current mission dictates ({vehicle, loadout}; {} when the mission leaves the
## choice to the player, like Earthsiege 1). Earthsiege 2 missions define the player's Herc and
## weapons, Starsiege campaigns a starting vehicle. The briefing offers it next to the garage's
## Hercs and defaults to it (battle config "use_mission_herc": false).
func mission_herc() -> Dictionary:
	return MissionKinds.make_mission_herc(current_mission())


## What the campaign lets the player build and arm now (CampaignAvailability context, its stock the
## garage's armory); {} = no limits (no campaign, or a provider without availability).
func availability_context() -> Dictionary:
	var ctx := {}
	if saga != null:
		ctx = saga.availability_context()
	elif campaign != null and campaign.has_method("availability_context"):
		ctx = campaign.availability_context()
	if classic and CampaignAvailability.is_restricted(ctx):
		ctx["classic"] = true
	return ctx


## The running campaign's garage (null when no campaign runs).
func garage() -> Garage:
	return campaign.get("garage") as Garage if campaign != null else null


## Called by the menu after a campaign battle returns. The result reaches the garage first (a won
## mission's weapons, salvage tonnage, the squad's damage and losses: apply_battle_result), then the
## pilot's autosave is rewritten. A killed pilot's mission is not recorded: the campaign stays at its
## restore point (must_replay).
func finish_mission() -> void:
	if campaign == null or last_result.is_empty() or must_replay():
		return
	apply_battle_result(campaign, last_result)
	var vars: PackedInt32Array = last_result.get("vars", PackedInt32Array())
	if saga != null:
		saga.record_result(bool(last_result.get("success", false)), vars)
		campaign = saga.campaign
	else:
		campaign.record_result(bool(last_result.get("success", false)), vars)
	last_mission = {}
	autosave()


## The pilot was killed in the battle just flown (Battle reports "pilot_killed": the player's Herc was destroyed).
static func is_pilot_killed(result: Dictionary) -> bool:
	return bool(result.get("pilot_killed", false))


## The last single-player campaign battle killed the pilot: the mission must be replayed from the restore
## point (or the campaign left at its last save), like the originals (Earthsiege: "restore a backup",
## Earthsiege 2: "You were killed. Replay?", Starsiege replays a failed mission).
func must_replay() -> bool:
	return not coop and campaign != null and is_pilot_killed(last_result)


## Hands a battle `result` to campaign `c`'s garage (providers without an economy only take the
## won mission's weapons); the summary is kept for the hangar (Garage.last_report).
static func apply_battle_result(c: Object, result: Dictionary) -> void:
	if c.has_method("apply_battle_result"):
		var summary: Dictionary = c.call("apply_battle_result", result)
		var g = c.get("garage")
		if g is Garage:
			(g as Garage).last_report = summary
	elif bool(result.get("success", false)) and c.has_method("apply_salvage"):
		c.call("apply_salvage", result.get("salvage", []))


# ------------------------------------------------------------------ saves (SaveGames)

## Rewrites the pilot's autosave of the running campaign.
func autosave() -> void:
	_write(SaveGames.make_autosave_id(campaign_key(), pilot_name), SaveGames.KIND_AUTOSAVE, pilot_name)


## Writes the "before mission" restore point; `launch` = the Herc the mission is flown in {vehicle, loadout, garage}.
func save_restore_point(launch: Dictionary) -> void:
	var d := make_save(SaveGames.KIND_RESTORE_POINT, "%s - before mission" % pilot_name)
	if d.is_empty():
		return
	d["launch"] = launch.duplicate(true)
	SaveGames.write(SaveGames.make_restore_point_id(campaign_key(), pilot_name), d)


## A named save of the running campaign (between missions); returns its id ("" when none runs).
func save_manual(save_name: String) -> String:
	var id := SaveGames.make_manual_id(save_name)
	return id if _write(id, SaveGames.KIND_MANUAL, save_name) else ""


## Saves the running campaign as `slot` (a named save called after the slot).
func save_campaign(slot: String) -> void:
	_write(slot, SaveGames.KIND_MANUAL, slot)


func _write(id: String, kind: String, save_name: String) -> bool:
	var d := make_save(kind, save_name)
	return not d.is_empty() and SaveGames.write(id, d)


## The save of the running campaign ({} when none runs).
func make_save(kind: String, save_name: String) -> Dictionary:
	if saga == null and campaign == null:
		return {}
	return SaveGames.make_save(campaign, saga, {"pilot": pilot_name, "playtime": SaveGames.clock_seconds(),
		"coop": coop, "kind": kind, "name": save_name, "classic": classic})


## The running campaign's save as an autosave ({} when none runs).
func make_save_dict() -> Dictionary:
	return make_save(SaveGames.KIND_AUTOSAVE, pilot_name)


## "saga", "es1", "starsiege_human" ... of the running campaign.
func campaign_key() -> String:
	var variant = campaign.get("variant") if campaign != null else null
	return SaveGames.make_campaign_key(campaign_pack(campaign) if campaign != null else "",
		str(variant) if variant != null else "", saga != null)


static func save_path(slot: String) -> String:
	return SaveGames.make_path(slot)


## True when slot `slot` holds a campaign save (does not load it).
static func has_saved_campaign(slot: String) -> bool:
	return SaveGames.exists(slot)


## Loads save `id` (replacing the running campaign); false when it is missing, unreadable, finished or
## needs a game that is not installed.
func load_save(id: String) -> bool:
	var d := SaveGames.read(id)
	if d.is_empty():
		return false
	var block := SaveGames.make_block_reason(SaveGames.make_entry(id, d))
	if block != "":
		push_warning("Session: save %s cannot be continued (%s)" % [id, block])
		return false
	apply_save_dict(d)
	return true


## Same as load_save (the older name).
func load_campaign(slot: String) -> bool:
	return load_save(slot)


## True when the running single-player campaign has a "before mission" restore point to replay from.
func has_restore_point() -> bool:
	return not coop and campaign != null and SaveGames.exists(SaveGames.make_restore_point_id(campaign_key(), pilot_name))


## True when the running campaign flies a failed mission again instead of moving on (Starsiege); the
## Earthsiege campaigns move on (GO.EXE failure branches, VSHELL 0x412dc7).
func replays_failed_missions() -> bool:
	return campaign != null and campaign.has_method("replays_failed_missions") and bool(campaign.call("replays_failed_missions"))


## Reloads the running campaign's restore point; returns the Herc its mission was launched with ({} when
## there is no restore point: the campaign is left as it is).
func replay_from_restore_point() -> Dictionary:
	var d := SaveGames.read(SaveGames.make_restore_point_id(campaign_key(), pilot_name))
	if d.is_empty():
		return {}
	apply_save_dict(d)
	return d.get("launch", {}) if d.get("launch") is Dictionary else {}


func apply_save_dict(d: Dictionary) -> void:
	last_result = {}
	last_mission = {}
	if d.has("saga"):
		saga = Saga.from_dict(d.saga)
		campaign = saga.campaign
	else:
		saga = null
		var pack := str(d.get("pack", guess_pack(d.campaign)))
		campaign = load(Saga.PROVIDERS.get(pack, Saga.PROVIDERS.es1)).restore(d.campaign)
	coop = d.get("coop", false)
	classic = bool(d.get("classic", false))
	pilot_name = str(d.get("pilot", pilot_name))
	SaveGames.reset_clock(float(d.get("playtime", 0.0)))


## "Campaign 2  -  mission 3" / "Human campaign  -  mission c1" for campaign `c`.
static func make_mission_heading(c: Object) -> String:
	if c == null:
		return ""
	if c.has_method("make_heading"):
		return c.call("make_heading")
	var number: Variant = c.get("campaign")   # Starsiege campaigns have a variant instead
	if number != null and campaign_pack(c) == ES1_PACK:
		number = int(number) + 1                  # Earthsiege counts its campaigns from 0 (C0..C3), its shell shows + 1
	var part := "Campaign %d" % int(number) if number != null else "%s campaign" % str(c.get("variant")).capitalize()
	return "%s  -  mission %s" % [part, c.current_mission()]


## The game ("es1" / "es2" / "starsiege") whose provider runs `c`.
static func campaign_pack(c: Object) -> String:
	if c.has_method("pack_id"):
		return c.call("pack_id")
	push_error("Session: campaign %s does not name its game; saved as Earthsiege" % c)
	return "es1"


## Saves from before the provider was recorded: recognised by their own fields.
static func guess_pack(campaign_dict: Dictionary) -> String:
	if campaign_dict.get("game") is String:
		return campaign_dict.game
	if campaign_dict.has("inventory_log") or campaign_dict.has("variant"):
		return "starsiege"
	if campaign_dict.has("unlocks"):
		return "es2"
	return "es1"

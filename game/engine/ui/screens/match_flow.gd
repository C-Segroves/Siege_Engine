class_name MatchFlow
## The launcher's game logic, kept out of its screens: hosting a LAN lobby, building battle configs
## (skirmish, hosted match, campaign mission) and where a campaign goes after a debriefing.

## Lobby modes, in the order of the host screen's mode picker.
## Versus first: a LAN game is a deathmatch unless the host picks otherwise (the map's game modes, LobbySettings).
const MODES := ["vs", "coop", "campaign", ExtractionRules.MODE]
const MODE_NAMES := ["Versus (the map's game modes)", "Co-op vs Cybrids", "Co-op campaign", "Extraction raid (loot, exfil, PvPvE)"]


## The MODES a host may pick with the installed packs (extraction needs a soldier pack: ExtractionRules.is_available).
static func make_offered_modes() -> Array:
	return MODES.filter(func(m: String) -> bool: return m != ExtractionRules.MODE or ExtractionRules.is_available())


## The name of MODES key `mode`.
static func make_mode_name(mode: String) -> String:
	return str(MODE_NAMES[MODES.find(mode)]) if MODES.has(mode) else mode
## Herc stats in mixed-game matches.
const BALANCES := ["balanced", "original"]
const BALANCE_NAMES := ["Balanced (cross-game speeds matched per weight class)", "Original (each game's own stats)"]
const DEFAULT_VEHICLE := "es1:RAPTOR"
const DEFAULT_FRAG_LIMIT := 10
## Co-op AI opponents: the Earthsiege Cybrid line-up, cycled.
const COOP_ENEMIES := ["es1:SCORPION", "es1:MONGOOSE", "es1:BULLDOG", "es1:ACHILLES", "es1:MIRIMAC",
	"es1:RAMSES", "es1:APOLLO"]
const COOP_AI_SKILL := [0.35, 0.05, 6]     # base, step, steps before wrapping
const VERSUS_AI_SKILL := [0.4, 0.1, 5]
const ENEMY_TEAM := 1
const FREE_FOR_ALL_TEAM_BASE := 10         # every pilot on an own team
const FREE_FOR_ALL_AI_TEAM_BASE := 100
const HOST_ID := 1
## The campaign the multiplayer-only menu and the co-op campaign lobby run.
const FIRST_CAMPAIGN_PACK := "es1"
## Lobby settings key of the co-op campaign host's offer (see make_campaign_offer).
const CAMPAIGN_OFFER := "campaign_offer"
const SAGA_TEXT := "Saga: Earthsiege -> Earthsiege 2 -> Starsiege"
## Short descriptions on the New campaign screen (campaign key -> text).
const CAMPAIGN_DESCRIPTIONS := {
	"saga": "The whole war in one career: Earthsiege, then Earthsiege 2, then Starsiege on the side you choose. "
		+ "Your Hercs, armory and crew carry over from game to game.",
	"es1": "Metaltech: Earthsiege (1994). The Cybrids rise against mankind; lead your lance through eight "
		+ "campaigns of the original career, salvaging and rebuilding Hercs between missions.",
	"es2": "Earthsiege 2 (1996). The Cybrids return from the Moon; fight across five theatres from Alpha "
		+ "to the assault on Luna, with flying Razors and a growing squad.",
	"starsiege_human": "Starsiege (1999), Human campaign. Fight for the free colonies across the solar "
		+ "system against the Imperial forces and the Cybrid threat.",
	"tribes_aa": "Tribes: Aerial Assault (2002, PS2). Five training missions, then the Blood Eagle campaign on foot. "
		+ "Needs Tribes 2 installed for the soldiers and base equipment; the scripted mission logic is not "
		+ "reproduced: each mission is a reach-and-destroy run.",
	"starsiege_cybrid": "Starsiege (1999), Cybrid campaign. Serve Prometheus as a Cybrid unit in the war "
		+ "against humanity (the original's advanced campaign).",
}


# ------------------------------------------------------------------ hosting

## Opens the LAN lobby with `settings` (see make_lobby_settings) and announces our Herc.
static func host_lobby(settings: Dictionary, vehicle_id: String) -> Error:
	var err := Net.host()
	if err != OK:
		return err
	if settings.mode == "campaign":
		Session.start_campaign(0, true)
	Net.set_settings(settings)
	Net.set_my_info("team", Net.make_join_team())
	Net.set_my_info("vehicle", vehicle_id if vehicle_id != "" else DEFAULT_VEHICLE)
	return OK


## Why the host may not start yet ("" = everybody is ready and, in a team match, on a team): the pilots without
## a team, else those who are not ready, are named.
static func make_start_block_reason() -> String:
	var unassigned := TeamAssignment.make_unassigned_names(Net.roster, Net.settings)
	if not unassigned.is_empty():
		return "No team yet: %s. Press Assign all or pick their teams." % ", ".join(unassigned)
	var waiting := Net.make_unready_names()
	if waiting.is_empty():
		return ""
	return "Waiting for %s to be ready." % ", ".join(waiting)


## Host, from the lobby: starts the match when every pilot is ready; returns why not otherwise ("" = started).
static func try_start_hosted_match() -> String:
	var reason := make_start_block_reason()
	if reason == "":
		start_hosted_match()
	return reason


## Host: applies `teams` ({peer: team}, TeamAssignment) to the roster.
static func apply_team_choices(teams: Dictionary) -> void:
	for peer in teams:
		Net.assign_team(int(peer), int(teams[peer]))


## Host only: starts the match for everybody in the lobby (the lobby asks try_start_hosted_match; a rematch from
## the results screen starts at once, everybody is on that screen).
static func start_hosted_match() -> void:
	var s := Net.settings
	if s.mode == "campaign":
		Net.start_game(make_campaign_match_config())
		return
	if ExtractionRules.is_extraction(s):
		apply_extraction_roster(bool(s.get("teams", false)))
		Net.start_game(make_extraction_config(s))
		return
	if s.mode == "vs" and not s.get("teams", false):
		apply_free_for_all_teams()
	Net.start_game(make_match_config(s, Packs.pilotable()))


## Co-op campaign host: publishes what the campaign lets every pilot fly in the lobby settings, so a
## client picks from the host's campaign, never from its own save.
static func publish_campaign_offer() -> void:
	if not (Net.is_host() and Net.settings.get("mode") == "campaign" and Session.has_campaign()):
		return
	var s := Net.settings.duplicate()
	s[CAMPAIGN_OFFER] = make_campaign_offer()
	Net.set_settings(s)


## {"garage": the campaign garage (Garage.to_dict()), "mission_herc": {vehicle, loadout} or {},
##  "heading": "Campaign 1  -  mission ..."}
static func make_campaign_offer() -> Dictionary:
	var garage := Session.garage()
	return {"garage": garage.to_dict() if garage != null else {}, "mission_herc": Session.mission_herc(),
		"heading": make_mission_heading()}


static func make_campaign_match_config() -> Dictionary:
	if not Session.has_campaign():
		Session.start_campaign(0, true)
	var roster := {}
	for id in Net.roster:
		roster[id] = Net.roster[id].duplicate()
		roster[id].team = 0
	var cfg := Session.mission_config(roster)
	cfg["use_mission_herc"] = false   # every pilot drives what they picked in the lobby hangar
	return cfg


## Battle config for a co-op / versus match with `settings`; AI drawn from `vehicles`.
static func make_match_config(s: Dictionary, vehicles: Array) -> Dictionary:
	var cfg := {"mode": s.mode, "teams": s.get("teams", false), LobbySettings.TEAM_COUNT_KEY: LobbySettings.make_team_count(s),
		LobbySettings.GAME_MODE_KEY: str(s.get(LobbySettings.GAME_MODE_KEY, GameModes.DEFAULT)),
		GameModes.SCORE_LIMIT_KEY: int(s.get(GameModes.SCORE_LIMIT_KEY, 0)),
		GameModes.TIME_LIMIT_KEY: int(s.get(GameModes.TIME_LIMIT_KEY, 0)),
		"frag_limit": s.get("frag_limit", DEFAULT_FRAG_LIMIT),
		"balance": s.get("balance", BALANCES[0]), "respawn": s.mode == "vs", "ai": make_ai_roster(s, vehicles),
		"start": BattleInfantry.START_ON_FOOT, InfantryBots.CONFIG_KEY: int(s.get(InfantryBots.CONFIG_KEY, 0))}
	cfg.merge(MapPicker.config_at(int(s.get("world_idx", 0))), true)
	_apply_infantry_pack(cfg, s)
	return cfg


## The match's infantry game: the host's choice when he made one (both Tribes installed).
static func _apply_infantry_pack(cfg: Dictionary, s: Dictionary) -> void:
	var pack := str(s.get(LobbySettings.INFANTRY_PACK_KEY, ""))
	if pack != "":
		cfg[LobbySettings.INFANTRY_PACK_KEY] = pack


static func make_ai_roster(s: Dictionary, vehicles: Array) -> Array:
	var out := []
	for i in int(s.get("ai", 0)):
		if s.mode == "coop" or vehicles.is_empty():
			out.append({"vehicle": COOP_ENEMIES[i % COOP_ENEMIES.size()], "team": ENEMY_TEAM,
				"skill": _make_skill(COOP_AI_SKILL, i)})
		else:
			var v: Dictionary = vehicles[randi() % vehicles.size()]
			var team: int = LobbySettings.make_ai_team(s, i) if s.get("teams", false) else FREE_FOR_ALL_AI_TEAM_BASE + i
			out.append({"vehicle": v.id, "team": team, "skill": _make_skill(VERSUS_AI_SKILL, i), "name": "AI %s" % v.name})
	return out


## Free-for-all versus: every pilot on an own team.
static func apply_free_for_all_teams() -> void:
	var k := 0
	for id in Net.roster:
		Net.roster[id].team = FREE_FOR_ALL_TEAM_BASE + k
		k += 1


static func _make_skill(curve: Array, i: int) -> float:
	return curve[0] + curve[1] * (i % int(curve[2]))


# ------------------------------------------------------------------ extraction raids

## Battle config of an extraction raid (docs/design/extraction.md): the lobby settings' map, faction soldiers
## ("infantry_bots") and faction vehicles ("ai"); nobody respawns.
static func make_extraction_config(s: Dictionary) -> Dictionary:
	var cfg := {"mode": ExtractionRules.MODE, "teams": bool(s.get("teams", false)), "balance": s.get("balance", BALANCES[0]),
		"ai": [], ExtractionSquads.VEHICLES_KEY: int(s.get("ai", 0)), InfantryBots.CONFIG_KEY: int(s.get(InfantryBots.CONFIG_KEY, 0)),
		"start": BattleInfantry.START_ON_FOOT}
	cfg.merge(MapPicker.config_at(int(s.get("world_idx", 0))), true)
	cfg["respawn"] = false
	cfg[ExtractionFactions.CONFIG_KEY] = str(s.get(ExtractionFactions.CONFIG_KEY, ExtractionFactions.DEFAULT_PRESET))
	return cfg


## The roster of a raid: every pilot wears his kit's armour; squads by lobby team, else each on his own team.
static func apply_extraction_roster(squads: bool) -> void:
	var k := 0
	for id in Net.roster:
		apply_extraction_entry(Net.roster[id], k, squads)
		k += 1


static func apply_extraction_entry(entry: Dictionary, k: int, squads: bool) -> void:
	var kit: Dictionary = entry.get("kit", {}) if entry.get("kit") is Dictionary else {}
	var armor_id := str(kit.get("armor", ""))
	if InfantryCatalog.armor(armor_id).is_empty():
		armor_id = InfantryCatalog.light_armor_id(InfantryCatalog.make_default_pack())
	entry["vehicle"] = armor_id
	entry["loadout"] = []
	entry["kit"] = kit
	entry["team"] = int(ExtractionRules.data().get("player_team_base", 10)) + (int(entry.get("team", 0)) if squads else k)


## A solo raid with `profile`'s kit on `map_config` against `soldiers` faction soldiers and `vehicles` vehicles.
static func make_extraction_solo_config(profile: ExtractionProfile, map_config: Dictionary, soldiers: int, vehicles: int) -> Dictionary:
	var entry := {"name": Net.player_name, "team": 0, "kit": profile.make_kit_dict()}
	apply_extraction_entry(entry, 0, false)
	var cfg := make_extraction_config({"world_idx": 0, "ai": vehicles, InfantryBots.CONFIG_KEY: soldiers})
	cfg.merge(map_config, true)
	cfg["respawn"] = false
	cfg["roster"] = {HOST_ID: entry}
	return cfg


# ------------------------------------------------------------------ single player

static func make_solo_roster(vehicle_id: String, loadout: Array) -> Dictionary:
	return {HOST_ID: {"name": Net.player_name, "vehicle": vehicle_id if vehicle_id != "" else DEFAULT_VEHICLE,
		"team": 0, "loadout": loadout.duplicate()}}


static func make_skirmish_config(vehicle_id: String, loadout: Array, map_config: Dictionary) -> Dictionary:
	var cfg := Battle.default_config(vehicle_id)
	cfg.roster[HOST_ID].loadout = loadout.duplicate()
	cfg["start"] = BattleInfantry.START_ON_FOOT   # the player starts on foot beside the chosen vehicle
	cfg.merge(map_config, true)
	return cfg


## The soldier an on-foot mission issues ({vehicle: "<pack>:<armour>", loadout}); armours are not vehicles
## (Packs.vehicle), so this asks the mission's runtime directly, as the battle does.
static func make_issued_soldier() -> Dictionary:
	var mission := Session.current_mission()
	return MissionKinds.runtime_script(mission).make_mission_herc(mission) if not mission.is_empty() else {}


## The current campaign mission with the Herc chosen in the pre-mission hangar; `garage_tag` names the
## garage Herc it is (Garage.make_battle_tag; {} for the Herc a mission issues).
static func make_mission_config(vehicle_id: String, loadout: Array, garage_tag := {}) -> Dictionary:
	var roster := make_solo_roster(vehicle_id, loadout)
	if not garage_tag.is_empty():
		roster[HOST_ID]["garage"] = garage_tag.duplicate(true)
	var cfg := Session.mission_config(roster)
	cfg["use_mission_herc"] = false   # the hangar choice (default = the mission's Herc) wins
	return cfg


# ------------------------------------------------------------------ campaign progress

## The campaign entries in saga order, one per game and side:
## [{text, pack, variant, playable, key, description}] ("Earthsiege 2 campaign", "Starsiege: Human campaign" ...).
static func make_campaign_entries() -> Array:
	var out := []
	for stage in Saga.available_stages():
		var stage_def: Dictionary = Saga.STAGES[int(stage.index)]
		for variant in stage_def.get("choice", [""]):
			var text := "%s campaign" % stage_def.name if variant == "" else "%s: %s campaign" % [stage_def.name, str(variant).capitalize()]
			var key := SaveGames.make_campaign_key(str(stage_def.pack), str(variant), false)
			out.append({"text": text, "pack": stage_def.pack, "variant": variant, "playable": bool(stage.playable),
				"key": key, "description": str(CAMPAIGN_DESCRIPTIONS.get(key, ""))})
	for s in Saga.STANDALONE:
		var key := SaveGames.make_campaign_key(str(s.pack), "", false)
		var playable := Assets.has_pack(str(s.pack)) and (s.get("needs", []) as Array).all(
			func(p: String) -> bool: return Assets.has_pack(p))
		out.append({"text": "%s campaign" % s.name, "pack": s.pack, "variant": "", "playable": playable,
			"key": key, "description": str(CAMPAIGN_DESCRIPTIONS.get(key, ""))})
	return out


## The New campaign screen's choices: the saga first, then every game's campaign (make_campaign_entries);
## the saga entry has "saga": true and is playable while any of its stages is.
static func make_new_campaign_choices() -> Array:
	var saga_playable := Saga.available_stages().any(func(s: Dictionary) -> bool: return bool(s.playable))
	var out := [{"text": SAGA_TEXT, "pack": "", "variant": "", "saga": true, "playable": saga_playable,
		"key": SaveGames.SAGA_KEY, "description": str(CAMPAIGN_DESCRIPTIONS[SaveGames.SAGA_KEY])}]
	out.append_array(make_campaign_entries())
	return out


## Records the debriefed mission in the campaign (and autosaves).
static func apply_mission_result() -> void:
	Session.finish_mission()
	Session.last_result = {}


## Where to go after a debriefing: {"screen": "end"|"briefing"|"lobby", "text": end-page text, "replay": the
## lost campaign can be replayed from its restore point}.
static func make_next_after_debrief() -> Dictionary:
	if Session.saga != null:
		if Session.saga.is_complete():
			return {"screen": "end", "text": "THE SAGA IS COMPLETE."}
		if Session.campaign != null and Session.campaign.is_over() and not Session.campaign.is_victory():
			return make_campaign_lost_page()
		return {"screen": "briefing"}
	if Session.campaign.is_victory():
		return {"screen": "end", "text": str(CampaignPresentation.of(Session.campaign).victory_text)}
	if Session.campaign.is_over():
		return make_campaign_lost_page()
	return {"screen": "lobby" if Net.is_online() else "briefing"}


## The war is lost: Earthsiege 2 asks "replay the mission?" (reloads its launch autosave, VSHELL game state 0),
## Earthsiege's CAREER OVER says "restore a backup to replay this career" (MENU1260).
static func make_campaign_lost_page() -> Dictionary:
	return {"screen": "end", "text": str(CampaignPresentation.of(Session.campaign).defeat_text),
		"replay": Session.has_restore_point()}


## Replays the running campaign's last mission from its restore point, in the Herc it was launched in
## (the briefing when the launch was not recorded).
static func replay_mission(launcher: Launcher) -> void:
	var launch := Session.replay_from_restore_point()
	Session.last_result = {}
	if launch.has("vehicle"):
		launcher.start_battle(make_mission_config(str(launch.vehicle), launch.get("loadout", []),
			make_restored_garage_tag(launch.get("garage", {}))))
	else:
		launcher.show_campaign()


## The restored garage's tag of the Herc `saved_tag` named (its uid), {} for the Herc a mission issues.
static func make_restored_garage_tag(saved_tag: Dictionary) -> Dictionary:
	var g := Session.garage()
	if saved_tag.is_empty() or g == null:
		return {}
	for e in g.vehicles:
		if int(e.uid) == int(saved_tag.get("uid", -1)):
			return Garage.make_battle_tag(e)
	return {}


## "Campaign 2 - mission 3" / "Human campaign - mission c1" of the running campaign.
static func make_mission_heading() -> String:
	return Session.make_mission_heading(Session.campaign)

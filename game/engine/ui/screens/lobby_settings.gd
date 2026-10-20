class_name LobbySettings
## The LAN lobby's settings (Net.settings), made by the host screen and replicated to every pilot:
##   mode            "vs" | "coop" | "campaign" | "extraction" (MatchFlow.MODES)
##   game_mode       the map's game mode id (GameModes; versus only; "deathmatch" by default)
##   teams           true in a team game mode (versus) or with squads (extraction)
##   team_count      teams of a team match (2..4, clamped to the mode and the map: CatalogBridge.make_team_range)
##   score_limit, time_limit_s  a game mode's limits the host changed from its defaults (0 = the mode decides;
##                   GameModes); frag_limit is the deathmatch family's kill limit
##   map, world_idx  the MapPicker entry; frag_limit, ai (AI units / faction vehicles), infantry_bots (bots /
##                   faction soldiers), balance, infantry_pack (the infantry game when both Tribes are installed),
##                   extraction_relations (the factions' relation preset)
##   max_bots        the cap on live AI units (BotBudget; 0 = none)
##   solo            an offline session (skirmish, single player campaign or raid); coop a LAN campaign (it pays as
##                   "campaign.coop"); goal_seed (GameOptionsModel) the host's seed of the goal board
## Deathmatch puts every pilot and bot on a side of its own (MatchFlow.apply_free_for_all_teams).

const GAME_MODE_KEY := "game_mode"
const TEAM_COUNT_KEY := "team_count"
const INFANTRY_PACK_KEY := "infantry_pack"
const RELATIONS_KEY := CatalogBridge.RELATIONS_CONFIG_KEY
const DEFAULT_TEAM_COUNT := 2
const MODE_TITLES := {"vs": "Versus", "coop": "Co-op", "campaign": "Co-op campaign", "extraction": "Extraction raid"}


## Settings from the host screen's choices: {mode, game_mode ({id, team_based}), team_count, squads, frag_limit,
## ai, infantry_bots, balance, map_name, world_idx, infantry_pack, relations}.
static func make(choice: Dictionary) -> Dictionary:
	var mode := str(choice.mode)
	var game_mode: Dictionary = choice.get("game_mode", {})
	var teams := bool(game_mode.get("team_based", false)) if mode == "vs" else (mode == ExtractionRules.MODE and bool(choice.get("squads", false)))
	var s := {"mode": mode, "teams": teams, TEAM_COUNT_KEY: int(choice.get("team_count", DEFAULT_TEAM_COUNT)) if teams else DEFAULT_TEAM_COUNT,
		"frag_limit": int(choice.get("frag_limit", MatchFlow.DEFAULT_FRAG_LIMIT)), "ai": int(choice.get("ai", 0)),
		InfantryBots.CONFIG_KEY: 0 if mode == "campaign" else int(choice.get(InfantryBots.CONFIG_KEY, 0)),
		"balance": str(choice.get("balance", MatchFlow.BALANCES[0])), "map": str(choice.get("map_name", "")),
		"world_idx": int(choice.get("world_idx", 0)), INFANTRY_PACK_KEY: str(choice.get("infantry_pack", ""))}
	if mode == "vs":
		s[GAME_MODE_KEY] = str(game_mode.get("id", GameModes.DEFAULT))
		var limits: Dictionary = choice.get("limits", {})
		s[GameModes.SCORE_LIMIT_KEY] = int(limits.get(GameModes.SCORE_LIMIT_KEY, 0))
		s[GameModes.TIME_LIMIT_KEY] = int(limits.get(GameModes.TIME_LIMIT_KEY, 0))
	if mode == ExtractionRules.MODE:
		s[RELATIONS_KEY] = str(choice.get("relations", ""))
	s[BotBudget.CONFIG_KEY] = maxi(int(choice.get(BotBudget.CONFIG_KEY, 0)), 0)   # the host's cap on live AI units, 0 = none
	s["solo"] = bool(choice.get("solo", false))
	s["coop"] = mode == "campaign" and not s.solo   # EconomyRules.make_mode_key: a LAN campaign pays as "campaign.coop"
	return s


## True when the pilots of `s` play in teams (the lobby lists the teams and lets pilots pick one).
static func is_team_match(s: Dictionary) -> bool:
	return bool(s.get("teams", false)) and str(s.get("mode", "")) in ["vs", ExtractionRules.MODE]


static func make_team_count(s: Dictionary) -> int:
	return clampi(int(s.get(TEAM_COUNT_KEY, DEFAULT_TEAM_COUNT)), CatalogBridge.MIN_TEAMS, CatalogBridge.MAX_TEAMS)


## The map config of the lobby's map (MapPicker entry), {} when the index is out of range.
static func make_map_config(s: Dictionary) -> Dictionary:
	var entries := MapPicker.make_entries()
	var i := int(s.get("world_idx", -1))
	return (entries[i].config as Dictionary) if i >= 0 and i < entries.size() else {}


## The infantry bots of a match with `s` as the lobby shows them: [{name, team}] (InfantryBots' teams).
static func make_planned_bots(s: Dictionary) -> Array:
	var cfg := s.duplicate()
	var out := []
	for i in clampi(int(s.get(InfantryBots.CONFIG_KEY, 0)), 0, InfantryBots.MAX_BOTS):
		out.append({"key": "bot:%d" % i, "name": "Bot %d" % (i + 1), "team": InfantryBots.make_team(cfg, i)})
	return out


## The AI units of a team versus match with `s` as the lobby shows them: [{name, team}] (MatchFlow.make_ai_roster
## deals them round the teams; which vehicle each flies is drawn when the match starts). [] in other matches.
static func make_planned_ai(s: Dictionary) -> Array:
	var out := []
	if str(s.get("mode", "")) != "vs" or not bool(s.get("teams", false)):
		return out
	for i in int(s.get("ai", 0)):
		out.append({"key": "ai:%d" % i, "name": "AI unit %d" % (i + 1), "team": make_ai_team(s, i)})
	return out


## Every computer-controlled member of a team match: the infantry bots, then the AI units ([{name, team, kind}]).
static func make_planned_members(s: Dictionary) -> Array:
	var out := []
	for b in make_planned_bots(s):
		out.append(b.merged({"kind": "infantry bot"}))
	for a in make_planned_ai(s):
		out.append(a.merged({"kind": "AI vehicle"}))
	return out


## The team of AI unit `i` in a team versus match with `s`.
static func make_ai_team(s: Dictionary, i: int) -> int:
	var count := make_team_count(s)
	var picked := int((s.get(InfantryBots.MEMBER_TEAMS_KEY, {}) as Dictionary).get("ai:%d" % i, -1))
	return picked if picked >= 0 and picked < count else i % count


## Host: settings `s` with the computer-controlled member `key` ("bot:<i>" / "ai:<i>") put on `team`.
static func make_with_member_team(s: Dictionary, key: String, team: int) -> Dictionary:
	var out := s.duplicate(true)
	var picks: Dictionary = out.get(InfantryBots.MEMBER_TEAMS_KEY, {})
	picks[key] = team
	out[InfantryBots.MEMBER_TEAMS_KEY] = picks
	return out


## One-line description of the settings.
static func make_summary(s: Dictionary) -> String:
	if ExtractionRules.is_extraction(s):
		return "Extraction raid  -  %s%s  -  faction soldiers %d  -  faction vehicles %d" % [s.get("map", ""),
			", squads by team" if s.get("teams", false) else ", every pilot for himself", int(s.get(InfantryBots.CONFIG_KEY, 0)), int(s.get("ai", 0))]
	if s.get("mode") == "campaign":
		return "Co-op campaign  -  the host's campaign, its next mission"
	var title := str(MODE_TITLES.get(s.get("mode"), MODE_TITLES.vs))
	if s.get("mode") == "vs":
		title = make_game_mode_label(s)
	if is_team_match(s):
		title += " (%d teams)" % make_team_count(s)
	return "%s  -  %s  -  kill limit %d  -  AI units %d  -  infantry bots %d" % [title, s.get("map", ""),
		int(s.get("frag_limit", MatchFlow.DEFAULT_FRAG_LIMIT)), int(s.get("ai", 0)), int(s.get(InfantryBots.CONFIG_KEY, 0))]


static func make_game_mode_label(s: Dictionary) -> String:
	return GameModes.label_for(str(s.get(GAME_MODE_KEY, GameModes.DEFAULT)))

class_name GameOptionsModel
extends RefCounted
## The host's game options as pure changes of the lobby settings (Net.settings, LobbySettings): each make_with_* returns a
## new settings dictionary with the dependent keys kept consistent (the teams of a game mode, the limits of a map) and
## every key it does not own (member teams, the campaign offer, goal seed ...) untouched. The default settings of each
## way into the lobby (make_default_settings) are what "Host LAN game" opens at once; the host edits them in Game Options.

const KIND_VERSUS := "vs"
const KIND_COOP := "coop"
const KIND_EXTRACTION := "extraction"
const KIND_CAMPAIGN := "campaign"
const KIND_SKIRMISH := "skirmish"
const DEFAULT_AI := 4
const SKIRMISH_AI := 3
const RAID_SOLDIERS := 10
const RAID_VEHICLES := 3
const MAX_AI := 23
const MAX_FRAG_LIMIT := 100
const MAX_TIME_LIMIT_MIN := 60
const SECONDS_PER_MINUTE := 60
## Game mode families whose limit counts kills (the battle's frag limit); the others score captures / points.
const KILL_FAMILIES := ["deathmatch", "duel"]
const GOAL_SEED_KEY := "goal_seed"
## Maps preferred for a raid (big Tribes / Tribes 2 / Starsiege maps), by entry name.
const PREFERRED_RAID_MAPS := ["Tribes 2 map - Katabatic", "Tribes map - Raindance", "Tribes 2 map", "Tribes map", "Starsiege map"]


## The settings of a new lobby of `kind` (KIND_*): a LAN game, or with `solo` an offline session.
static func make_default_settings(kind: String, solo := false) -> Dictionary:
	var mode := KIND_VERSUS if kind == KIND_SKIRMISH else kind
	var choice := {"mode": mode, "world_idx": make_default_map_index(mode), "balance": MatchFlow.BALANCES[0],
		"ai": SKIRMISH_AI if kind == KIND_SKIRMISH else DEFAULT_AI}
	if mode == KIND_EXTRACTION:
		choice.merge({"ai": RAID_VEHICLES, InfantryBots.CONFIG_KEY: RAID_SOLDIERS}, true)
		choice["relations"] = str(CatalogBridge.make_relation_presets()[0].id)
	if mode == KIND_CAMPAIGN:
		choice["ai"] = 0
	var entries := MapPicker.make_entries()
	var entry: Dictionary = entries[int(choice.world_idx)] if int(choice.world_idx) < entries.size() else {}
	choice["map_name"] = str(entry.get("name", ""))
	choice["game_mode"] = _find_game_mode(entry, "")
	choice["infantry_pack"] = make_default_infantry_pack()
	var s := LobbySettings.make(choice)
	s[GOAL_SEED_KEY] = randi()
	s["solo"] = solo
	s["coop"] = mode == KIND_CAMPAIGN and not solo
	return s


## The infantry game a new lobby plays when several are installed: the one the pilot's active character slot was built
## for (so its armour is not "left off" at the first Ready), else his preference; "" when only one is installed.
static func make_default_infantry_pack() -> String:
	var packs := CatalogBridge.make_infantry_packs().map(func(p: Dictionary) -> String: return str(p.pack))
	if packs.size() < 2:
		return ""
	var slot_pack := OperatorProfile.load_for(Net.player_name).make_active_slot().pack
	return slot_pack if packs.has(slot_pack) else PlayerProfile.load_infantry_pack()


## The map entry index a new lobby of `mode` starts on (a raid prefers a big map; else the first).
static func make_default_map_index(mode: String) -> int:
	if mode != KIND_EXTRACTION:
		return 0
	var entries := MapPicker.make_entries()
	for wanted in PREFERRED_RAID_MAPS:
		for i in entries.size():
			if str(entries[i].name).begins_with(wanted):
				return i
	return 0


# ------------------------------------------------------------------ changes

## Another map: its name, a game mode it offers (the chosen one when it does), and that mode's teams and limits.
static func make_with_map(s: Dictionary, world_idx: int) -> Dictionary:
	var out := s.duplicate(true)
	var entries := MapPicker.make_entries()
	if world_idx < 0 or world_idx >= entries.size():
		return out
	out["world_idx"] = world_idx
	out["map"] = str(entries[world_idx].name)
	if str(s.get("mode", "")) == KIND_VERSUS:
		return _apply_game_mode(out, _find_game_mode(entries[world_idx], str(s.get(LobbySettings.GAME_MODE_KEY, ""))))
	return out


## Another game mode of the map (versus).
static func make_with_game_mode(s: Dictionary, mode_id: String) -> Dictionary:
	var entry := make_map_entry(s)
	return _apply_game_mode(s.duplicate(true), _find_game_mode(entry, mode_id))


## Another mode of the lobby: versus, co-op, the co-op campaign or an extraction raid. Versus and co-op keep the map, game
## mode and opponents; the campaign and the raid start from their own defaults (other maps, opponents and limits).
static func make_with_mode(s: Dictionary, mode: String) -> Dictionary:
	var out: Dictionary
	if mode in [KIND_CAMPAIGN, KIND_EXTRACTION] or str(s.get("mode", "")) in [KIND_CAMPAIGN, KIND_EXTRACTION]:
		out = make_default_settings(mode, bool(s.get("solo", false)))
		out[LobbySettings.INFANTRY_PACK_KEY] = s.get(LobbySettings.INFANTRY_PACK_KEY, out.get(LobbySettings.INFANTRY_PACK_KEY, ""))
		out["balance"] = s.get("balance", out.balance)
	else:
		out = LobbySettings.make({"mode": mode, "world_idx": int(s.get("world_idx", 0)), "map_name": s.get("map", ""),
			"game_mode": _find_game_mode(make_map_entry(s), str(s.get(LobbySettings.GAME_MODE_KEY, ""))), "ai": int(s.get("ai", DEFAULT_AI)),
			InfantryBots.CONFIG_KEY: int(s.get(InfantryBots.CONFIG_KEY, 0)), "balance": s.get("balance", MatchFlow.BALANCES[0]),
			"infantry_pack": s.get(LobbySettings.INFANTRY_PACK_KEY, ""), "relations": s.get(LobbySettings.RELATIONS_KEY, ""),
			"frag_limit": int(s.get("frag_limit", MatchFlow.DEFAULT_FRAG_LIMIT))})
		out["solo"] = bool(s.get("solo", false))
	for key in [GOAL_SEED_KEY, InfantryBots.MEMBER_TEAMS_KEY, BotBudget.CONFIG_KEY]:
		if s.has(key):
			out[key] = s[key]
	return out


static func make_with_value(s: Dictionary, key: String, value: Variant) -> Dictionary:
	var out := s.duplicate(true)
	out[key] = value
	return out


## Squads on or off in a raid (teams = squads).
static func make_with_squads(s: Dictionary, on: bool) -> Dictionary:
	var out := s.duplicate(true)
	out["teams"] = on
	return out


static func make_with_team_count(s: Dictionary, count: int) -> Dictionary:
	var teams := team_range(s)
	return make_with_value(s, LobbySettings.TEAM_COUNT_KEY, clampi(count, teams.x, teams.y))


## A score limit; the mode's own default is stored as 0 ("the mode decides").
static func make_with_score_limit(s: Dictionary, value: int) -> Dictionary:
	if is_kill_limit(s):
		return make_with_value(s, "frag_limit", value)
	return make_with_value(s, GameModes.SCORE_LIMIT_KEY, 0 if value == int(make_default_limits(s).score_limit) else value)


## A time limit in minutes; the mode's own default is stored as 0.
static func make_with_time_limit(s: Dictionary, minutes: int) -> Dictionary:
	var seconds := minutes * SECONDS_PER_MINUTE
	return make_with_value(s, GameModes.TIME_LIMIT_KEY, 0 if seconds == int(make_default_limits(s).time_limit_s) else seconds)


# ------------------------------------------------------------------ queries

static func make_map_entry(s: Dictionary) -> Dictionary:
	var entries := MapPicker.make_entries()
	var i := int(s.get("world_idx", -1))
	return entries[i] if i >= 0 and i < entries.size() else {}


## The game modes the lobby's map offers (CatalogBridge), deathmatch first.
static func make_game_modes(s: Dictionary) -> Array:
	return CatalogBridge.make_game_modes(make_map_entry(s))


static func team_range(s: Dictionary) -> Vector2i:
	var mode := _find_game_mode(make_map_entry(s), str(s.get(LobbySettings.GAME_MODE_KEY, "")))
	return CatalogBridge.make_team_range(mode, LobbySettings.make_map_config(s))


static func is_kill_limit(s: Dictionary) -> bool:
	return str(s.get("mode", "")) != KIND_VERSUS or GameModes.family_of(str(s.get(LobbySettings.GAME_MODE_KEY, GameModes.DEFAULT))) in KILL_FAMILIES


## The mode's own {score_limit, time_limit_s} on the lobby's map (0 = none).
static func make_default_limits(s: Dictionary) -> Dictionary:
	if str(s.get("mode", "")) != KIND_VERSUS:
		return {"score_limit": 0, "time_limit_s": 0}
	var map_id := str(LobbySettings.make_map_config(s).get("map", ""))
	return GameModes.make_default_limits(str(s.get(LobbySettings.GAME_MODE_KEY, GameModes.DEFAULT)), MapBuilder.load_map(map_id) if map_id != "" else {})


## The score (or kill) limit the match plays with, as the slider shows it.
static func make_shown_score_limit(s: Dictionary) -> int:
	if is_kill_limit(s):
		return int(s.get("frag_limit", MatchFlow.DEFAULT_FRAG_LIMIT))
	var chosen := int(s.get(GameModes.SCORE_LIMIT_KEY, 0))
	return chosen if chosen > 0 else int(make_default_limits(s).score_limit)


## The time limit in minutes as the slider shows it (0 = none).
static func make_shown_time_limit(s: Dictionary) -> int:
	var chosen := int(s.get(GameModes.TIME_LIMIT_KEY, 0))
	return (chosen if chosen > 0 else int(make_default_limits(s).time_limit_s)) / SECONDS_PER_MINUTE


# ------------------------------------------------------------------ helpers

static func _find_game_mode(map_entry: Dictionary, wanted: String) -> Dictionary:
	var modes := CatalogBridge.make_game_modes(map_entry)
	for m in modes:
		if str(m.id) == wanted:
			return m
	return modes[0]


## `s` with game mode `mode` ({id, team_based, min_teams, max_teams}): teams on or off, the team count clamped, limits reset.
static func _apply_game_mode(s: Dictionary, mode: Dictionary) -> Dictionary:
	s[LobbySettings.GAME_MODE_KEY] = str(mode.id)
	s["teams"] = bool(mode.get("team_based", false))
	var counts := CatalogBridge.make_team_range(mode, LobbySettings.make_map_config(s))
	s[LobbySettings.TEAM_COUNT_KEY] = clampi(int(s.get(LobbySettings.TEAM_COUNT_KEY, LobbySettings.DEFAULT_TEAM_COUNT)), counts.x, counts.y) if s.teams else LobbySettings.DEFAULT_TEAM_COUNT
	s[GameModes.SCORE_LIMIT_KEY] = 0
	s[GameModes.TIME_LIMIT_KEY] = 0
	return s

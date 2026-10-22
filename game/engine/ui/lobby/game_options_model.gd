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
## The groups of the one Game mode picker, in its order, and the id prefix of the vs and training choices.
const GROUP_VERSUS := "Versus"
const GROUP_COOP := "Co-op"
const GROUP_CAMPAIGN := "Campaign"
const GROUP_EXTRACTION := "Extraction"
const GROUP_TRAINING := "Training"
const VERSUS_PREFIX := "vs:"
const TRAINING_PREFIX := "training:"
const TRAINING_KIND := "training"
const COOP_LABEL := "Co-op vs AI"
const BATTLEDROME_MODES := ["duel"]

static var _maps_by_mode := {}
static var _maps_by_mode_key := 0


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


## The map entry index a new lobby of `mode` starts on (a raid prefers a big map among those that can host it; else the first).
static func make_default_map_index(mode: String) -> int:
	if mode != KIND_EXTRACTION:
		return 0
	var entries := MapPicker.make_entries()
	var raid_maps := make_maps_for_choice(KIND_EXTRACTION)
	for wanted in PREFERRED_RAID_MAPS:
		for i in raid_maps:
			if str(entries[i].name).begins_with(wanted):
				return i
	return raid_maps[0] if not raid_maps.is_empty() else 0


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


## Whatever the host picks in the single Game mode picker, by choice id (make_choice_id): every versus game mode of the
## installed games, co-op, the co-op campaign, the extraction raid, then the training pages. Each choice is
## {id, label, group, kind (KIND_* or TRAINING_KIND), game_mode (versus), pack (training), maps (entry indices of the
## maps it can be played on), enabled, reason ("" when enabled: why no map offers it)}.
static func make_mode_choices() -> Array:
	return make_choices_from(_make_maps_by_mode(), ExtractionRules.is_available())


## make_mode_choices for `maps` (game mode id -> the entry indices of the maps that offer it) and whether the raid's soldiers
## are installed: the pure part, so a lobby with some games missing can be checked.
static func make_choices_from(maps: Dictionary, soldiers_installed: bool) -> Array:
	var out := []
	for id in _make_versus_ids():
		var offered: Array = maps.get(id, [])
		out.append(_make_choice(VERSUS_PREFIX + id, GameModes.label_for(id), GROUP_VERSUS, KIND_VERSUS, offered, _make_versus_reason(id)))
		out.back()["game_mode"] = id
	out.append(_make_choice(KIND_COOP, COOP_LABEL, GROUP_COOP, KIND_COOP, maps.get("coop_ai", []), "needs an installed map"))
	out.append(_make_choice(KIND_CAMPAIGN, str(LobbySettings.MODE_TITLES[KIND_CAMPAIGN]), GROUP_CAMPAIGN, KIND_CAMPAIGN, [0], ""))
	out.back()["maps"] = []
	out.append(_make_choice(KIND_EXTRACTION, str(LobbySettings.MODE_TITLES[KIND_EXTRACTION]), GROUP_EXTRACTION, KIND_EXTRACTION,
		maps.get("extraction", []), "needs Tribes 2 installed" if not soldiers_installed else "needs a large map"))
	for pack in TribesMissionRuntime.PACKS:
		if not TribesMissionRuntime.list_missions(pack).is_empty():
			out.append(_make_choice(TRAINING_PREFIX + str(pack), "%s training..." % Packs.pack_name(pack), GROUP_TRAINING, TRAINING_KIND, [0], ""))
			out.back()["pack"] = str(pack)
			out.back()["maps"] = []
	return out


static func find_mode_choice(id: String) -> Dictionary:
	for c in make_mode_choices():
		if str(c.id) == id:
			return c
	return {}


## The picker's choice id of settings `s`: "vs:<game mode>" in versus, else the mode itself.
static func make_choice_id(s: Dictionary) -> String:
	var mode := str(s.get("mode", KIND_VERSUS))
	return VERSUS_PREFIX + GameModes.canonical(str(s.get(LobbySettings.GAME_MODE_KEY, GameModes.DEFAULT))) if mode == KIND_VERSUS else mode


## The name of settings `s`' game mode as the picker and a client's read-only row show it.
static func make_choice_label(s: Dictionary) -> String:
	var mode := str(s.get("mode", KIND_VERSUS))
	if mode == KIND_VERSUS:
		return LobbySettings.make_game_mode_label(s)
	return COOP_LABEL if mode == KIND_COOP else str(LobbySettings.MODE_TITLES.get(mode, mode))


## The entry indices of the maps choice `id` can be played on (every map for a mode the maps offer; [] for the campaign).
static func make_maps_for_choice(id: String) -> Array:
	return find_mode_choice(id).get("maps", [])


## The settings after the host picks choice `id`: the lobby's mode and game mode change, and the map moves to the first
## one that can host it when the current map cannot (the map is kept when it fits). A disabled choice changes nothing.
static func make_with_choice(s: Dictionary, id: String) -> Dictionary:
	var choice := find_mode_choice(id)
	if choice.is_empty() or not bool(choice.enabled) or str(choice.kind) == TRAINING_KIND:
		return s.duplicate(true)
	var kind := str(choice.kind)
	var out := s.duplicate(true) if str(s.get("mode", "")) == kind else make_with_mode(s, kind)
	if kind != KIND_CAMPAIGN:
		out = _make_fitted_map(out, choice)
	if kind == KIND_VERSUS:
		out = make_with_game_mode(out, str(choice.game_mode))
	return out


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


## `s` on a map `choice` can be played on: unchanged when its map fits, else the first fitting map (a raid: the preferred one).
static func _make_fitted_map(s: Dictionary, choice: Dictionary) -> Dictionary:
	var maps: Array = choice.maps
	if maps.is_empty() or maps.has(int(s.get("world_idx", -1))):
		return s
	var at := make_default_map_index(KIND_EXTRACTION) if str(choice.kind) == KIND_EXTRACTION else int(maps[0])
	return make_with_map(s, at if maps.has(at) else int(maps[0]))


static func _make_choice(id: String, label: String, group: String, kind: String, maps: Array, reason: String) -> Dictionary:
	var enabled := not maps.is_empty()
	return {"id": id, "label": label, "group": group, "kind": kind, "maps": maps, "enabled": enabled, "reason": "" if enabled else reason}


## Every versus game mode the registry knows, in its order (the co-op and extraction families are choices of their own).
static func _make_versus_ids() -> Array:
	var out := []
	for id in GameModes.data().get("order", []):
		if GameModes.is_known(str(id)) and not GameModes.family_of(str(id)) in GameModes.LEGACY_FAMILIES and not out.has(str(id)):
			out.append(str(id))
	for id in GameModes.data().get("modes", {}):
		if not GameModes.family_of(str(id)) in GameModes.LEGACY_FAMILIES and not out.has(str(id)):
			out.append(str(id))
	return out


static func _make_versus_reason(id: String) -> String:
	if id in BATTLEDROME_MODES:
		return "needs a Battledrome arena"
	return "needs an installed map" if id in GameModes.REMAKE_MODES else "needs a Tribes map"


## Game mode id -> the entry indices of the maps that offer it.
static func _make_maps_by_mode() -> Dictionary:
	var entries := MapPicker.make_entries()
	var key := hash(JSON.stringify(entries.map(func(e: Dictionary) -> String: return str(e.name))) + str(ExtractionRules.is_available()))
	if key == _maps_by_mode_key and not _maps_by_mode.is_empty():
		return _maps_by_mode
	var out := {}
	for i in entries.size():
		for id in GameModes.make_mode_ids_for_map(entries[i]):
			if not out.has(id):
				out[id] = []
			out[id].append(i)
	_maps_by_mode = out
	_maps_by_mode_key = key
	return out

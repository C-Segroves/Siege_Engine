class_name GameModes
extends RefCounted
## The game-mode registry (docs/formats/game_modes.md): which modes a map offers, their labels for the lobby, the
## battle config a mode needs and the rule values its rules run with. Data-driven: the remake's own definitions and
## default values are in game_modes.json; a pack's original values come from the user's disc
## (gamedata/<pack>/gameplay/game_modes.json, tools/export_game_modes.py) and a map's own ones from its map.json
## "mode_settings" (e.g. a Tribes mission's team score limit).
##
## Lobby API (D): make_modes_for_map(map_entry) -> [{id, label, team_based, min_teams, max_teams, description}],
## DEFAULT, CONFIG_KEY ("game_mode"), label_for(id), is_team_based(id), make_config_keys(id).
## A battle config with a CONFIG_KEY runs GameModeDirector (unless the mode is co-op or extraction, which keep
## their own rules).

const FILE := "res://engine/game_modes/game_modes.json"
const DEFAULT := "deathmatch"
const CONFIG_KEY := "game_mode"
## Battle config keys a lobby may set to override a mode's limits.
const SCORE_LIMIT_KEY := "score_limit"
const TIME_LIMIT_KEY := "time_limit_s"
## Families whose rules live elsewhere (BattleRules co-op end, ExtractionDirector).
const LEGACY_FAMILIES := ["coop_ai", "extraction"]
## The frag limit BattleRules sees while a mode decides the match itself (no kill limit of its own).
const NO_FRAG_LIMIT := 1 << 30
## Meta on a vehicle the mode respawns itself (BattleRules leaves it down).
const RESPAWNED_BY_MODE_META := "respawned_by_mode"
## Remake modes every map with enough starts offers.
const REMAKE_MODES := ["deathmatch", "team_deathmatch", "coop_ai"]
## Battledrome arenas: the original challenge plus the remake modes.
const ARENA_MODES := ["duel", "deathmatch", "team_deathmatch", "coop_ai"]
## Earthsiege worlds without a map file (MapPicker's legacy entries): large open ground.
const WORLD_MODES := ["deathmatch", "team_deathmatch", "coop_ai", "extraction"]
const START_SPAWN_KINDS := ["herc", "infantry", "vehicle_pad"]

static var _data := {}
static var _pack_rules := {}


## The whole registry (game_modes.json).
static func data() -> Dictionary:
	if _data.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(FILE))
		if not d is Dictionary:
			push_error("GameModes: cannot read %s" % FILE)
			d = {"modes": {}, "order": [], "aliases": {}}
		_data = d
	return _data


## The engine id of `id` (original short names such as "dm", "cnh" map to it).
static func canonical(id: String) -> String:
	var low := id.to_lower()
	return str(data().get("aliases", {}).get(low, low))


static func definition(id: String) -> Dictionary:
	return data().modes.get(canonical(id), {})


static func is_known(id: String) -> bool:
	return data().modes.has(canonical(id))


static func label_for(id: String) -> String:
	return str(definition(id).get("label", id.capitalize()))


static func is_team_based(id: String) -> bool:
	return bool(definition(id).get("team_based", false))


static func family_of(id: String) -> String:
	return str(definition(id).get("family", ""))


## The lobby entry of mode `id`.
static func make_entry(id: String, max_teams := -1) -> Dictionary:
	var d := definition(id)
	var top := int(d.get("max_teams", 0))
	if max_teams >= 0 and d.get("team_based", false):
		top = clampi(max_teams, int(d.get("min_teams", 0)), top)
	return {"id": canonical(id), "label": label_for(id), "team_based": bool(d.get("team_based", false)),
		"min_teams": int(d.get("min_teams", 0)), "max_teams": top, "description": str(d.get("description", ""))}


## The modes a map offers, DEFAULT first then registry order. `map_entry` is a maps/_index.json row (with or
## without "pack"), a MapBuilder.list_maps entry, a MapPicker entry ({name, config}) or a battle config.
static func make_modes_for_map(map_entry: Dictionary) -> Array:
	var ids := make_mode_ids_for_map(map_entry)
	var teams := _make_map_team_count(map_entry)
	var out := []
	for id in ids:
		out.append(make_entry(id, teams))
	return out


## Just the ids of make_modes_for_map.
static func make_mode_ids_for_map(map_entry: Dictionary) -> Array:
	var config: Dictionary = map_entry.get("config", map_entry)
	var found := {}
	if config.has("arena"):
		for id in ARENA_MODES:
			found[id] = true
	elif config.has("map") or map_entry.has("modes"):
		var row := _resolve_index_row(map_entry)
		for id in row.get("modes", []):
			if is_known(str(id)):
				found[canonical(str(id))] = true
		for id in make_remake_ids(row):
			found[id] = true
	else:
		for id in WORLD_MODES:
			found[id] = true
	return _make_ordered(found)


## Remake modes the map row allows: deathmatch and co-op everywhere (a map without starts of its own gets the
## battle's ring of starts, BattleSpawner), team deathmatch with enough starts, extraction on large maps.
static func make_remake_ids(row: Dictionary) -> Array:
	var out := ["deathmatch", "coop_ai"]
	var need: Dictionary = data().get("min_spawns", {})
	if make_start_count(row) >= int(need.get("team", 2)):
		out.append("team_deathmatch")
	if is_large_map(row) and ExtractionRules.is_available():
		out.append("extraction")
	return out


## Starts of every kind a combatant may begin at (index rows count them per kind; map files list them).
static func make_start_count(row: Dictionary) -> int:
	var spawns = row.get("spawns", {})
	if spawns is Array:
		return spawns.filter(func(s) -> bool: return str(s.get("kind", "herc")) in START_SPAWN_KINDS).size()
	var n := 0
	if spawns is Dictionary:
		for kind in START_SPAWN_KINDS:
			n += int(spawns.get(kind, 0))
	return n


## Extraction needs room for its zones and loot areas: both sides at least extraction_min_side_m.
static func is_large_map(row: Dictionary) -> bool:
	var size: Array = row.get("size_m", [0, 0])
	if size.size() < 2:
		return false
	return minf(float(size[0]), float(size[1])) >= float(data().get("extraction_min_side_m", 1000.0))


static func _make_ordered(found: Dictionary) -> Array:
	var out := []
	if found.has(DEFAULT):
		out.append(DEFAULT)
	for id in data().get("order", []):
		if found.has(id) and not out.has(id):
			out.append(id)
	for id in found:
		if not out.has(id):
			out.append(id)
	return out


## The maps/_index.json row behind `map_entry` (the entry itself when it already is one).
static func _resolve_index_row(map_entry: Dictionary) -> Dictionary:
	if map_entry.has("modes") and map_entry.has("spawns"):
		return map_entry
	var config: Dictionary = map_entry.get("config", map_entry)
	var map_id := str(config.get("map", map_entry.get("id", "")))
	for m in MapBuilder.list_maps():
		if str(m.id) == map_id:
			return m
	return MapBuilder.load_map(map_id) if map_id.contains(":") else {}


static func _make_map_team_count(map_entry: Dictionary) -> int:
	var config: Dictionary = map_entry.get("config", map_entry)
	if not (config.has("map") or map_entry.has("id")):
		return MapTeams.MAX_TEAMS
	var id := str(config.get("map", map_entry.get("id", "")))
	if not id.contains(":") and map_entry.has("pack"):
		id = "%s:%s" % [map_entry.pack, id]
	return MapTeams.make_team_count({"map": id})


# ------------------------------------------------------------------ battle config

## The config keys mode `id` needs (merged over the lobby's config): the mode id, the BattleRules mode
## ("vs" / "coop" / "extraction"), teams and respawning.
static func make_config_keys(id: String) -> Dictionary:
	var mode_id := canonical(id)
	var family := family_of(mode_id)
	if family == "extraction":
		return {CONFIG_KEY: mode_id, "mode": ExtractionRules.MODE, "respawn": false}
	if family == "coop_ai":
		return {CONFIG_KEY: mode_id, "mode": "coop", "teams": true}
	return {CONFIG_KEY: mode_id, "mode": "vs", "teams": is_team_based(mode_id), "respawn": true}


## True when the battle's mode is played by GameModeDirector.
static func uses_director(config: Dictionary) -> bool:
	var id := str(config.get(CONFIG_KEY, ""))
	return id != "" and is_known(id) and not (family_of(id) in LEGACY_FAMILIES)


## Battle start: the config keys the mode decides (mode, teams, respawn) and no BattleRules kill limit while a
## mode's own rules end the match.
static func apply_to_config(config: Dictionary) -> void:
	if not config.has(CONFIG_KEY) or str(config.get("mode", "")) == "mission":
		return
	var id := canonical(str(config[CONFIG_KEY]))
	if not is_known(id):
		push_error("GameModes: unknown game mode '%s', playing %s" % [id, DEFAULT])
		id = DEFAULT
	config.merge(make_config_keys(id), true)
	if uses_director(config):
		config["frag_limit"] = NO_FRAG_LIMIT


## True in a free-for-all (every pilot for himself): the mode's rule, else versus without teams.
static func is_free_for_all(config: Dictionary) -> bool:
	if config.has(CONFIG_KEY) and is_known(str(config[CONFIG_KEY])):
		var family := family_of(str(config[CONFIG_KEY]))
		return not is_team_based(str(config[CONFIG_KEY])) and not (family in LEGACY_FAMILIES)
	return str(config.get("mode", "")) == "vs" and not bool(config.get("teams", false))


## The objective announced when a match of the battle's mode starts: "Capture the Flag: <description>".
static func make_objective_text(config: Dictionary) -> String:
	var id := canonical(str(config.get(CONFIG_KEY, DEFAULT)))
	return "%s: %s" % [label_for(id), str(definition(id).get("description", ""))]


# ------------------------------------------------------------------ rules

## The rule values of mode `id` on map `m` (a loaded map.json, {} for none): the remake defaults, the pack's
## original values, the map's own, then the battle config's limit overrides.
static func make_rules_settings(id: String, m: Dictionary, config := {}) -> Dictionary:
	var mode_id := canonical(id)
	var out: Dictionary = definition(mode_id).get("rules", {}).duplicate(true)
	var pack := str(m.get("_pack", m.get("pack", "")))
	out.merge(_load_pack_rules(pack).get(mode_id, {}), true)
	out.merge(m.get("mode_settings", {}).get(mode_id, {}), true)
	for key in [SCORE_LIMIT_KEY, TIME_LIMIT_KEY]:
		if float(config.get(key, 0.0)) > 0.0:   # 0 / absent: the mode's own limit
			out[key] = float(config[key])
	return out


## The limits mode `id` plays with on map `m` unless the lobby overrides them: {score_limit, time_limit_s}
## (0 = none). A lobby shows these as its defaults for the chosen mode.
static func make_default_limits(id: String, m: Dictionary) -> Dictionary:
	var s := make_rules_settings(id, m)
	return {SCORE_LIMIT_KEY: float(s.get(SCORE_LIMIT_KEY, 0.0)), TIME_LIMIT_KEY: float(s.get(TIME_LIMIT_KEY, 0.0))}


static func _load_pack_rules(pack: String) -> Dictionary:
	if pack == "":
		return {}
	if not _pack_rules.has(pack):
		var j = Assets.load_json("gameplay/game_modes.json", pack) if Assets.has_pack(pack) else null
		_pack_rules[pack] = j if j is Dictionary else {}
	return _pack_rules[pack]


## A new rules object of mode `id`'s family (GameModeRules subclass).
static func make_rules(id: String, settings: Dictionary) -> GameModeRules:
	var mode_id := canonical(id)
	var rules: GameModeRules
	match family_of(mode_id):
		"ctf":
			rules = CtfRules.new()
		"capture_hold":
			rules = CaptureHoldRules.new()
		"defend_destroy":
			rules = DefendDestroyRules.new()
		"find_retrieve":
			rules = FindRetrieveRules.new()
		"hunters":
			rules = HuntersRules.new()
		"rabbit":
			rules = RabbitRules.new()
		"bounty":
			rules = BountyRules.new()
		"siege":
			rules = SiegeRules.new()
		"football":
			rules = FootballRules.new()
		"duel":
			rules = DuelRules.new()
		_:
			rules = DeathmatchRules.new()
	rules.configure(mode_id, is_team_based(mode_id), settings)
	return rules


## The map's mode objects mode `id` uses (map.json "mode_objects" listed for it or for every mode).
static func make_mode_objects(id: String, m: Dictionary) -> Array:
	var mode_id := canonical(id)
	return m.get("mode_objects", []).filter(func(o: Dictionary) -> bool:
		var modes: Array = o.get("modes", [])
		return modes.is_empty() or modes.has(mode_id))

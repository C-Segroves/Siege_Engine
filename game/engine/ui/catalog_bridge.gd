class_name CatalogBridge
## The front end's view of the catalogs other parts of the engine own: the infantry choices (InfantryCatalog),
## each map's versus game modes (GameModes), the map's teams (MapTeams) and the extraction factions' relation presets
## (ExtractionFactions). A catalog function is called when its class has it; otherwise a small fallback answers,
## so the screens work while a catalog is being extended. Every function returns plain data.

const FALLBACK_GAME_MODES := [
	{"id": "deathmatch", "label": "Deathmatch (every pilot and bot on their own side)", "team_based": false,
		"min_teams": 0, "max_teams": 0, "description": "Everyone against everyone."},
	{"id": "team_deathmatch", "label": "Team deathmatch", "team_based": true, "min_teams": 2, "max_teams": 4,
		"description": "Teams fight; the first team to the kill limit wins."},
]
const DEFAULT_GAME_MODE := "deathmatch"
const FALLBACK_TEAM_COUNT := 2
const MIN_TEAMS := 2
const MAX_TEAMS := 4
const FALLBACK_TEAM_COLORS := [Color("e04a3a"), Color("3a7be0"), Color("e0c23a"), Color("a64ae0")]
const FALLBACK_RELATION_PRESETS := [{"id": "story", "label": "Story"}, {"id": "all_hostile", "label": "All hostile"},
	{"id": "humans_allied", "label": "Humans allied"}]
const RELATIONS_CONFIG_KEY := "extraction_relations"
const ARMOR_SIZES := ["LIGHT", "MEDIUM", "HEAVY"]
const SIZE_LABELS := {"LIGHT": "Light armour", "MEDIUM": "Medium armour", "HEAVY": "Heavy armour"}
const DEFAULT_SKIN := {"id": "", "label": "Default"}

static var _scripts := {}


# ------------------------------------------------------------------ infantry (InfantryCatalog)

## Installed infantry games: [{pack, label}], Tribes first; empty = no infantry (vehicles only).
static func make_infantry_packs() -> Array:
	if has_function("InfantryCatalog", "make_infantry_packs"):
		return call_function("InfantryCatalog", "make_infantry_packs", [])
	var out := []
	for pack in InfantryCatalog.INFANTRY_PACKS:
		if InfantryCatalog.light_armor_id(pack) != "":
			out.append({"pack": pack, "label": Packs.pack_name(pack)})
	return out


## The armours of `pack`: [{id, label, size}], light first.
static func make_armors(pack: String) -> Array:
	if has_function("InfantryCatalog", "make_armors"):
		return call_function("InfantryCatalog", "make_armors", [pack])
	var out := []
	for size in ARMOR_SIZES:
		var id := "%s:%s" % [pack, size]
		if not InfantryCatalog.armor(id).is_empty():
			out.append({"id": id, "label": str(InfantryCatalog.armor(id).get("name", SIZE_LABELS[size])), "size": size.to_lower()})
	return out


## The bodies armour `armor_id` may be drawn with: [{id (shape id), label, bioderm}], the default first.
static func make_bodies(armor_id: String) -> Array:
	if has_function("InfantryCatalog", "make_bodies"):
		return call_function("InfantryCatalog", "make_bodies", [armor_id])
	var shape := str(InfantryCatalog.armor(armor_id).get("shape", ""))
	return [{"id": shape, "label": "Default", "bioderm": false}] if shape != "" else []


## The skins of body `body_id`: [{id, label}], {"", "Default"} first.
static func make_skins(body_id: String) -> Array:
	if has_function("InfantryCatalog", "make_skins"):
		return call_function("InfantryCatalog", "make_skins", [body_id])
	return SkinCatalog.make_skin_choices(body_id)


# ------------------------------------------------------------------ game modes and teams

## The game modes map entry `map_entry` (MapPicker entry {name, config}) offers; deathmatch first.
## The versus game modes of map entry `map_entry` (GameModes; the co-op and extraction families are the host
## screen's own Mode choices, so they are left out here).
static func make_game_modes(map_entry: Dictionary) -> Array:
	var modes := GameModes.make_modes_for_map(map_entry).filter(func(m: Dictionary) -> bool:
		return not GameModes.family_of(str(m.id)) in GameModes.LEGACY_FAMILIES)
	return modes if not modes.is_empty() else FALLBACK_GAME_MODES.duplicate(true)


## How many teams the map of `map_config` supports (2..4).
static func make_team_count(map_config: Dictionary) -> int:
	if has_function("MapTeams", "make_team_count"):
		return int(call_function("MapTeams", "make_team_count", [map_config]))
	return FALLBACK_TEAM_COUNT


static func make_team_color(i: int) -> Color:
	if has_function("MapTeams", "make_team_color"):
		return call_function("MapTeams", "make_team_color", [i])
	return FALLBACK_TEAM_COLORS[posmod(i, FALLBACK_TEAM_COLORS.size())]


static func make_team_name(i: int, map_config := {}) -> String:
	if has_function("MapTeams", "make_team_name"):
		return str(call_function("MapTeams", "make_team_name", [i, map_config]))
	return "Team %d" % (i + 1)


## The team counts the host may pick for game mode `mode` on the map of `map_config`: [min, max].
static func make_team_range(mode: Dictionary, map_config: Dictionary) -> Vector2i:
	var map_max := clampi(make_team_count(map_config), MIN_TEAMS, MAX_TEAMS)
	var lo := maxi(int(mode.get("min_teams", MIN_TEAMS)), MIN_TEAMS)
	var hi := mini(int(mode.get("max_teams", MAX_TEAMS)) if int(mode.get("max_teams", 0)) > 0 else MAX_TEAMS, map_max)
	return Vector2i(mini(lo, hi), maxi(hi, mini(lo, hi)))


# ------------------------------------------------------------------ extraction

## The extraction factions' relation presets: [{id, label}], the story first.
static func make_relation_presets() -> Array:
	if has_function("ExtractionFactions", "make_preset_list"):
		return call_function("ExtractionFactions", "make_preset_list", [])
	return FALLBACK_RELATION_PRESETS.duplicate(true)


# ------------------------------------------------------------------ class lookup

## True when global class `class_id` exists and has static function `function_name`.
static func has_function(class_id: String, function_name: String) -> bool:
	var s := _script_of(class_id)
	return s != null and s.has_method(function_name)


static func call_function(class_id: String, function_name: String, args: Array) -> Variant:
	return _script_of(class_id).callv(function_name, args)


static func _script_of(class_id: String) -> Script:
	if not _scripts.has(class_id):
		_scripts[class_id] = null
		for c in ProjectSettings.get_global_class_list():
			if str(c.class) == class_id:
				_scripts[class_id] = load(str(c.path))
	return _scripts[class_id]

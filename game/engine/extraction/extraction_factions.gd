class_name ExtractionFactions
extends RefCounted
## The extraction mode's AI factions (ExtractionRules "factions"; docs/design/extraction.md section 3): human
## factions of the series (Earthsiege-era UEN, Starsiege's Imperials and Knights / Rebels, the Tribes tribes), the
## Bioderms and the Cybrids. A faction fields what the user's packs provide: soldiers in a Tribes armour (the
## Bioderms in the Tribes 2 Bioderm bodies when those shapes are imported) and AI vehicles from its games.
## Each faction in a raid gets a team (faction_team_base + its index). Relations come from a preset of the rules'
## "relations" table, picked by the raid host (config CONFIG_KEY): per faction pair a stance (allied / neutral /
## hostile); human pairs not listed take the preset's "human_default"; the always-hostile kinds (Bioderms, Cybrids)
## and the players are hostile to everyone (TeamRelations; docs/design/extraction.md section 3).

const KIND_CYBRID := "cybrid"
const KIND_HUMAN := "human"
const CONFIG_KEY := "extraction_relations"
const DEFAULT_PRESET := "story"


## The factions that can field something with the installed packs, in rules order.
static func make_available() -> Array:
	return ExtractionRules.factions().filter(func(f: Dictionary) -> bool:
		return make_infantry_pack(f) != "" or not make_vehicle_pool(f).is_empty())


static func find(faction_id: String) -> Dictionary:
	for f in ExtractionRules.factions():
		if str(f.id) == faction_id:
			return f
	return {}


static func make_team(index: int) -> int:
	return int(ExtractionRules.data().get("faction_team_base", 300)) + index


## The armour pack the faction's soldiers wear ("" when it has no infantry here).
static func make_infantry_pack(faction: Dictionary) -> String:
	var infantry: Dictionary = faction.get("infantry", {}) if faction.get("infantry") is Dictionary else {}
	for pack in infantry.get("packs", []):
		if InfantryCatalog.light_armor_id(str(pack)) != "" and Packs.is_enabled(str(pack), "infantry") \
				and _has_body_shapes(infantry):
			return str(pack)
	return ""


## The faction's own body for armour `armor_id` ("" = the armour's shape): the Bioderms' bodies.
static func make_body_shape(faction: Dictionary, armor_id: String) -> String:
	var infantry: Dictionary = faction.get("infantry", {}) if faction.get("infantry") is Dictionary else {}
	return str((infantry.get("body_shapes", {}) as Dictionary).get(armor_id.get_slice(":", 1), ""))


static func _has_body_shapes(infantry: Dictionary) -> bool:
	for shape_id in (infantry.get("body_shapes", {}) as Dictionary).values():
		var parts := Assets.split_id(str(shape_id))
		if not FileAccess.file_exists(Assets.path("shapes/%s.json" % parts[1], parts[0])):
			return false
	return true


## Vehicle ids the faction's AI drives: pilotable walkers and tanks (no flyers or drones) of its packs and side,
## optionally only ids with one of its prefixes.
static func make_vehicle_pool(faction: Dictionary) -> Array:
	var rules: Dictionary = faction.get("vehicles", {}) if faction.get("vehicles") is Dictionary else {}
	var packs: Array = rules.get("packs", [])
	var prefixes: Array = rules.get("id_prefixes", [])
	var side := str(rules.get("side", ""))
	var out := []
	for v in Packs.pilotable(packs, side):
		if packs.is_empty() or bool(v.get("flyer", false)) or str(v.get("category", "herc")) != "herc":
			continue
		var key := str(v.id).get_slice(":", 1)
		if prefixes.is_empty() or prefixes.any(func(p) -> bool: return key.begins_with(str(p))):
			out.append(str(v.id))
	return out


## Squad sizes {infantry: [lo, hi], vehicles: [lo, hi]}: the faction's own, else the rules' default.
static func make_squad_rules(faction: Dictionary) -> Dictionary:
	var squad: Dictionary = (ExtractionRules.data().get("squad", {}) as Dictionary).duplicate()
	squad.merge(faction.get("squad", {}), true)
	return squad


## The relation presets a raid host can pick: [{id, label}, ...] in rules order.
static func make_preset_list() -> Array:
	return _relation_rules().get("presets", []).map(func(p: Dictionary) -> Dictionary:
		return {"id": str(p.id), "label": str(p.get("label", p.id))})


## The preset `preset_id` (the rules' default preset when unknown).
static func find_preset(preset_id: String) -> Dictionary:
	var fallback := {}
	for p in _relation_rules().get("presets", []):
		if str(p.id) == preset_id:
			return p
		if str(p.id) == str(_relation_rules().get("default_preset", DEFAULT_PRESET)):
			fallback = p
	if preset_id != "":
		push_error("ExtractionFactions: unknown relation preset '%s'" % preset_id)
	return fallback


## The preset id a raid of `config` uses.
static func make_preset_id(config: Dictionary) -> String:
	return str(config.get(CONFIG_KEY, _relation_rules().get("default_preset", DEFAULT_PRESET)))


## Stance between factions `a` and `b` under `preset` (TeamRelations.HOSTILE / NEUTRAL / ALLIED).
static func make_stance(preset: Dictionary, a: String, b: String) -> String:
	var always: Array = _relation_rules().get("always_hostile_kinds", [])
	if a == "" or b == "" or always.has(kind_of(a)) or always.has(kind_of(b)):
		return TeamRelations.HOSTILE
	if a == b:
		return TeamRelations.ALLIED
	for pair in preset.get("pairs", []):
		if (pair.a == a and pair.b == b) or (pair.a == b and pair.b == a):
			return str(pair.stance)
	if kind_of(a) == KIND_HUMAN and kind_of(b) == KIND_HUMAN:
		return str(preset.get("human_default", TeamRelations.HOSTILE))
	return TeamRelations.HOSTILE


## Sets TeamRelations for a raid: `teams` maps team -> faction id ("" = a player team, hostile to everyone).
static func apply_relations(teams: Dictionary, preset_id := DEFAULT_PRESET) -> void:
	TeamRelations.clear()
	var preset := find_preset(preset_id)
	for a in teams:
		for b in teams:
			if int(a) < int(b):
				TeamRelations.apply_stance(int(a), int(b), make_stance(preset, str(teams[a]), str(teams[b])))


static func kind_of(faction_id: String) -> String:
	return str(find(faction_id).get("kind", ""))


static func _relation_rules() -> Dictionary:
	return ExtractionRules.data().get("relations", {})

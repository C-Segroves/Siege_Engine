class_name PlayerProfile
## The local player's own choices, kept in user://settings.json (Assets.settings, key "player"): the name shown
## in the lobby, chat and nameplates; the infantry game played when both Tribes games are installed; the armour,
## body and skin the soldier starts in; a skin per Herc. Edited in Options and the lobby; the lobby announces
## them in the roster entry (make_roster_fields), the battle spawns from there.

const SETTINGS_KEY := "player"
const DEFAULT_NAME := "Pilot"
const MAX_NAME_LENGTH := 24
## Roster / config keys (BattleInfantry reads the infantry ones; BattleSpawner the Herc skin).
const ARMOR_KEY := "infantry_armor"
const BODY_KEY := "infantry_body"
const SKIN_KEY := "infantry_skin"
const HERC_SKIN_KEY := "herc_skin"
const PACK_KEY := "infantry_pack"
const HERC_SKINS_KEY := "herc_skins"


## The saved player name (DEFAULT_NAME when none was saved).
static func load_name() -> String:
	var n := make_clean_name(str(_data().get("name", "")))
	return n if n != "" else DEFAULT_NAME


## Saves `n` (cleaned) as the player name and uses it for the LAN session at once.
static func apply_name(n: String) -> void:
	var clean := make_clean_name(n)
	_store("name", clean)
	Net.player_name = clean if clean != "" else DEFAULT_NAME


static func make_clean_name(n: String) -> String:
	return n.strip_edges().replace("\n", " ").left(MAX_NAME_LENGTH)


## The infantry game the player prefers (an installed one; the first installed when unset; "" = none installed).
static func load_infantry_pack() -> String:
	var installed := CatalogBridge.make_infantry_packs().map(func(p: Dictionary) -> String: return str(p.pack))
	var wanted := str(_data().get(PACK_KEY, ""))
	if wanted in installed:
		return wanted
	return str(installed[0]) if not installed.is_empty() else ""


static func apply_infantry_pack(pack: String) -> void:
	_store(PACK_KEY, pack)


## The saved armour / body / skin ("" = default).
static func load_value(key: String) -> String:
	return str(_data().get(key, ""))


static func apply_value(key: String, value: String) -> void:
	_store(key, value)


## The skin the player chose for Herc `vehicle_id` ("" = default).
static func load_herc_skin(vehicle_id: String) -> String:
	return str((_data().get(HERC_SKINS_KEY, {}) as Dictionary).get(vehicle_id, ""))


static func apply_herc_skin(vehicle_id: String, skin_id: String) -> void:
	var skins: Dictionary = (_data().get(HERC_SKINS_KEY, {}) as Dictionary).duplicate()
	skins[vehicle_id] = skin_id
	_store(HERC_SKINS_KEY, skins)


## The player's armour in infantry game `pack`: the saved armour's size in that game, else light armour.
static func make_armor_for(pack: String) -> String:
	var armors := CatalogBridge.make_armors(pack)
	if armors.is_empty():
		return ""
	var saved := load_value(ARMOR_KEY)
	var size := saved.get_slice(":", 1).to_lower()
	for a in armors:
		if str(a.id) == saved or str(a.size).to_lower() == size:
			return str(a.id)
	return str(armors[0].id)


## The player's body for `armor_id`: the saved one when that armour offers it, else the default ("").
static func make_body_for(armor_id: String) -> String:
	var saved := load_value(BODY_KEY)
	for b in CatalogBridge.make_bodies(armor_id):
		if str(b.id) == saved:
			return saved
	return ""


## The player's skin for body `body_id` ("" = default) when that body offers it.
static func make_skin_for(body_id: String) -> String:
	var saved := load_value(SKIN_KEY)
	for s in CatalogBridge.make_skins(body_id):
		if str(s.id) == saved:
			return saved
	return ""


## The roster fields of the player's choices in a match whose soldiers come from infantry game `pack` and whose
## Herc is `vehicle_id`: {infantry_armor, infantry_body, infantry_skin, herc_skin} ("" = default).
static func make_roster_fields(pack: String, vehicle_id: String) -> Dictionary:
	var armor := make_armor_for(pack) if pack != "" else ""
	var body := make_body_for(armor)
	var shown_body := body if body != "" else make_default_body(armor)
	return {ARMOR_KEY: armor, BODY_KEY: body, SKIN_KEY: make_skin_for(shown_body), HERC_SKIN_KEY: load_herc_skin(vehicle_id)}


## The body armour `armor_id` is drawn with by default (its first body, else its own shape).
static func make_default_body(armor_id: String) -> String:
	var bodies := CatalogBridge.make_bodies(armor_id)
	return str(bodies[0].id) if not bodies.is_empty() else str(InfantryCatalog.armor(armor_id).get("shape", ""))


static func _data() -> Dictionary:
	var d = Assets.settings.get(SETTINGS_KEY, {})
	return d if d is Dictionary else {}


static func _store(key: String, value: Variant) -> void:
	var d := _data().duplicate()
	d[key] = value
	Assets.settings[SETTINGS_KEY] = d
	Assets.save_settings()

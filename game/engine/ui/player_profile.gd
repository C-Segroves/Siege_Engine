class_name PlayerProfile
## The local player's own choices, kept in user://settings.json (Assets.settings, key "player"): the name shown
## in the lobby, chat and nameplates; the infantry game played when both Tribes games are installed; the armour,
## body and skin the soldier started in; a skin per Herc. Since Operator Setup the active character slot
## (OperatorProfile) holds the build; these are the older settings, kept for the one-time migration into slot 1
## (ProfileMigration) and the roster keys.

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





## The saved armour / body / skin ("" = default).
static func load_value(key: String) -> String:
	return str(_data().get(key, ""))


static func apply_value(key: String, value: String) -> void:
	_store(key, value)


## The skin the player chose for Herc `vehicle_id` ("" = default).
static func load_herc_skin(vehicle_id: String) -> String:
	return str((_data().get(HERC_SKINS_KEY, {}) as Dictionary).get(vehicle_id, ""))









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

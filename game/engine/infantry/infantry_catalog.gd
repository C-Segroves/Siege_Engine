class_name InfantryCatalog
extends RefCounted
## The infantry armours of the installed packs (gamedata/<pack>/gameplay/armors.json, written by
## tools/export_tribes_infantry.py; docs/formats/tribes_infantry.md). Armours are kept out of the vehicle
## catalog (Packs.vehicles): they are never offered in vehicle pickers, hangars or campaigns.
##
## Armour id = "<pack>:<SIZE>", e.g. "tribes:LIGHT". Record fields (metres, seconds, Earthsiege damage):
##   name, size (light / medium / heavy), shape, height_m, eye_height_m, capsule_radius, hand_node,
##   max_forward_speed, max_backward_speed, max_side_speed, ground_accel, jump_speed, jet_accel,
##   jet_energy_per_s, min_jet_energy, jet_side_factor, max_jet_forward_speed, max_energy,
##   energy_recharge_per_s, hp, max_weapons, weapons [ids], ammo {weapon id: rounds}, default_loadout,
##   can_pilot, sounds {jet, footstep, mount, dismount}, bodies [{shape, label, bioderm}] (the armour's own body
##   first; female / Bioderm bodies share its values).
## The choices a match screen offers (make_infantry_packs, make_armors, make_bodies, make_skins) reach the spawn
## through the roster entry keys "infantry_armor", "infantry_body", "infantry_skin" (BattleInfantry).

const ARMORS_FILE := "gameplay/armors.json"

## Packs that have infantry, in preference order (the original Tribes first).
const INFANTRY_PACKS := ["tribes", "tribes2"]
const LIGHT := "LIGHT"
const SIZES := ["LIGHT", "MEDIUM", "HEAVY"]

static var _armors := {}      # id -> record
static var _loaded := false


## The installed (and enabled) infantry games, in preference order: [{pack, label}]; empty = no infantry.
static func make_infantry_packs() -> Array:
	var out := []
	for pack in INFANTRY_PACKS:
		if is_pack_usable(pack):
			out.append({"pack": pack, "label": Packs.pack_name(pack)})
	return out


## True when `pack` has armours and its infantry is not switched off in the library.
static func is_pack_usable(pack: String) -> bool:
	return light_armor_id(pack) != "" and Packs.is_enabled(pack, "infantry")


## The armours of `pack` for a picker: [{id, label, size}], light first.
static func make_armors(pack: String) -> Array:
	return armors_of(pack).map(func(a: Dictionary) -> Dictionary:
		return {"id": a.id, "label": str(a.get("name", a.id)), "size": str(a.get("size", ""))})


## The bodies armour `armor_id` can be worn with: [{id (shape id), label, bioderm}], its own body first.
static func make_bodies(armor_id: String) -> Array:
	var a := armor(armor_id)
	if a.is_empty():
		return []
	var bodies: Array = a.get("bodies", [])
	var out := []
	if bodies.is_empty():
		out.append({"id": str(a.get("shape", "")), "label": "Male", "bioderm": false})
	else:
		out = bodies.filter(func(b: Dictionary) -> bool: return is_shape_installed(str(b.shape))).map(
			func(b: Dictionary) -> Dictionary: return {"id": str(b.shape), "label": str(b.label), "bioderm": bool(b.bioderm)})
	out.append_array(make_aa_bodies(armor_id))
	out.append_array(make_tv_bodies(armor_id))
	return out


## Aerial Assault's soldier shapes per armour size (tools/aa_soldier.py: rigged and animated like the other armours' bodies;
## a pack imported before that holds rest-pose shapes, which are offered in menus only, see make_preview_bodies).
const AA_PACK := "tribes_aa"
const AA_BODIES := {
	"LIGHT": [["light_male", "Aerial Assault", false], ["light_female", "Aerial Assault Female", false], ["light_bioderm", "Aerial Assault Bioderm", true]],
	"MEDIUM": [["medium_male", "Aerial Assault", false], ["medium_female", "Aerial Assault Female", false], ["medium_bioderm", "Aerial Assault Bioderm", true]],
	"HEAVY": [["heavy_male", "Aerial Assault", false], ["heavy_bioderm", "Aerial Assault Bioderm", true]],
}
## The weapon mount node of an Aerial Assault soldier (the armour's hand node is found by name; this is the fallback).
const AA_HAND_NODE := "mount0"


## The Aerial Assault bodies armour `armor_id` can wear (same size; the stats come from the armour itself): [{id, label,
## bioderm, animated}]. Only animated (rigged) shapes: they play like any armour's body and may be spawned.
static func make_aa_bodies(armor_id: String) -> Array:
	var out := []
	for e in AA_BODIES.get(armor_id.get_slice(":", 1), []):
		var id := "%s:%s" % [AA_PACK, e[0]]
		if is_shape_installed(id) and is_shape_animated(id):
			out.append({"id": id, "label": e[1], "bioderm": e[2], "animated": true})
	return out


## Tribes: Vengeance bodies (tools/tv_skeletal.py, gameplay/bodies.json of the "tribes_v" pack): the three factions' soldiers of the
## armour's size, male and female, rigged and animated like the other bodies (the stats stay the armour's own).
const TV_PACK := "tribes_v"
static var _tv_bodies: Array = []
static var _tv_loaded := false


## [{id, label, bioderm, animated}] of the Vengeance bodies armour `armor_id` can wear (empty when the pack is not imported).
static func make_tv_bodies(armor_id: String) -> Array:
	_ensure_tv_loaded()
	var size := armor_id.get_slice(":", 1)
	var out := []
	for b in _tv_bodies:
		if str(b.size) != size or not bool(b.get("offer", false)):
			continue
		var id := "%s:%s" % [TV_PACK, b.id]
		if is_shape_installed(id) and is_shape_animated(id):
			out.append({"id": id, "label": "Vengeance %s%s" % [b.faction, " Female" if bool(b.female) else ""], "bioderm": false, "animated": true})
	return out


## Every Vengeance body record (offered or not: named characters, civilians), [] when the pack is not imported.
static func make_tv_all_bodies() -> Array:
	_ensure_tv_loaded()
	return _tv_bodies


static func _ensure_tv_loaded() -> void:
	if _tv_loaded:
		return
	_tv_loaded = true
	var j = Assets.load_json("gameplay/bodies.json", TV_PACK)
	if j is Dictionary:
		_tv_bodies = j.get("bodies", [])


## Aerial Assault bodies for menus and the hangar preview, animated or not (rest-pose shapes from an older import are
## not for battles). Empty when Tribes 2 is installed (it has its own soldiers) or AA is not.
static func make_preview_bodies(armor_id: String) -> Array:
	if Assets.installed_packs().has("tribes2"):
		return []
	var out := []
	for e in AA_BODIES.get(armor_id.get_slice(":", 1), []):
		var id := "%s:%s" % [AA_PACK, e[0]]
		if is_shape_installed(id):
			out.append({"id": id, "label": e[1], "bioderm": e[2], "animated": is_shape_animated(id)})
	return out


## True when shape `shape_id` has animation sequences.
static func is_shape_animated(shape_id: String) -> bool:
	return not (Assets.shape(shape_id).get("ds_sequences", []) as Array).is_empty()


## True when shape `shape_id` ("pack:name") was exported.
static func is_shape_installed(shape_id: String) -> bool:
	var parts := Assets.split_id(Assets.qualify(shape_id))
	return FileAccess.file_exists(Assets.path("shapes/%s.json" % parts[1], parts[0]))


## True when `body_id` is one of the bodies of armour `armor_id`.
static func has_body(armor_id: String, body_id: String) -> bool:
	return make_bodies(armor_id).any(func(b: Dictionary) -> bool: return b.id == body_id) or is_tv_character(body_id)


## True when `body_id` is a Tribes: Vengeance body (armour, civilian or named character): campaign soldiers wear them on any armour.
static func is_tv_character(body_id: String) -> bool:
	return body_id.begins_with(TV_PACK + ":") and is_shape_installed(body_id)


## The skins of body shape `body_id`: [{id, label}], Default ("") first (SkinCatalog, tools/export_skins.py).
static func make_skins(body_id: String) -> Array:
	return SkinCatalog.make_skin_choices(body_id)


## Armour record by id ({} when unknown).
static func armor(id: String) -> Dictionary:
	_ensure_loaded()
	return _armors.get(id, {})


## Every armour of `pack`, light first.
static func armors_of(pack: String) -> Array:
	_ensure_loaded()
	var out := []
	for size in SIZES:
		var a: Dictionary = _armors.get("%s:%s" % [pack, size], {})
		if not a.is_empty():
			out.append(a)
	return out


## The light armour of `pack` (the armour every soldier spawns in), "" when the pack has none.
static func light_armor_id(pack: String) -> String:
	var id := "%s:%s" % [pack, LIGHT]
	return id if not armor(id).is_empty() else ""


## The first installed pack with infantry ("" when none is installed): with only one of Tribes / Tribes 2
## installed, that one.
static func make_default_pack() -> String:
	_ensure_loaded()
	for pack in INFANTRY_PACKS:
		if is_pack_usable(pack):
			return pack
	return ""


## True when weapon `weapon_id` may be carried in armour `armor_id` (Tribes $ItemMax / max[]). A weapon of the other
## Tribes game follows the rule of that game's armour of the same size (a Tribes 2 Spinfusor in Tribes 1 light armour
## is allowed because Tribes 2 light armour carries it; a mortar is not, in either game's light armour).
static func allows_weapon(armor_id: String, weapon_id: String) -> bool:
	return (make_rules_armor(armor_id, weapon_id).get("weapons", []) as Array).has(weapon_id)


## Rounds of `weapon_id` armour `armor_id` carries (Tribes max[]), by the same same-size rule; 0 when none.
static func make_ammo_capacity(armor_id: String, weapon_id: String) -> int:
	return int((make_rules_armor(armor_id, weapon_id).get("ammo", {}) as Dictionary).get(weapon_id, 0))


## The armour whose limits apply to `weapon_id` worn as `armor_id`: the armour itself for its own game's weapons,
## else the weapon's game's armour of the same size ({} when that game has none).
static func make_rules_armor(armor_id: String, weapon_id: String) -> Dictionary:
	var a := armor(armor_id)
	var weapon_pack := weapon_id.get_slice(":", 0)
	if a.is_empty() or weapon_pack == str(a.get("pack", "")) or not INFANTRY_PACKS.has(weapon_pack):
		return a
	return armor("%s:%s" % [weapon_pack, armor_id.get_slice(":", 1)])


## Drops the cache (tests, pack reloads).
static func reload() -> void:
	_armors.clear()
	_loaded = false
	_tv_bodies = []
	_tv_loaded = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	for pack in Assets.installed_packs():
		var j = Assets.load_json(ARMORS_FILE, pack)
		if not (j is Dictionary):
			continue
		var armors: Dictionary = j.get("armors", {})
		for key in armors:
			var a: Dictionary = armors[key]
			a["id"] = "%s:%s" % [pack, key]
			a["pack"] = pack
			a["category"] = "infantry"
			_armors[a.id] = a


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
	if bodies.is_empty():
		return [{"id": str(a.get("shape", "")), "label": "Male", "bioderm": false}]
	return bodies.filter(func(b: Dictionary) -> bool: return is_shape_installed(str(b.shape))).map(
		func(b: Dictionary) -> Dictionary: return {"id": str(b.shape), "label": str(b.label), "bioderm": bool(b.bioderm)})


## True when shape `shape_id` ("pack:name") was exported.
static func is_shape_installed(shape_id: String) -> bool:
	var parts := Assets.split_id(Assets.qualify(shape_id))
	return FileAccess.file_exists(Assets.path("shapes/%s.json" % parts[1], parts[0]))


## True when `body_id` is one of the bodies of armour `armor_id`.
static func has_body(armor_id: String, body_id: String) -> bool:
	return make_bodies(armor_id).any(func(b: Dictionary) -> bool: return b.id == body_id)


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


## True when weapon `weapon_id` may be carried in armour `armor_id` (Tribes $ItemMax / max[]).
static func allows_weapon(armor_id: String, weapon_id: String) -> bool:
	return (armor(armor_id).get("weapons", []) as Array).has(weapon_id)


## Drops the cache (tests, pack reloads).
static func reload() -> void:
	_armors.clear()
	_loaded = false


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


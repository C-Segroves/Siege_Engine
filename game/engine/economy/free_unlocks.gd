class_name FreeUnlocks
extends RefCounted
## What every operator owns from the start (docs/design/lobby_loadout_economy.md C6, rules "free_unlocks"): the basic
## Tribes 1 armours, the default body and the skins of the free skin packs, the weapons the free armours spawn with
## and their ammunition, the free weapons and gear, and one starter vehicle per installed pack (its lowest-rated
## pilotable vehicle) with the vehicle's standard weapons. Nothing here is stored in a profile; a pack that is not
## installed has no free items.

const O2_FREE_MODE := "free_outside_extraction"

static var _starters := {}
static var _key := ""


static func is_free(id: String) -> bool:
	var ref := UnlockId.ref_of(id)
	match UnlockId.kind_of(id):
		"armor":
			return _rule_list("armor").has(ref) and not InfantryCatalog.armor(ref).is_empty()
		"body":
			return _is_default_body(ref)
		"skin":
			return (_rule_list("skin_packs") as Array).has(UnlockId.pack_of(id)) and Assets.has_pack(UnlockId.pack_of(id))
		"weapon":
			return _rule_list("weapons").has(ref) or _is_spawn_weapon(ref)
		"ammo":
			return is_free(UnlockId.make("weapon", ref))
		"gear":
			return _rule_list("gear").has(ref)
		"vehicle":
			return make_starter_vehicles().values().has(ref)
		"herc_weapon":
			return bool(EconomyRules.free_unlocks().get("vehicle_default_loadout", false)) and _is_starter_weapon(ref)
	return false


## True for an armour that is free in matches but bought in a raid (user answer O5: only light armour is free there). Such an
## unlock is stored when bought and can be lost on death.
static func is_raid_paid(id: String) -> bool:
	return UnlockId.kind_of(id) == "armor" and is_free(id) and not (EconomyRules.option("o5_extraction_free_armors") as Array).has(UnlockId.ref_of(id))


## Free in every mode: nothing to buy, nothing to lose.
static func is_free_everywhere(id: String) -> bool:
	return is_free(id) and not is_raid_paid(id)


## Outside extraction (user answer O2): every weapon, ammunition type, gear item and backpack of an installed game is
## free as well; credits buy armours, bodies, skins and vehicles. The kinds are data (free_unlocks.free_outside_extraction).
static func is_free_outside_raid(id: String) -> bool:
	if is_free(id):
		return true
	var pack_id := UnlockId.pack_of(id)
	return is_stock_kind(UnlockId.kind_of(id)) and (pack_id == "" or Assets.has_pack(pack_id))


## True for a kind that is free outside extraction and only ever stock inside it (never bought as an unlock).
static func is_stock_kind(kind: String) -> bool:
	return str(EconomyRules.option("o2_ammo_mode")) == O2_FREE_MODE and _rule_list("free_outside_extraction").has(kind)


## The same, inside a raid: only the armours the rules let a raider wear for free (open question O5).
static func is_free_in_raid(id: String) -> bool:
	if UnlockId.kind_of(id) == "armor":
		return (EconomyRules.option("o5_extraction_free_armors") as Array).has(UnlockId.ref_of(id)) and is_free(id)
	return is_free(id)


## {pack: vehicle id}: the starter vehicle of every installed pack that has a pilotable vehicle (open question O3 may
## limit it to some packs).
static func make_starter_vehicles() -> Dictionary:
	var key := "%d|%s" % [Packs.vehicles.size(), str(Packs.packs.keys())]
	if key != _key:
		_key = key
		_starters = _build_starters()
	return _starters


## The starter vehicle new slots use: the first pack on the timeline that has one ("" when no pilotable vehicle).
static func make_default_vehicle() -> String:
	var starters := make_starter_vehicles()
	var packs := starters.keys()
	packs.sort_custom(func(a: String, b: String) -> bool:
		return Packs.era(a) < Packs.era(b) or (Packs.era(a) == Packs.era(b) and a < b))
	return str(starters[packs[0]]) if not packs.is_empty() else ""


## Drops the cached starters (tests, pack reloads).
static func reload() -> void:
	_starters = {}
	_key = ""


static func _build_starters() -> Dictionary:
	var out := {}
	if not bool(EconomyRules.free_unlocks().get("starter_vehicle_per_pack", false)):
		return out
	var only: Array = EconomyRules.option("o3_starter_vehicle_packs") if EconomyRules.option("o3_starter_vehicle_packs") is Array else []
	var by_pack := {}
	for v in Packs.pilotable():
		var pack := str(v.pack)
		if only.is_empty() or only.has(pack):
			if not by_pack.has(pack):
				by_pack[pack] = []
			by_pack[pack].append(v)
	for pack in by_pack:
		out[pack] = str(_pick_lowest_rated(by_pack[pack]).id)
	return out


static func _pick_lowest_rated(vehicles: Array) -> Dictionary:
	var best: Dictionary = vehicles[0]
	for v in vehicles:
		var a := Packs.combat_rating(v)
		var b := Packs.combat_rating(best)
		if a < b or (is_equal_approx(a, b) and str(v.id) < str(best.id)):
			best = v
	return best


static func _rule_list(key: String) -> Array:
	var v = EconomyRules.free_unlocks().get(key, [])
	return v if v is Array else []


static func _free_armors() -> Array:
	return _rule_list("armor").filter(func(a: String) -> bool: return not InfantryCatalog.armor(a).is_empty())


static func _is_default_body(shape: String) -> bool:
	if not bool(EconomyRules.free_unlocks().get("default_skin_and_body", false)):
		return false
	return _free_armors().any(func(a: String) -> bool: return PlayerProfile.make_default_body(a) == shape)


static func _is_spawn_weapon(weapon_id: String) -> bool:
	if not bool(EconomyRules.free_unlocks().get("default_loadout_weapons", false)):
		return false
	return _free_armors().any(func(a: String) -> bool: return (InfantryCatalog.armor(a).get("default_loadout", []) as Array).has(weapon_id))


static func _is_starter_weapon(weapon_id: String) -> bool:
	for vid in make_starter_vehicles().values():
		if (Packs.default_loadout(Packs.vehicle(str(vid))) as Array).has(weapon_id):
			return true
	return false

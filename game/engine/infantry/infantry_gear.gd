class_name InfantryGear
extends RefCounted
## The Tribes games' infantry gear and vehicle seats (gamedata/<pack>/gameplay/infantry_gear.json and
## vehicle_seats.json, written by tools/export_tribes_gear.py; docs/formats/tribes_infantry.md section 6).
##
## Hand items, id "<pack>:<KEY>" (tribes:GRENADE, tribes2:MINE ...):
##   kind grenade | concussion (a fuse) or mine (proximity, armed once at rest), damage (ES points), radius,
##   damage_type, mass, elasticity, friction, fuse_s, proximity, arm_s, kick (impulse), throw_speed (T1);
##   kind repair_kit: repair (ES points), repair_s (seconds it takes to heal: T1 repairDamage is instant = 0, T2 applyRepair
##   heals repairRate per tick); "mapped": false = recorded only (beacons, flares, cameras).
## Packs: effect energy (recharge_bonus_per_s) | repair (repair_per_s, energy_per_s) | shield
##   (energy_per_damage, energy_per_s, weak_types) | jammer (jam_radius, energy_per_s) | ammo (extra_rounds)
##   | cloak (cloak_profile: a CloakProfile id, engine/stealth) | unmapped (satchel); "toggled": pack_use turns it on and off.
## Every pack record also names its use_sound (heard when it is switched on); "sounds" of the file: kit (a repair kit
## used), pack_fail (a refused use), pack_use (a pack with no sound of its own).
## Throw rules per pack ("throw"): T1 GameBase::throw strength, T2 HandInventory::onUse impulse.
## Seats per vehicle id: [{seat, role (pilot / gunner / armed / passenger), node (seat node in the shape)}].

const GEAR_FILE := "gameplay/infantry_gear.json"
const SEATS_FILE := "gameplay/vehicle_seats.json"
const KIND_REPAIR_KIT := "repair_kit"
const KIND_MINE := "mine"
const THROWN_KINDS := ["grenade", "concussion", "mine"]

static var _items := {}       # id -> record
static var _packs := {}       # id -> record
static var _throw := {}       # pack -> throw rules
static var _sounds := {}      # pack -> {kit, pack_fail, pack_use}
static var _seats := {}       # vehicle id -> [seat records]
static var _loaded := false


static func item(id: String) -> Dictionary:
	_ensure_loaded()
	return _items.get(id, {})


static func pack(id: String) -> Dictionary:
	_ensure_loaded()
	return _packs.get(id, {})


## The thrown items (grenades, mines) `armor` may carry.
static func thrown_items_of(armor: Dictionary) -> Array:
	return (armor.get("hand_items", {}) as Dictionary).keys().filter(func(id: String) -> bool:
		return is_thrown(item(id)))


## The grenades (not mines) `armor` may carry: the inventory's grenade choice.
static func grenades_of(armor: Dictionary) -> Array:
	return thrown_items_of(armor).filter(func(id: String) -> bool: return item(id).kind != KIND_MINE)


## The packs `armor` may wear whose effect the remake models.
static func packs_of(armor: Dictionary) -> Array:
	return (armor.get("packs", []) as Array).filter(func(id: String) -> bool: return bool(pack(id).get("mapped", false)))


## Every hand item record of the installed packs (id order).
static func all_items() -> Array:
	_ensure_loaded()
	return _sorted_values(_items)


## Every backpack record of the installed packs (id order).
static func all_packs() -> Array:
	_ensure_loaded()
	return _sorted_values(_packs)


static func _sorted_values(table: Dictionary) -> Array:
	var ids := table.keys()
	ids.sort()
	return ids.map(func(id: String) -> Dictionary: return table[id])


static func is_thrown(record: Dictionary) -> bool:
	return bool(record.get("mapped", false)) and str(record.get("kind", "")) in THROWN_KINDS


## The Sfx stem of use sound `key` (kit, pack_fail, pack_use) of game `pack_name` ("" when none is installed).
static func sound(pack_name: String, key: String) -> String:
	_ensure_loaded()
	return str((_sounds.get(pack_name, {}) as Dictionary).get(key, ""))


static func throw_rules(pack_name: String) -> Dictionary:
	_ensure_loaded()
	return _throw.get(pack_name, {})


## Seat records of `vehicle_id` ([] for vehicles without seat data: one pilot seat).
static func seats_of(vehicle_id: String) -> Array:
	_ensure_loaded()
	return _seats.get(vehicle_id, [])


static func reload() -> void:
	_items.clear()
	_packs.clear()
	_throw.clear()
	_sounds.clear()
	_seats.clear()
	_loaded = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	for pack_name in Assets.installed_packs():
		var gear = Assets.load_json(GEAR_FILE, pack_name)
		if gear is Dictionary:
			_index(gear.get("items", []), _items)
			_index(gear.get("packs", []), _packs)
			_throw[pack_name] = gear.get("throw", {})
			_sounds[pack_name] = gear.get("sounds", {})
		var seats = Assets.load_json(SEATS_FILE, pack_name)
		if seats is Dictionary:
			_seats.merge(seats.get("vehicles", {}), true)


static func _index(records: Array, into: Dictionary) -> void:
	for r in records:
		into[str(r.id)] = r

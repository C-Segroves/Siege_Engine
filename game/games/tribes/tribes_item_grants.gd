class_name TribesItemGrants
extends RefCounted
## What picking up a Tribes / Tribes 2 item gives a soldier (TribesPickups; the originals' ItemData::onCollision ->
## Player::pickup): a weapon his armour allows into a free slot, rounds for a weapon he carries, hand items
## (grenades, mines, repair kits) up to the armour's limit, a backpack when he wears none, a repair patch's health
## when hurt. An item that would give nothing stays on the ground (Player::pickup returns false). An explicit
## pickup (`interact`) also swaps: the weapon in hand for the item's weapon when every slot is full, the worn pack
## for the item's pack (remake addition: the originals drop by a separate key).
## Item names resolve as in the mission runtime (TribesItems over missions/datablocks.json).

## Item catalog of the pack (tools/export_tribes_items.py).
const ITEMS_FILE := "gameplay/items.json"
const DATABLOCKS_FILE := "missions/datablocks.json"
const REPAIR_CLASS := "repair"
const REPAIR_PATCH := "repairpatch"

var pack := ""
var catalog := {}            # datablock -> {name, class, shape, radius, amount}
var _names: TribesItems


func _init(p_pack: String) -> void:
	pack = p_pack
	var j = Assets.load_json(ITEMS_FILE, pack)
	catalog = j.get("items", {}) if j is Dictionary else {}
	var dbs = Assets.load_json(DATABLOCKS_FILE, pack)
	_names = TribesItems.new(pack, dbs if dbs is Dictionary else {})


## The catalog record of item `datablock` ({} when unknown).
func record(datablock: String) -> Dictionary:
	return catalog.get(datablock.to_lower(), {})


## True when item `datablock` can give a soldier something (a weapon, rounds, gear, a pack, health): the items the
## remake models (a Hunters nexus, a satchel charge ... are left out).
func is_pickup(datablock: String) -> bool:
	var db := datablock.to_lower()
	if db == REPAIR_PATCH or str(record(db).get("class", "")).to_lower() == REPAIR_CLASS:
		return true
	if _names.weapon_of(db) != "" or _names.ammo_weapon_of(db) != "":
		return true
	var gid := _names.gear_of(db)
	var gear := InfantryGear.pack(gid) if not InfantryGear.pack(gid).is_empty() else InfantryGear.item(gid)
	return gid != "" and bool(gear.get("mapped", true))


## True when `soldier` would take item `datablock` (`swap`: an explicit pickup that may replace a weapon / pack).
func can_take(soldier: Infantry, datablock: String, swap: bool) -> bool:
	return _make_take(soldier, datablock, 1, swap) != ""


## Gives `soldier` what item `datablock` holds (`count` placed units); false when he takes nothing.
func apply_take(soldier: Infantry, datablock: String, count: int, swap: bool) -> bool:
	match _make_take(soldier, datablock, count, swap):
		"weapon":
			_apply_weapon(soldier, _names.weapon_of(datablock))
		"ammo":
			_apply_ammo(soldier, datablock, count)
		"gear":
			_apply_gear(soldier, _names.gear_of(datablock), count)
		"pack":
			soldier.kit.pack_id = _names.gear_of(datablock)
			soldier.kit.pack_active = false
		"repair":
			InfantryPack.apply_repair(soldier, float(soldier.components[0].max) * make_repair_share())
		_:
			return false
	return true


## The share of full health a repair patch restores (T1 RepairPatch / T2 RepairPatch, as the mission runtimes).
func make_repair_share() -> float:
	return Tribes2Methods.REPAIR_PATCH_SHARE if pack == "tribes2" else Tribes1MissionRuntime.REPAIR_PATCH_SHARE


## What a take would do: "weapon", "ammo", "gear", "pack", "repair" or "" (nothing).
func _make_take(soldier: Infantry, datablock: String, count: int, swap: bool) -> String:
	var db := datablock.to_lower()
	if soldier == null or not soldier.alive or soldier.stowed:
		return ""
	if db == REPAIR_PATCH or str(record(db).get("class", "")).to_lower() == REPAIR_CLASS:
		return "repair" if soldier.integrity < 1.0 else ""
	var wid := _names.weapon_of(db)
	if wid != "":
		return "weapon" if _may_take_weapon(soldier, wid, swap) else ""
	var ammo_of := _names.ammo_weapon_of(db)
	if ammo_of != "":
		return "ammo" if _missing_rounds(soldier, ammo_of) > 0 else ""
	var gid := _names.gear_of(db)
	if gid == "":
		return ""
	if not InfantryGear.pack(gid).is_empty():
		return "pack" if soldier.kit.pack_id == "" or (swap and soldier.kit.pack_id != gid) else ""
	return "gear" if soldier.kit.count(gid) < soldier.kit.make_max_count(soldier.armor, gid) and count > 0 else ""


func _may_take_weapon(soldier: Infantry, wid: String, swap: bool) -> bool:
	if soldier.make_loadout().has(wid) or not InfantryCatalog.allows_weapon(soldier.armor_id, wid):
		return false
	return soldier.weapons.size() < int(soldier.armor.get("max_weapons", 3)) or swap


## Adds weapon `wid` (in hand, as Weapon::onPickup uses it when nothing is in hand; the remake always does so the
## player sees what he took), replacing the weapon in hand when every slot is full.
func _apply_weapon(soldier: Infantry, wid: String) -> void:
	var loadout := soldier.make_loadout()
	var slot := loadout.size()
	if slot >= int(soldier.armor.get("max_weapons", 3)):
		slot = soldier.weapon_slot
		loadout[slot] = wid
	else:
		loadout.append(wid)
	var rounds := {}
	for w in soldier.weapons:
		rounds[w.weapon_id] = w.ammo
	soldier.equip(loadout)
	for w in soldier.weapons:
		if rounds.has(w.weapon_id):
			w.ammo = int(rounds[w.weapon_id])
	soldier.apply_weapon_slot(slot)


func _apply_ammo(soldier: Infantry, datablock: String, count: int) -> void:
	var wid := _names.ammo_weapon_of(datablock)
	var rounds := int(record(datablock).get("amount", 1)) * maxi(count, 1)
	for w in soldier.weapons:
		if w.weapon_id == wid and w is InfantryWeapon:
			(w as InfantryWeapon).apply_resupply(rounds)


func _apply_gear(soldier: Infantry, gid: String, count: int) -> void:
	var most := soldier.kit.make_max_count(soldier.armor, gid)
	soldier.kit.counts[gid] = mini(soldier.kit.count(gid) + maxi(count, 1), most)
	if InfantryGear.item(gid).get("kind", "") == TribesItems.GRENADE_KIND and soldier.kit.grenade_id == "":
		soldier.kit.grenade_id = gid


static func _missing_rounds(soldier: Infantry, wid: String) -> int:
	for w in soldier.weapons:
		if w.weapon_id == wid and w is InfantryWeapon:
			return (w as InfantryWeapon).missing_rounds()
	return 0

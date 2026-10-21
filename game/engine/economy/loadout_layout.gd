class_name LoadoutLayout
extends RefCounted
## The rows of the Operator Setup list and the rules for filling them (docs/design/lobby_loadout_economy.md section
## 2.6): which weapon, ammunition, gear, backpack and hardpoint rows an armour or a vehicle has, how full they are,
## and whether a part fits a row. Pure data: the screen only draws it.
## A row: {key, kind, label, accepts, current, ammo, ammo_max, locked}; keys are "armour", "weapon:<i>", "ammo:<weapon>",
## "gear:<item>", "pack", "skin", "hardpoint:<i>", "herc_skin".

const SIDE_INFANTRY := "infantry"
const SIDE_VEHICLE := "vehicle"
const KG_PRECISION := 0.01
## The store filter key for "any hardpoint of the vehicle" (no hardpoint row selected).
const ROW_ANY_HARDPOINT := "hardpoint"


static func make_rows(side: String, slot: CharacterSlot, ctx: LoadoutContext) -> Array:
	return _make_infantry_rows(slot) if side == SIDE_INFANTRY else _make_vehicle_rows(slot, ctx)


## {slots, slots_max, kg, kg_max, ok}: weapons carried against the armour's weapon limit and the carried weight against
## the armour's capacity (the extraction capacity table); a vehicle counts its filled hardpoints.
static func make_fit(side: String, slot: CharacterSlot) -> Dictionary:
	if side == SIDE_VEHICLE:
		return _make_vehicle_fit(slot)
	var armor := InfantryCatalog.armor(slot.armor)
	var slots_max := int(armor.get("max_weapons", 0))
	var kg_max := float(ExtractionRules.capacity(str(armor.get("size", "light"))).get("kg", 0.0))
	var slots := (slot.infantry.weapons as Array).size()
	var kg := _make_infantry_kg(slot)
	return {"slots": slots, "slots_max": slots_max, "kg": kg, "kg_max": kg_max, "ok": slots <= slots_max and kg <= kg_max + KG_PRECISION}


## Puts `id` in row `row_key`; false (nothing changed) when it does not fit. "" clears the row.
static func apply_set(slot: CharacterSlot, row_key: String, id: String) -> bool:
	if id == "":
		apply_clear(slot, row_key)
		return true
	var kind := row_key.get_slice(":", 0)
	var arg := row_key.substr(row_key.find(":") + 1) if row_key.contains(":") else ""
	match kind:
		"armour":
			return _apply_armor(slot, id)
		"weapon":
			return _apply_weapon(slot, int(arg), id)
		"gear":
			return _apply_gear(slot, arg)
		"pack":
			return _apply_pack(slot, id)
		"skin":
			return _apply_skin(slot, id)
		"hardpoint":
			return _apply_hardpoint(slot, int(arg), id)
		"herc_skin":
			return _apply_herc_skin(slot, id)
		"vehicle":
			return _apply_vehicle(slot, id)
	return false


## Sets the rounds of weapon `weapon_id` (0..the armour's capacity); false when the weapon is not carried.
static func apply_set_ammo(slot: CharacterSlot, weapon_id: String, rounds: int) -> bool:
	var capacity := InfantryCatalog.make_ammo_capacity(slot.armor, weapon_id)
	if not (slot.infantry.weapons as Array).has(weapon_id) or capacity <= 0:
		return false
	slot.infantry.ammo[weapon_id] = clampi(rounds, 0, capacity)
	return true


## Empties row `row_key` (the armour and the vehicle rows cannot be emptied).
static func apply_clear(slot: CharacterSlot, row_key: String) -> void:
	var kind := row_key.get_slice(":", 0)
	var arg := row_key.substr(row_key.find(":") + 1) if row_key.contains(":") else ""
	match kind:
		"weapon":
			var weapons: Array = slot.infantry.weapons
			if int(arg) >= 0 and int(arg) < weapons.size():
				(slot.infantry.ammo as Dictionary).erase(str(weapons[int(arg)]))
				weapons.remove_at(int(arg))
		"gear":
			(slot.infantry.gear as Dictionary).erase(arg)
		"pack":
			slot.infantry.pack = ""
		"skin":
			slot.skin = ""
		"hardpoint":
			if int(arg) >= 0 and int(arg) < slot.herc_loadout.size():
				slot.herc_loadout[int(arg)] = ""
		"herc_skin":
			slot.herc_skin = ""


## True when `id` could be put in `row_key` of a copy of `slot` (the store's "fits slot" filter).
static func is_fit(slot: CharacterSlot, row_key: String, id: String) -> bool:
	if row_key == ROW_ANY_HARDPOINT:
		return _is_fit_any_hardpoint(slot, id)
	return apply_set(slot.make_copy(), row_key, id)


static func _is_fit_any_hardpoint(slot: CharacterSlot, id: String) -> bool:
	var count := WeaponFit.hardpoint_masks(Packs.vehicle(slot.vehicle)).size()
	for i in count:
		if apply_set(slot.make_copy(), "hardpoint:%d" % i, id):
			return true
	return false


# ------------------------------------------------------------------ rows

static func _make_row(key: String, kind: String, label: String, accepts: Variant, current: String) -> Dictionary:
	return {"key": key, "kind": kind, "label": label, "accepts": accepts, "current": current, "ammo": 0, "ammo_max": 0, "locked": false}


static func _make_infantry_rows(slot: CharacterSlot) -> Array:
	var armor := InfantryCatalog.armor(slot.armor)
	if armor.is_empty():
		return []
	var rows := []
	var fixed := _make_row("armour", "armour", str(armor.get("name", slot.armor)), "armour", slot.armor)
	fixed.locked = true
	rows.append(fixed)
	var weapons: Array = slot.infantry.weapons
	for i in int(armor.get("max_weapons", 0)):
		var current := str(weapons[i]) if i < weapons.size() else ""
		rows.append(_make_row("weapon:%d" % i, "weapon", "Weapon %d" % (i + 1), "weapon", current))
		if current != "" and InfantryCatalog.make_ammo_capacity(slot.armor, current) > 0:
			var ammo := _make_row("ammo:%s" % current, "ammo", "Ammo", "ammo", current)
			ammo.ammo = int((slot.infantry.ammo as Dictionary).get(current, 0))
			ammo.ammo_max = InfantryCatalog.make_ammo_capacity(slot.armor, current)
			rows.append(ammo)
	rows.append_array(_make_gear_rows(slot, armor))
	var backpack := _make_row("pack", "pack", "Pack", InfantryGear.packs_of(armor), str(slot.infantry.pack))
	rows.append(backpack)
	return rows


static func _make_gear_rows(slot: CharacterSlot, armor: Dictionary) -> Array:
	var out := []
	var items: Dictionary = armor.get("hand_items", {})
	var ids := items.keys()
	ids.sort()
	for id in ids:
		if not bool(InfantryGear.item(str(id)).get("mapped", false)):
			continue
		var carried := (slot.infantry.gear as Dictionary).has(id)
		var row := _make_row("gear:%s" % id, "gear", str(InfantryGear.item(str(id)).get("name", id)), "gear", str(id) if carried else "")
		row.ammo = int((slot.infantry.gear as Dictionary).get(id, 0))
		row.ammo_max = int(items[id])
		out.append(row)
	return out


static func _make_vehicle_rows(slot: CharacterSlot, ctx: LoadoutContext) -> Array:
	var v := Packs.vehicle(slot.vehicle)
	if v.is_empty():
		return []
	var rows := []
	var fixed := PackVehicleLoader.has_fixed_loadout(v)
	var masks := WeaponFit.hardpoint_masks(v)
	for i in masks.size():
		var current := str(slot.herc_loadout[i]) if i < slot.herc_loadout.size() else ""
		var row := _make_row("hardpoint:%d" % i, "hardpoint", "Hardpoint %d (%s)" % [i + 1, WeaponFit.hardpoint_size(v, i)], int(masks[i]), current)
		row.locked = fixed or ctx.source == LoadoutContext.SOURCE_STASH
		rows.append(row)
	rows.append(_make_row("herc_skin", "skin", "Skin", "skin", slot.herc_skin))
	return rows


# ------------------------------------------------------------------ fit

static func _make_infantry_kg(slot: CharacterSlot) -> float:
	var kg := 0.0
	for w in slot.infantry.weapons:
		kg += float(ExtractionItems.item(ExtractionItems.make_id("weapon", str(w))).get("kg", 0.0))
	for w in slot.infantry.ammo:
		kg += float(ExtractionItems.item(ExtractionItems.make_id("ammo", str(w))).get("kg", 0.0)) * int(slot.infantry.ammo[w])
	for g in slot.infantry.gear:
		kg += float(ExtractionItems.item(ExtractionItems.make_id("gear", str(g))).get("kg", 0.0)) * int(slot.infantry.gear[g])
	var backpack := str(slot.infantry.pack)
	return kg + (float(ExtractionItems.item(ExtractionItems.make_id("pack", backpack)).get("kg", 0.0)) if backpack != "" else 0.0)


static func _make_vehicle_fit(slot: CharacterSlot) -> Dictionary:
	var masks := WeaponFit.hardpoint_masks(Packs.vehicle(slot.vehicle))
	var filled := slot.herc_loadout.filter(func(w: String) -> bool: return w != "").size()
	var ok := true
	for i in mini(masks.size(), slot.herc_loadout.size()):
		var wid := str(slot.herc_loadout[i])
		ok = ok and (wid == "" or WeaponFit.fits_mask(Packs.weapon(wid), int(masks[i])))
	return {"slots": filled, "slots_max": masks.size(), "kg": 0.0, "kg_max": 0.0, "ok": ok}


# ------------------------------------------------------------------ setting

static func _apply_armor(slot: CharacterSlot, armor_id: String) -> bool:
	var armor := InfantryCatalog.armor(armor_id)
	if armor.is_empty():
		return false
	var old: Dictionary = slot.infantry.duplicate(true)
	slot.apply_armor_defaults(armor_id)
	var kept := []
	for w in old.weapons:
		if InfantryCatalog.allows_weapon(armor_id, str(w)) and kept.size() < int(armor.get("max_weapons", 0)):
			kept.append(w)
	slot.infantry.weapons = kept if not kept.is_empty() else slot.infantry.weapons
	slot.infantry.ammo = {}
	for w in slot.infantry.weapons:
		var capacity := InfantryCatalog.make_ammo_capacity(armor_id, str(w))
		if capacity > 0:
			slot.infantry.ammo[w] = mini(int((old.ammo as Dictionary).get(w, capacity)), capacity)
	if (armor.get("packs", []) as Array).has(str(old.pack)):
		slot.infantry.pack = old.pack
	return true


static func _apply_weapon(slot: CharacterSlot, index: int, weapon_id: String) -> bool:
	var armor := InfantryCatalog.armor(slot.armor)
	var weapons: Array = slot.infantry.weapons
	if index < 0 or index >= int(armor.get("max_weapons", 0)) or not InfantryCatalog.allows_weapon(slot.armor, weapon_id):
		return false
	if weapons.has(weapon_id) and (index >= weapons.size() or weapons[index] != weapon_id):
		return false   # a weapon is carried once
	if index < weapons.size():
		(slot.infantry.ammo as Dictionary).erase(str(weapons[index]))
		weapons[index] = weapon_id
	else:
		weapons.append(weapon_id)
	var capacity := InfantryCatalog.make_ammo_capacity(slot.armor, weapon_id)
	if capacity > 0:
		slot.infantry.ammo[weapon_id] = capacity
	return true


static func _apply_gear(slot: CharacterSlot, item_id: String) -> bool:
	var items: Dictionary = InfantryCatalog.armor(slot.armor).get("hand_items", {})
	if not items.has(item_id):
		return false
	slot.infantry.gear[item_id] = int(items[item_id])
	return true


static func _apply_pack(slot: CharacterSlot, pack_id: String) -> bool:
	if not (InfantryGear.packs_of(InfantryCatalog.armor(slot.armor)) as Array).has(pack_id):
		return false
	slot.infantry.pack = pack_id
	return true


static func _apply_skin(slot: CharacterSlot, skin_id: String) -> bool:
	var shown := slot.body if slot.body != "" else PlayerProfile.make_default_body(slot.armor)
	if not CatalogBridge.make_skins(shown).any(func(s: Dictionary) -> bool: return str(s.id) == skin_id):
		return false
	slot.skin = skin_id
	return true


static func _apply_hardpoint(slot: CharacterSlot, index: int, weapon_id: String) -> bool:
	var v := Packs.vehicle(slot.vehicle)
	var masks := WeaponFit.hardpoint_masks(v)
	if v.is_empty() or PackVehicleLoader.has_fixed_loadout(v) or index < 0 or index >= masks.size():
		return false
	if not WeaponFit.fits_mask(Packs.weapon(weapon_id), int(masks[index])):
		return false
	while slot.herc_loadout.size() < masks.size():
		slot.herc_loadout.append("")
	slot.herc_loadout[index] = weapon_id
	return true


static func _apply_herc_skin(slot: CharacterSlot, skin_id: String) -> bool:
	if not SkinCatalog.make_vehicle_skin_choices(slot.vehicle).any(func(s: Dictionary) -> bool: return str(s.id) == skin_id):
		return false
	slot.herc_skin = skin_id
	return true


static func _apply_vehicle(slot: CharacterSlot, vehicle_id: String) -> bool:
	if Packs.vehicle(vehicle_id).is_empty():
		return false
	slot.apply_vehicle_defaults(vehicle_id)
	return true

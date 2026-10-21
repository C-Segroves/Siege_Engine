class_name OperatorEquip
extends RefCounted
## Puts a store entry (StoreCatalog) into a CharacterSlot: the one place that knows which loadout row an entry of each
## kind goes to (docs/design/lobby_loadout_economy.md section 6.1). Pure data, no UI. Every function returns
## {ok, text}; a failed call leaves the slot as it was. Ownership and prices are the caller's business (OperatorState).

const NO_FREE_WEAPON := "No free weapon slot: remove one first (right click / X)"
const NO_FREE_HARDPOINT := "No free hardpoint takes %s: select one to replace"


## Equips `entry` into `slot`; `selected_row` (a LoadoutLayout row key or "") says where a weapon should go.
static func apply_entry(slot: CharacterSlot, entry: Dictionary, selected_row: String) -> Dictionary:
	var id := str(entry.id)
	var ref := UnlockId.ref_of(id)
	var label := str(entry.name)
	match str(entry.kind):
		"weapon":
			return _apply_weapon(slot, ref, label, selected_row)
		"herc_weapon":
			return _apply_herc_weapon(slot, ref, label, selected_row)
		"ammo":
			return _apply_ammo(slot, ref, label)
		"gear":
			return _make_result(LoadoutLayout.apply_set(slot, "gear:" + ref, ref), label, make_fit_reason(slot, entry))
		"pack":
			return _make_result(LoadoutLayout.apply_set(slot, "pack", ref), label, make_fit_reason(slot, entry))
		"armor":
			return _make_result(LoadoutLayout.apply_set(slot, "armour", ref), label, "%s is not installed" % label)
		"body":
			return _apply_body(slot, UnlockId.shape_of(id), label)
		"skin":
			return _apply_skin(slot, id, label)
		"vehicle":
			return _make_result(LoadoutLayout.apply_set(slot, "vehicle", ref), label, "%s is not installed" % label)
		"herc_skin":
			return _apply_herc_skin(slot, id, label)
		MountEntries.KIND_PART:
			return _apply_mount_part(slot, entry, label)
	return _make_fail("%s cannot be equipped" % label)


## "" when `entry` could be put on `slot` (somewhere), else why not ("does not fit Light Armor"). Used for the red
## "does not fit" mark on store entries; it is a quick test, apply_entry has the last word.
static func make_fit_reason(slot: CharacterSlot, entry: Dictionary, selected_row := "") -> String:
	var armor := InfantryCatalog.armor(slot.armor)
	var ref := UnlockId.ref_of(str(entry.id))
	var armor_name := str(armor.get("name", slot.armor))
	match str(entry.kind):
		"weapon":
			return "" if InfantryCatalog.allows_weapon(slot.armor, ref) else "does not fit %s" % armor_name
		"ammo":
			return "" if InfantryCatalog.make_ammo_capacity(slot.armor, ref) > 0 else "%s takes no such ammunition" % armor_name
		"gear":
			return "" if (armor.get("hand_items", {}) as Dictionary).has(ref) else "does not fit %s" % armor_name
		"pack":
			return "" if (armor.get("packs", []) as Array).has(ref) else "does not fit %s" % armor_name
		"herc_weapon":
			return _make_hardpoint_reason(slot, ref, selected_row)
		"body":
			return "" if _offers_body(slot, UnlockId.shape_of(str(entry.id))) else "does not fit %s" % armor_name
		"skin":
			return "" if _offers_skin(slot, str(entry.id)) else "is for another body"
		"herc_skin":
			return "" if UnlockId.shape_of(str(entry.id)) == SkinCatalog.make_vehicle_shape(slot.vehicle) else "is for another vehicle"
	return ""


## Why Herc weapon `weapon_id` does not fit: the selected hardpoint when one is selected, else every hardpoint.
static func _make_hardpoint_reason(slot: CharacterSlot, weapon_id: String, selected_row: String) -> String:
	var v := Packs.vehicle(slot.vehicle)
	if PackVehicleLoader.has_fixed_loadout(v):
		return "this vehicle has a fixed loadout"
	var masks := WeaponFit.hardpoint_masks(v)
	var weapon := Packs.weapon(weapon_id)
	if selected_row.begins_with("hardpoint:"):
		var index := int(selected_row.get_slice(":", 1))
		if index >= 0 and index < masks.size():
			return "" if WeaponFit.fits_mask(weapon, int(masks[index])) else "too big for a %s hardpoint" % WeaponFit.hardpoint_size(v, index)
	return "" if _find_hardpoint(slot, weapon_id, false) >= 0 else "fits no hardpoint of this vehicle"


static func _make_result(ok: bool, label: String, fail_text: String) -> Dictionary:
	return {"ok": true, "text": "Equipped %s" % label} if ok else _make_fail(fail_text if fail_text != "" else "%s does not fit" % label)


static func _make_fail(text: String) -> Dictionary:
	return {"ok": false, "text": text}


static func _apply_weapon(slot: CharacterSlot, weapon_id: String, label: String, selected_row: String) -> Dictionary:
	var armor := InfantryCatalog.armor(slot.armor)
	if not InfantryCatalog.allows_weapon(slot.armor, weapon_id):
		return _make_fail("%s does not fit %s" % [label, armor.get("name", slot.armor)])
	var weapons: Array = slot.infantry.weapons
	if weapons.has(weapon_id):
		return _make_fail("%s is already carried" % label)
	var row := selected_row if selected_row.begins_with("weapon:") else "weapon:%d" % weapons.size()
	if int(row.get_slice(":", 1)) >= int(armor.get("max_weapons", 0)):
		return _make_fail(NO_FREE_WEAPON)
	return _make_result(LoadoutLayout.apply_set(slot, row, weapon_id), label, "")


static func _apply_herc_weapon(slot: CharacterSlot, weapon_id: String, label: String, selected_row: String) -> Dictionary:
	if PackVehicleLoader.has_fixed_loadout(Packs.vehicle(slot.vehicle)):
		return _make_fail("%s has a fixed loadout" % Packs.vehicle(slot.vehicle).get("name", slot.vehicle))
	var row := selected_row if selected_row.begins_with("hardpoint:") else ""
	if row == "":
		var index := _find_hardpoint(slot, weapon_id, true)
		if index < 0:
			return _make_fail(NO_FREE_HARDPOINT % label)
		row = "hardpoint:%d" % index
	return _make_result(LoadoutLayout.apply_set(slot, row, weapon_id), label, "%s does not fit that hardpoint" % label)


## The first hardpoint that takes `weapon_id` (and, with `only_empty`, is empty); -1 when none.
static func _find_hardpoint(slot: CharacterSlot, weapon_id: String, only_empty: bool) -> int:
	var v := Packs.vehicle(slot.vehicle)
	var masks := WeaponFit.hardpoint_masks(v)
	for i in masks.size():
		var taken := i < slot.herc_loadout.size() and str(slot.herc_loadout[i]) != ""
		if WeaponFit.fits_mask(Packs.weapon(weapon_id), int(masks[i])) and not (only_empty and taken):
			return i
	return -1


static func _apply_ammo(slot: CharacterSlot, weapon_id: String, label: String) -> Dictionary:
	var capacity := InfantryCatalog.make_ammo_capacity(slot.armor, weapon_id)
	if not LoadoutLayout.apply_set_ammo(slot, weapon_id, capacity):
		return _make_fail("Carry the weapon for %s first" % label)
	return {"ok": true, "text": "Refilled %s" % label}


static func _offers_body(slot: CharacterSlot, shape: String) -> bool:
	return CatalogBridge.make_bodies(slot.armor).any(func(b: Dictionary) -> bool: return str(b.id) == shape)


static func _apply_body(slot: CharacterSlot, shape: String, label: String) -> Dictionary:
	if not _offers_body(slot, shape):
		return _make_fail("%s does not fit %s" % [label, InfantryCatalog.armor(slot.armor).get("name", slot.armor)])
	slot.body = "" if shape == PlayerProfile.make_default_body(slot.armor) else shape
	slot.skin = ""
	return {"ok": true, "text": "Equipped %s" % label}


static func _offers_skin(slot: CharacterSlot, skin_unlock_id: String) -> bool:
	var shape := UnlockId.shape_of(skin_unlock_id)
	var shown := slot.body if slot.body != "" else PlayerProfile.make_default_body(slot.armor)
	return shape == shown or _offers_body(slot, shape)


static func _apply_skin(slot: CharacterSlot, skin_unlock_id: String, label: String) -> Dictionary:
	if not _offers_skin(slot, skin_unlock_id):
		return _make_fail("%s is for another body" % label)
	var shape := UnlockId.shape_of(skin_unlock_id)
	if shape != (slot.body if slot.body != "" else PlayerProfile.make_default_body(slot.armor)):
		_apply_body(slot, shape, label)
	return _make_result(LoadoutLayout.apply_set(slot, "skin", UnlockId.skin_of(skin_unlock_id)), label, "%s is not offered for this body" % label)


static func _apply_mount_part(slot: CharacterSlot, entry: Dictionary, label: String) -> Dictionary:
	var mounts := slot.make_mounts()
	var index: int = MountEntries.make_slot_index(str(entry.mount_row))
	if not HercMounts.apply_set(Packs.vehicle(slot.vehicle), mounts, index, int(entry.mount_value)):
		return _make_fail("%s does not fit that component slot" % label)
	slot.herc_mounts = mounts
	return {"ok": true, "text": "Equipped %s" % label}


static func _apply_herc_skin(slot: CharacterSlot, skin_unlock_id: String, label: String) -> Dictionary:
	if UnlockId.shape_of(skin_unlock_id) != SkinCatalog.make_vehicle_shape(slot.vehicle):
		return _make_fail("%s is for another vehicle" % label)
	return _make_result(LoadoutLayout.apply_set(slot, "herc_skin", UnlockId.skin_of(skin_unlock_id)), label, "")

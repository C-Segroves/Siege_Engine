class_name ExtractionLoadout
extends RefCounted
## Between a raid soldier and his inventory (host; docs/design/extraction.md section 4):
##   * the weapons in hand are the first weapon items of the inventory his armour may carry (up to max_weapons);
##     the worn pack is the first pack item it may wear; both stay inventory items (they weigh);
##   * rounds and hand items are loaded from the inventory as they are used (apply_reload, every reload_seconds):
##     a weapon's magazine and the kit's grenades / mines / repair kits hold what was taken out;
##   * dying or extracting hands back everything carried: the inventory plus the loaded rounds and kit
##     (make_carried_stacks).
## The inventory panel's Equip moves an item to the front of the inventory (ExtractionInventory.apply_move_to_front).

## Item kinds the inventory panel can equip (a weapon in hand, a pack worn).
const EQUIP_KINDS := ["weapon", "pack"]


## True when `item_id` is the weapon in `soldier`'s hand or the pack on his back.
static func is_equipped(soldier: Infantry, item_id: String) -> bool:
	match ExtractionItems.kind_of(item_id):
		"weapon":
			return soldier.current_weapon() != null and soldier.current_weapon().weapon_id == ExtractionItems.ref_of(item_id)
		"pack":
			return soldier.kit.pack_id == ExtractionItems.ref_of(item_id)
	return false


## True when `item_id` is a weapon `soldier` carries ready (one of his weapon slots), in hand or not.
static func is_carried_ready(soldier: Infantry, item_id: String) -> bool:
	return ExtractionItems.kind_of(item_id) == "weapon" and soldier.make_loadout().has(ExtractionItems.ref_of(item_id))


## True when `soldier` could take `item_id` in hand / wear it (his armour allows it) but does not yet.
static func can_equip(soldier: Infantry, item_id: String) -> bool:
	var ref := ExtractionItems.ref_of(item_id)
	match ExtractionItems.kind_of(item_id):
		"weapon":
			return InfantryCatalog.allows_weapon(soldier.armor_id, ref) and not is_equipped(soldier, item_id)
		"pack":
			return InfantryGear.packs_of(soldier.armor).has(ref) and not is_equipped(soldier, item_id)
	return false


## The weapon ids `soldier` should carry from `inv`.
static func make_weapon_loadout(soldier: Infantry, inv: ExtractionInventory) -> Array:
	return make_kit_weapons(soldier.armor_id, inv)


## The weapon ids armour `armor_id` carries from `inv` (what the raid spawn gives, and what Operator Setup shows).
static func make_kit_weapons(armor_id: String, inv: ExtractionInventory) -> Array:
	var out := []
	var slots := int(InfantryCatalog.armor(armor_id).get("max_weapons", 3))
	for id in inv.stacks:
		if ExtractionItems.kind_of(id) != "weapon" or out.size() >= slots:
			continue
		var wid := ExtractionItems.ref_of(id)
		if InfantryCatalog.allows_weapon(armor_id, wid) and not out.has(wid):
			out.append(wid)
	return out


## What a raider in `armor_id` really carries from kit `inv`: its weapons, else the rules' free weapon (apply_free_weapon).
static func make_raid_weapons(armor_id: String, inv: ExtractionInventory) -> Array:
	var out := make_kit_weapons(armor_id, inv)
	if not out.is_empty():
		return out
	for wid in ExtractionRules.data().get("free_weapons", []):
		if InfantryCatalog.allows_weapon(armor_id, str(wid)) and ExtractionItems.has(ExtractionItems.make_id("weapon", str(wid))):
			return [str(wid)]
	return out


## The weapon item after the one in `soldier`'s hand among every weapon of `inv` his armour may use (sorted by id, so
## the order stays put as an equip reorders the inventory; wraps round): "" when none is usable.
static func make_next_weapon_item(soldier: Infantry, inv: ExtractionInventory) -> String:
	var usable := []
	for id in inv.stacks:
		if ExtractionItems.kind_of(id) == "weapon" and InfantryCatalog.allows_weapon(soldier.armor_id, ExtractionItems.ref_of(id)):
			usable.append(str(id))
	if usable.is_empty():
		return ""
	usable.sort()
	var cur := soldier.current_weapon()
	var at := -1
	if cur != null:
		at = usable.find(ExtractionItems.make_id("weapon", cur.weapon_id))
	return usable[(at + 1) % usable.size()]


## The pack `soldier` wears from `inv` ("" = none).
static func make_worn_pack(soldier: Infantry, inv: ExtractionInventory) -> String:
	var allowed := InfantryGear.packs_of(soldier.armor)
	for id in inv.stacks:
		if ExtractionItems.kind_of(id) == "pack" and allowed.has(ExtractionItems.ref_of(id)):
			return ExtractionItems.ref_of(id)
	return ""


## {weapon id: rounds} loaded in `soldier`'s weapons.
static func make_loaded_rounds(soldier: Infantry) -> Dictionary:
	var out := {}
	for w in soldier.weapons:
		if w.ammo_max >= 0:
			out[w.weapon_id] = int(out.get(w.weapon_id, 0)) + maxi(w.ammo, 0)
	return out


## Sets the rounds of `soldier`'s weapons from `rounds` ({weapon id: rounds}); weapons not listed are empty.
static func apply_loaded_rounds(soldier: Infantry, rounds: Dictionary) -> void:
	for w in soldier.weapons:
		if w.ammo_max >= 0:
			w.ammo = mini(int(rounds.get(w.weapon_id, 0)), w.ammo_max)


## Applies the rules' raid tuning (weapon_overrides: damage and refire scales) to `soldier`'s weapons; every peer,
## after each equip (the host's hits use it, the clients' refire matches).
static func apply_weapon_overrides(soldier: Infantry) -> void:
	for w in soldier.weapons:
		var o := ExtractionItems.make_weapon_override(w.weapon_id)
		if o.is_empty() or w.has_meta("raid_tuned"):
			continue
		w.set_meta("raid_tuned", true)
		w.armor_damage *= float(o.get("damage_scale", 1.0))
		w.shield_damage *= float(o.get("damage_scale", 1.0))
		w.refire *= float(o.get("refire_scale", 1.0))


## A raider who brings no weapon his armour can carry gets the rules' free weapon (playtest X5); true when he did.
static func apply_free_weapon(soldier: Infantry, inv: ExtractionInventory) -> bool:
	if not make_weapon_loadout(soldier, inv).is_empty():
		return false
	for wid in ExtractionRules.data().get("free_weapons", []):
		if InfantryCatalog.allows_weapon(soldier.armor_id, str(wid)) and ExtractionItems.has(ExtractionItems.make_id("weapon", str(wid))):
			inv.apply_add_unchecked(ExtractionItems.make_id("weapon", str(wid)), 1)
			return true
	return false


## The raid starts: no free spawn kit, empty magazines (apply_reload fills them from the inventory).
static func apply_raid_start(soldier: Infantry) -> void:
	soldier.kit.counts.clear()
	soldier.kit.pack_id = ""
	soldier.kit.pack_active = false
	apply_loaded_rounds(soldier, {})


## Loads rounds and hand items from `inv` into the weapons and the kit; wears the pack. True when `inv` changed.
static func apply_reload(soldier: Infantry, inv: ExtractionInventory) -> bool:
	var changed := false
	for w in soldier.weapons:
		var missing := (w as InfantryWeapon).missing_rounds() if w is InfantryWeapon else 0
		if missing > 0:
			var n := inv.apply_take(ExtractionItems.make_id("ammo", w.weapon_id), missing)
			w.ammo += n
			changed = changed or n > 0
	for item_id in soldier.armor.get("hand_items", {}):
		var need := soldier.kit.make_max_count(soldier.armor, item_id) - soldier.kit.count(item_id)
		var n := inv.apply_take(ExtractionItems.make_id("gear", item_id), need) if need > 0 else 0
		if n > 0:
			soldier.kit.counts[item_id] = soldier.kit.count(item_id) + n
			changed = true
	_apply_grenade_choice(soldier)
	soldier.apply_worn_pack(make_worn_pack(soldier, inv))
	return changed


## The grenade type thrown is one the kit has (it switches when the current one runs out).
static func _apply_grenade_choice(soldier: Infantry) -> void:
	if soldier.kit.count(soldier.kit.grenade_id) > 0:
		return
	for id in InfantryGear.grenades_of(soldier.armor):
		if soldier.kit.count(id) > 0:
			soldier.kit.grenade_id = id
			return


## Unloads `weapon_id`'s rounds back into `inv` (it is about to be dropped).
static func apply_unload_weapon(soldier: Infantry, inv: ExtractionInventory, weapon_id: String) -> void:
	for w in soldier.weapons:
		if w.weapon_id == weapon_id and w.ammo > 0 and w.ammo_max >= 0:
			inv.apply_add_unchecked(ExtractionItems.make_id("ammo", weapon_id), w.ammo)
			w.ammo = 0


## Everything `soldier` carries: the inventory plus his loaded rounds and kit, as stacks.
static func make_carried_stacks(soldier: Infantry, inv: ExtractionInventory) -> Array:
	var all := ExtractionInventory.new()
	all.apply_merge(inv.make_stacks())
	if soldier == null:
		return all.make_stacks()
	var rounds := make_loaded_rounds(soldier)
	for wid in rounds:
		all.apply_add_unchecked(ExtractionItems.make_id("ammo", wid), int(rounds[wid]))
	for item_id in soldier.kit.counts:
		all.apply_add_unchecked(ExtractionItems.make_id("gear", item_id), soldier.kit.count(item_id))
	return all.make_stacks()


## A killed player's `carried` stacks split by his insured slot `slot` ([item id, units] or []):
## {kept: what the slot holds of them, dropped: the rest but standard issue (free weapons), which is worth nothing}.
static func make_insured_split(carried: Array, slot: Array) -> Dictionary:
	var rest := ExtractionInventory.new()
	rest.apply_merge(carried)
	var id := ExtractionProfile.make_insured_id_of(slot)
	var n := rest.apply_take(id, int(slot[1])) if id != "" else 0
	var dropped := rest.make_stacks().filter(func(st: Array) -> bool: return not ExtractionItems.is_standard_issue(str(st[0])))
	return {"kept": [[id, n]] if n > 0 else [], "dropped": dropped}


## What a killed bot leaves: his weapons, their rounds and his kit.
static func make_bot_stacks(soldier: Infantry) -> Array:
	var inv := ExtractionInventory.new()
	for wid in soldier.make_loadout():
		if not ExtractionItems.is_free_weapon(wid):
			inv.apply_add_unchecked(ExtractionItems.make_id("weapon", wid), 1)
	return make_carried_stacks(soldier, inv)

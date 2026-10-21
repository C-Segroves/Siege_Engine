class_name SpawnLoadout
extends RefCounted
## The weapons a soldier spawns with (docs/design/lobby_loadout_economy.md sections 2.6 and 13): outside extraction
## exactly the weapons of the pilot's character slot (roster entry "slot"), each with a full load; a soldier without a
## slot (a bot, a mission actor) or a slot of another armour gets the armour's spawn weapons. In a raid the inventory
## decides instead (ExtractionLoadout.make_weapon_loadout), after the spawn.


## The weapon ids armour `armor_id` spawns with for the roster `entry`: the slot's, else the armour's default_loadout.
static func make_for(entry: Dictionary, armor_id: String) -> Array:
	var armor := InfantryCatalog.armor(armor_id)
	var wanted := make_slot_weapons(entry, armor_id)
	return wanted if not wanted.is_empty() else (armor.get("default_loadout", []) as Array).duplicate()


## The slot's weapons the armour can carry (at most its max_weapons, in slot order); empty without a slot of this armour.
static func make_slot_weapons(entry: Dictionary, armor_id: String) -> Array:
	var out := []
	if not entry.get("slot") is Dictionary or str((entry.slot as Dictionary).get("a", "")) != armor_id:
		return out
	var limit := int(InfantryCatalog.armor(armor_id).get("max_weapons", 3))
	for w in CharacterSlot.make_strings((entry.slot as Dictionary).get("w", [])):
		var wdef := Packs.weapon(str(w))
		if out.size() >= limit:
			break
		if not wdef.is_empty() and wdef.get("category", "") == "infantry" and InfantryCatalog.allows_weapon(armor_id, str(w)) and not out.has(w):
			out.append(w)
	return out


## The kit the pilot's slot of armour `armor_id` spawns with besides weapons: {pack, grenade, counts} (backpack id, the
## grenade type he carries, hand item id -> count; applied by InfantryKit.apply_slot). Empty without a slot of this armour.
static func make_kit(entry: Dictionary, armor_id: String) -> Dictionary:
	if not entry.get("slot") is Dictionary or str((entry.slot as Dictionary).get("a", "")) != armor_id:
		return {}
	var armor := InfantryCatalog.armor(armor_id)
	var slot: Dictionary = entry.slot
	var counts := {}
	var grenade := ""
	var carried: Dictionary = CharacterSlot.make_counts(slot.get("g", {}))
	for id in carried:
		var n := int(carried[id])
		if n > 0 and (armor.get("hand_items", {}) as Dictionary).has(str(id)):
			counts[str(id)] = n
			if InfantryGear.grenades_of(armor).has(str(id)) and grenade == "":
				grenade = str(id)
	return {"pack": str(slot.get("p", "")), "grenade": grenade, "counts": counts}

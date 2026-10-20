class_name SlotCheck
extends RefCounted
## What is wrong with a CharacterSlot in a match (CharacterSlot.make_blocks / make_resolved): parts the match forbids
## (LoadoutContext), parts the armour or hardpoint cannot take, parts the operator does not own. A block is
## {part, id, text}; `part` is the slot field ("armor", "body", "skin", "vehicle", "herc_skin", "weapon:<i>", "ammo:<id>",
## "gear:<id>", "pack", "hardpoint:<i>").

const MAX_PASSES := 4
const SKIN_KINDS := ["skin", "herc_skin"]


static func make_blocks(slot: CharacterSlot, ctx: LoadoutContext, owned: Unlocks) -> Array:
	var out := []
	out.append_array(_make_look_blocks(slot, ctx, owned))
	out.append_array(_make_infantry_blocks(slot, ctx, owned))
	out.append_array(_make_herc_blocks(slot, ctx, owned))
	return out


static func make_resolved(slot: CharacterSlot, ctx: LoadoutContext, owned: Unlocks) -> Dictionary:
	var built := slot.make_copy()
	var dropped := []
	for pass_index in MAX_PASSES:
		var blocks := make_blocks(built, ctx, owned)
		if blocks.is_empty():
			break
		var armor_blocks := blocks.filter(func(b: Dictionary) -> bool: return b.part == "armor")
		var fixes := armor_blocks if not armor_blocks.is_empty() else blocks   # a new armour changes what else fits
		for b in fixes:
			dropped.append(str(b.text))
		fixes.reverse()   # later weapon rows first: removing one shifts the rows after it
		for b in fixes:
			_apply_fix(built, str(b.part), ctx)
	return {"slot": built, "dropped": dropped}


## A readable name of the part an unlock id stands for.
static func make_name(id: String) -> String:
	var ref := UnlockId.ref_of(id)
	match UnlockId.kind_of(id):
		"armor":
			return str(InfantryCatalog.armor(ref).get("name", ref))
		"vehicle":
			return str(Packs.vehicle(ref).get("name", ref))
		"weapon", "herc_weapon", "ammo":
			var w := Packs.weapon(ref)
			return str(w.get("display_name", w.get("name", ref)))
		"gear":
			return str(InfantryGear.item(ref).get("name", ref))
		"pack":
			return str(InfantryGear.pack(ref).get("name", ref))
	if SKIN_KINDS.has(UnlockId.kind_of(id)):
		return UnlockId.skin_of(id)
	return ref.get_slice(":", ref.count(":"))


# ------------------------------------------------------------------ scanning

static func _block(part: String, id: String, text: String) -> Dictionary:
	return {"part": part, "id": id, "text": "%s: %s" % [make_name(id), text]}


## "" when `id` can be fielded here, else why not (the match first, then ownership).
static func _make_reason(id: String, ctx: LoadoutContext, owned: Unlocks) -> String:
	var reason := ctx.make_block_reason(id)
	return reason if reason != "" else ctx.make_ownership_block_with(id, owned)


static func _make_look_blocks(slot: CharacterSlot, ctx: LoadoutContext, owned: Unlocks) -> Array:
	var out := []
	if slot.armor != "":
		var armor_id := UnlockId.make("armor", slot.armor)
		var why := "not installed" if InfantryCatalog.armor(slot.armor).is_empty() else _make_reason(armor_id, ctx, owned)
		if why != "":
			return [_block("armor", armor_id, why)]
		out.append_array(_make_body_skin_blocks(slot, ctx, owned))
	if slot.vehicle != "":
		var vehicle_id := UnlockId.make("vehicle", slot.vehicle)
		var why := "not installed" if Packs.vehicle(slot.vehicle).is_empty() else _make_reason(vehicle_id, ctx, owned)
		if why != "":
			out.append(_block("vehicle", vehicle_id, why))
		elif slot.herc_skin != "":
			out.append_array(_make_herc_skin_blocks(slot, ctx, owned))
	return out


static func _make_body_skin_blocks(slot: CharacterSlot, ctx: LoadoutContext, owned: Unlocks) -> Array:
	var out := []
	var shown := slot.body if slot.body != "" else PlayerProfile.make_default_body(slot.armor)
	if slot.body != "":
		var body_id := UnlockId.make("body", slot.body)
		var offered := CatalogBridge.make_bodies(slot.armor).any(func(b: Dictionary) -> bool: return str(b.id) == slot.body)
		var why := "does not fit the armour" if not offered else _make_reason(body_id, ctx, owned)
		if why != "":
			out.append(_block("body", body_id, why))
			return out
	if slot.skin != "":
		var skin_id := UnlockId.make("skin", UnlockId.make_skin_ref(shown, slot.skin))
		var offered := CatalogBridge.make_skins(shown).any(func(s: Dictionary) -> bool: return str(s.id) == slot.skin)
		var why := "is not offered for this body" if not offered else _make_reason(skin_id, ctx, owned)
		if why != "":
			out.append(_block("skin", skin_id, why))
	return out


static func _make_herc_skin_blocks(slot: CharacterSlot, ctx: LoadoutContext, owned: Unlocks) -> Array:
	var shape := SkinCatalog.make_vehicle_shape(slot.vehicle)
	var id := UnlockId.make("herc_skin", UnlockId.make_skin_ref(shape, slot.herc_skin))
	var offered := SkinCatalog.make_vehicle_skin_choices(slot.vehicle).any(func(s: Dictionary) -> bool: return str(s.id) == slot.herc_skin)
	var why := "is not offered for this vehicle" if not offered else _make_reason(id, ctx, owned)
	return [] if why == "" else [_block("herc_skin", id, why)]


static func _make_infantry_blocks(slot: CharacterSlot, ctx: LoadoutContext, owned: Unlocks) -> Array:
	var out := []
	if slot.armor == "" or InfantryCatalog.armor(slot.armor).is_empty():
		return out
	var armor := InfantryCatalog.armor(slot.armor)
	var weapons: Array = slot.infantry.weapons
	for i in weapons.size():
		var wid := str(weapons[i])
		var id := UnlockId.make("weapon", wid)
		var why := ""
		if not InfantryCatalog.allows_weapon(slot.armor, wid):
			why = "does not fit %s" % str(armor.get("name", slot.armor))
		elif not _is_issued(armor, "weapon", wid):
			why = _make_reason(id, ctx, owned)
		if why != "":
			out.append(_block("weapon:%d" % i, id, why))
			continue
		var ammo_id := UnlockId.make("ammo", wid)
		var ammo_why := _make_reason(ammo_id, ctx, owned) if (slot.infantry.ammo as Dictionary).has(wid) and not _is_issued(armor, "weapon", wid) else ""
		if ammo_why != "":
			out.append(_block("ammo:%s" % wid, ammo_id, ammo_why))
	out.append_array(_make_gear_blocks(slot, armor, ctx, owned))
	return out


static func _make_gear_blocks(slot: CharacterSlot, armor: Dictionary, ctx: LoadoutContext, owned: Unlocks) -> Array:
	var out := []
	var fits_text := "does not fit %s" % str(armor.get("name", slot.armor))
	for g in slot.infantry.gear:
		var id := UnlockId.make("gear", str(g))
		var why := fits_text if not (armor.get("hand_items", {}) as Dictionary).has(g) else ("" if _is_issued(armor, "gear", str(g)) else _make_reason(id, ctx, owned))
		if why != "":
			out.append(_block("gear:%s" % g, id, why))
	var backpack := str(slot.infantry.pack)
	if backpack != "":
		var id := UnlockId.make("pack", backpack)
		var why := fits_text if not (armor.get("packs", []) as Array).has(backpack) else _make_reason(id, ctx, owned)
		if why != "":
			out.append(_block("pack", id, why))
	return out


## True for what an armour is issued with (rules "armor_spawn_kit"): its spawn weapons with their ammunition and its
## first grenade need no unlock of their own, so a bought armour is usable at once.
static func _is_issued(armor: Dictionary, kind: String, ref: String) -> bool:
	if not bool(EconomyRules.free_unlocks().get("armor_spawn_kit", false)):
		return false
	if kind == "weapon":
		return (armor.get("default_loadout", []) as Array).has(ref)
	return InfantryGear.grenades_of(armor).slice(0, 1).has(ref)


static func _make_herc_blocks(slot: CharacterSlot, ctx: LoadoutContext, owned: Unlocks) -> Array:
	var out := []
	var v := Packs.vehicle(slot.vehicle)
	if v.is_empty() or PackVehicleLoader.has_fixed_loadout(v) or _make_reason(UnlockId.make("vehicle", slot.vehicle), ctx, owned) != "":
		return out
	var masks := WeaponFit.hardpoint_masks(v)
	for i in slot.herc_loadout.size():
		var wid := str(slot.herc_loadout[i])
		if wid == "":
			continue
		var id := UnlockId.make("herc_weapon", wid)
		var why := ""
		if i >= masks.size() or not WeaponFit.fits_mask(Packs.weapon(wid), int(masks[i])):
			why = "does not fit hardpoint %d" % (i + 1)
		else:
			why = _make_reason(id, ctx, owned)
		if why != "":
			out.append(_block("hardpoint:%d" % i, id, why))
	return out


# ------------------------------------------------------------------ fixing

static func _apply_fix(slot: CharacterSlot, part: String, ctx: LoadoutContext) -> void:
	var kind := part.get_slice(":", 0)
	var arg := part.substr(part.find(":") + 1) if part.contains(":") else ""
	match kind:
		"armor":
			slot.apply_armor_defaults(CharacterSlot.make_free_armor_id(ctx.pack))
		"body":
			slot.body = ""
			slot.skin = ""
		"skin":
			slot.skin = ""
		"vehicle":
			slot.apply_vehicle_defaults(FreeUnlocks.make_default_vehicle())
		"herc_skin":
			slot.herc_skin = ""
		"weapon":
			_apply_drop_weapon(slot, int(arg))
		"ammo":
			(slot.infantry.ammo as Dictionary).erase(arg)
		"gear":
			(slot.infantry.gear as Dictionary).erase(arg)
		"pack":
			slot.infantry.pack = ""
		"hardpoint":
			slot.herc_loadout[int(arg)] = ""


## Removes weapon `i` (and its ammunition); a soldier left with none gets his armour's spawn weapons back.
static func _apply_drop_weapon(slot: CharacterSlot, i: int) -> void:
	var weapons: Array = slot.infantry.weapons
	if i < 0 or i >= weapons.size():
		return
	(slot.infantry.ammo as Dictionary).erase(str(weapons[i]))
	weapons[i] = ""
	slot.infantry.weapons = weapons.filter(func(w: String) -> bool: return w != "")
	if (slot.infantry.weapons as Array).is_empty():
		var armor := InfantryCatalog.armor(slot.armor)
		slot.infantry.weapons = (armor.get("default_loadout", []) as Array).duplicate()

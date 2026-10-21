class_name ExtractionKitEditor
extends RefCounted
## The raid kit as Operator Setup edits it (docs/design/lobby_loadout_economy.md section 6.1): one row per weapon, ammunition,
## hand item and pack place of the worn armour, each with the choices the stash and the kit offer. A choice moves stacks
## between stash and kit (ExtractionProfile.apply_set_kit_count), so what the rows show is exactly what the raid spawn
## gives: the weapons are ExtractionLoadout.make_raid_weapons, the pack ExtractionLoadout.make_kit_pack, the rounds and
## hand items what apply_reload loads from the kit. Pure data, no UI.
## A row is LoadoutLayout's shape plus {choices: [{id, text}], choice: id}; the choice ids of a weapon or pack row are the
## catalog ids ("" = empty), those of a rounds or hand item row the unit counts as text.

const KIND_EMPTY := ""
const EMPTY_TEXT := "(empty)"
const AMMO_STEPS := 10
const NO_ROOM := "No room in the kit for %s."


## The weapon, ammunition, hand item and pack rows of `profile`'s kit, top to bottom.
static func make_rows(profile: ExtractionProfile) -> Array:
	var armor_id := profile.kit_armor
	var armor := InfantryCatalog.armor(armor_id)
	if armor.is_empty():
		return []
	var rows := []
	var weapons := ExtractionLoadout.make_raid_weapons(armor_id, profile.kit)
	for i in int(armor.get("max_weapons", 0)):
		var wid := str(weapons[i]) if i < weapons.size() else ""
		rows.append(_make_weapon_row(profile, i, wid))
		if wid != "" and InfantryCatalog.make_ammo_capacity(armor_id, wid) > 0:
			rows.append(_make_ammo_row(profile, wid))
	rows.append_array(_make_gear_rows(profile, armor))
	rows.append(_make_pack_row(profile, armor))
	return rows


## The fit line numbers of the kit: {slots, slots_max, kg, kg_max, ok} (LoadoutLayout.make_fit's shape).
static func make_fit(profile: ExtractionProfile) -> Dictionary:
	var armor := InfantryCatalog.armor(profile.kit_armor)
	var slots_max := int(armor.get("max_weapons", 0))
	var slots := ExtractionLoadout.make_raid_weapons(profile.kit_armor, profile.kit).size()
	var kg := profile.kit.make_used_kg()
	return {"slots": slots, "slots_max": slots_max, "kg": kg, "kg_max": profile.kit.max_kg,
		"ok": slots <= slots_max and kg <= profile.kit.max_kg + LoadoutLayout.KG_PRECISION}


## Puts `choice` into row `row_key` of the kit; false (the kit as it was) when the kit has no room for it.
static func apply_choice(profile: ExtractionProfile, row_key: String, choice: String) -> bool:
	match row_key.get_slice(":", 0):
		"weapon":
			return _apply_weapon(profile, int(row_key.get_slice(":", 1)), choice)
		"ammo":
			return _apply_count(profile, ExtractionItems.make_id("ammo", row_key.substr(row_key.find(":") + 1)), choice)
		"gear":
			return _apply_count(profile, ExtractionItems.make_id("gear", row_key.substr(row_key.find(":") + 1)), choice)
		"pack":
			return _apply_pack(profile, choice)
	return false


## Everything the player owns for a raid, grouped by item kind: [{kind, label, entries: [{id, stash, kit}]}] in
## ExtractionItems.KINDS order, only kinds he has some of (the stash tab's read-only view).
static func make_overview(profile: ExtractionProfile) -> Array:
	var out := []
	for kind in ExtractionItems.KINDS:
		var entries := []
		for r in ExtractionItems.items_of_kind(kind):
			var id := str(r.id)
			if profile.stash.count(id) > 0 or profile.kit.count(id) > 0:
				entries.append({"id": id, "stash": profile.stash.count(id), "kit": profile.kit.count(id)})
		if not entries.is_empty():
			out.append({"kind": kind, "label": str(ExtractionRules.item_kind(kind).get("label", kind.capitalize())), "entries": entries})
	return out


# ------------------------------------------------------------------ rows

static func _make_row(key: String, kind: String, label: String, current: String) -> Dictionary:
	return {"key": key, "kind": kind, "label": label, "accepts": kind, "current": current, "ammo": 0, "ammo_max": 0,
		"locked": false, "choices": [], "choice": current}


static func _make_weapon_row(profile: ExtractionProfile, index: int, weapon_id: String) -> Dictionary:
	var row := _make_row("weapon:%d" % index, "weapon", "Weapon %d" % (index + 1), weapon_id)
	row.choices = _make_item_choices(profile, "weapon", make_weapon_options(profile, weapon_id, index))
	return row


static func _make_ammo_row(profile: ExtractionProfile, weapon_id: String) -> Dictionary:
	var capacity := InfantryCatalog.make_ammo_capacity(profile.kit_armor, weapon_id)
	var item := ExtractionItems.make_id("ammo", weapon_id)
	var row := _make_row("ammo:%s" % weapon_id, "ammo", "Ammo", weapon_id)
	row.ammo = profile.kit.count(item)
	row.ammo_max = capacity
	row.choice = str(row.ammo)
	row.choices = _make_count_choices(profile, item, _make_ammo_counts(profile, item, capacity), " rounds")
	return row


static func _make_gear_rows(profile: ExtractionProfile, armor: Dictionary) -> Array:
	var out := []
	var items: Dictionary = armor.get("hand_items", {})
	var ids := items.keys()
	ids.sort()
	for id in ids:
		var item := ExtractionItems.make_id("gear", str(id))
		if not ExtractionItems.has(item):
			continue
		var most := int(items[id])
		var row := _make_row("gear:%s" % id, "gear", ExtractionItems.make_name(item), str(id) if profile.kit.count(item) > 0 else "")
		row.ammo = mini(profile.kit.count(item), most)
		row.ammo_max = most
		row.choice = str(row.ammo)
		row.choices = _make_count_choices(profile, item, range(0, mini(most, _make_available(profile, item)) + 1), "")
		out.append(row)
	return out


static func _make_pack_row(profile: ExtractionProfile, armor: Dictionary) -> Dictionary:
	var worn := ExtractionLoadout.make_kit_pack(profile.kit_armor, profile.kit)
	var row := _make_row("pack", "pack", "Pack", worn)
	row.choices = _make_item_choices(profile, "pack", make_pack_options(profile, armor))
	return row


# ------------------------------------------------------------------ choices

## The weapon ids row `index` may hold: empty, the one it holds, and every weapon the armour may carry that the stash or
## the kit has and no other row holds (a free weapon is always on offer).
static func make_weapon_options(profile: ExtractionProfile, current: String, index: int) -> Array:
	var others := ExtractionLoadout.make_raid_weapons(profile.kit_armor, profile.kit)
	if index < others.size():
		others.remove_at(index)
	var out := []
	var free := ExtractionLoadout.make_free_weapon(profile.kit_armor)
	if free != "" and not others.has(free):
		out.append(free)   # the standard-issue weapon is offered whatever the stash holds
	for id in _make_owned_ids(profile, "weapon"):
		var wid := ExtractionItems.ref_of(id)
		if not out.has(wid) and InfantryCatalog.allows_weapon(profile.kit_armor, wid) and not others.has(wid) and (wid == current or _make_available(profile, id) > 0):
			out.append(wid)
	return out


## The pack ids the armour may wear that the stash or the kit has.
static func make_pack_options(profile: ExtractionProfile, armor: Dictionary) -> Array:
	var allowed := InfantryGear.packs_of(armor)
	var out := []
	for id in _make_owned_ids(profile, "pack"):
		if allowed.has(ExtractionItems.ref_of(id)):
			out.append(ExtractionItems.ref_of(id))
	return out


## The item ids of `kind` the stash or the kit holds, plus the standard-issue ones, in id order.
static func _make_owned_ids(profile: ExtractionProfile, kind: String) -> Array:
	var out := []
	for r in ExtractionItems.items_of_kind(kind):
		var id := str(r.id)
		if _make_available(profile, id) > 0:
			out.append(id)
	return out


## Units of `id` the player can put in the kit: kit plus stash (standard issue has no end).
static func _make_available(profile: ExtractionProfile, id: String) -> int:
	if ExtractionItems.is_standard_issue(id):
		return 1
	return profile.kit.count(id) + profile.stash.count(id)


static func _make_item_choices(profile: ExtractionProfile, kind: String, ref_ids: Array) -> Array:
	var out := [{"id": KIND_EMPTY, "text": EMPTY_TEXT}]
	for ref in ref_ids:
		var id := ExtractionItems.make_id(kind, str(ref))
		var where := "" if ExtractionItems.is_standard_issue(id) or profile.kit.count(id) > 0 else "   (stash)"
		out.append({"id": str(ref), "text": ExtractionItems.make_name(id) + where})
	return out


static func _make_count_choices(profile: ExtractionProfile, item: String, counts: Array, unit: String) -> Array:
	var out := []
	for n in counts:
		out.append({"id": str(n), "text": "%d%s" % [n, unit] if n > 0 else "none"})
	if out.is_empty():
		out.append({"id": "0", "text": "none"})
	if profile.kit.count(item) > 0 and not out.any(func(c: Dictionary) -> bool: return str(c.id) == str(profile.kit.count(item))):
		out.append({"id": str(profile.kit.count(item)), "text": "%d%s" % [profile.kit.count(item), unit]})
	return out


## Round counts offered for `item`: none, then steps of a tenth of the armour's load up to what the kit usually brings
## (the starter loads) or all the stash has, whichever is less.
static func _make_ammo_counts(profile: ExtractionProfile, item: String, capacity: int) -> Array:
	var most := mini(_make_available(profile, item), capacity * ExtractionProfile.STARTER_AMMO_LOADS)
	var step := maxi(int(ceil(float(capacity) / AMMO_STEPS)), 1)
	var out := [0]
	var n := step
	while n < most:
		out.append(n)
		n += step
	if most > 0:
		out.append(most)
	return out


# ------------------------------------------------------------------ applying

static func _apply_weapon(profile: ExtractionProfile, index: int, weapon_id: String) -> bool:
	var armor_id := profile.kit_armor
	var held := ExtractionLoadout.make_raid_weapons(armor_id, profile.kit)
	for wid in held:
		profile.apply_set_kit_count(ExtractionItems.make_id("weapon", str(wid)), 1)   # a free weapon given at the spawn joins the kit
	var order := held.duplicate()
	if weapon_id == "":
		if index < order.size():
			order.remove_at(index)
	elif index < order.size():
		order[index] = weapon_id
	else:
		order.append(weapon_id)
	if order.has(weapon_id) and weapon_id != "" and profile.apply_set_kit_count(ExtractionItems.make_id("weapon", weapon_id), 1) < 1:
		return false
	for wid in held:
		if not order.has(wid):
			profile.apply_set_kit_count(ExtractionItems.make_id("weapon", str(wid)), 0)
			profile.apply_set_kit_count(ExtractionItems.make_id("ammo", str(wid)), 0)   # rounds without their weapon go back
	for i in range(order.size() - 1, -1, -1):
		profile.kit.apply_move_to_front(ExtractionItems.make_id("weapon", str(order[i])))
	return true


static func _apply_count(profile: ExtractionProfile, item: String, count_text: String) -> bool:
	var wanted := int(count_text)
	return profile.apply_set_kit_count(item, wanted) == wanted


static func _apply_pack(profile: ExtractionProfile, pack_id: String) -> bool:
	for id in profile.kit.stacks.keys():
		if ExtractionItems.kind_of(str(id)) == "pack" and ExtractionItems.ref_of(str(id)) != pack_id:
			profile.apply_set_kit_count(str(id), 0)
	if pack_id == "":
		return true
	return profile.apply_set_kit_count(ExtractionItems.make_id("pack", pack_id), 1) >= 1

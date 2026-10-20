class_name StoreCatalog
extends RefCounted
## What the unlock store lists (docs/design/lobby_loadout_economy.md section 2.6), built from the installed packs at run
## time. An entry: {id, kind, name, pack, state, price, reason, detail, tooltip_lines, kg, slots, rating, shape_id,
## skin_ids}. States: "free", "owned", "lost" (extraction only: bought back for the rebuy price), "for_sale",
## "not_allowed" (the match forbids it; `reason` says why). Ids of games that are not installed are never listed.
## Prices: base x the kind's multiplier (EconomyRules), at least the minimum price; a flat base for skins and bodies.

const CATEGORIES := [
	{"id": "weapons", "label": "Weapons", "kinds": ["weapon", "herc_weapon"]},
	{"id": "ammo", "label": "Ammo", "kinds": ["ammo"]},
	{"id": "gear", "label": "Gear", "kinds": ["gear"]},
	{"id": "packs", "label": "Packs", "kinds": ["pack"]},
	{"id": "armour", "label": "Armour", "kinds": ["armor"]},
	{"id": "models", "label": "Models", "kinds": ["body"]},
	{"id": "skins", "label": "Skins", "kinds": ["skin", "herc_skin"]},
	{"id": "vehicles", "label": "Vehicles", "kinds": ["vehicle"]}]
const SUPPLIES := "supplies"
## Raid shop kinds (physical stock for the kit); armour and call-ins are unlocks / raid points now.
const SUPPLY_KINDS := ["weapon", "ammo", "gear", "pack"]
const STATE_FREE := "free"
const STATE_OWNED := "owned"
const STATE_LOST := "lost"
const STATE_FOR_SALE := "for_sale"
const STATE_NOT_ALLOWED := "not_allowed"
const OWNED_STATES := [STATE_FREE, STATE_OWNED]
const SORT_NAME := "name"
const SORT_PRICE := "price"
const SORT_RATING := "rating"

## Readable names the catalogs gave to body and skin ids while they were listed (id -> label).
static var _labels := {}


## The categories the store shows in `ctx`: none where there is no store (campaign, bots); in a raid the look parts
## and "supplies" (weapons, ammunition and gear are physical stock there). Outside a raid weapons, ammunition, gear
## and packs are listed too (user answer O2: they are free, so they show no price).
static func make_categories(ctx: LoadoutContext) -> Array:
	var out := []
	if not ctx.store_enabled:
		return out
	for c in CATEGORIES:
		if (c.kinds as Array).any(func(k: String) -> bool: return ctx.is_ownership_checked(k)):
			out.append({"id": c.id, "label": c.label})
	if ctx.source == LoadoutContext.SOURCE_STASH:
		out.append({"id": SUPPLIES, "label": "Supplies"})
	return out


## Every category as a plain parts list, for screens without a store (campaign garage, a bot's card): nothing is bought
## there, the entries are all usable or "not_allowed".
static func make_part_categories() -> Array:
	return CATEGORIES.map(func(c: Dictionary) -> Dictionary: return {"id": c.id, "label": c.label})


## The entries matching `filter` {category, pack, text, owned_only, fits_slot (row key; needs `slot`), slot, allowed_only,
## sort}, in the chosen order. Category "supplies" lists the raid shop's stock (make_supply_entries).
static func make_entries(filter: Dictionary, ctx: LoadoutContext, profile: OperatorProfile) -> Array:
	if str(filter.get("category", "")) == SUPPLIES:
		return make_supply_entries(filter)
	var out := []
	var kinds := _kinds_of(str(filter.get("category", "")))
	if filter.get("kinds") is Array and not (filter.kinds as Array).is_empty():
		kinds = kinds.filter(func(k: String) -> bool: return (filter.kinds as Array).has(k))
	for id in _make_candidate_ids(kinds):
		var e := make_entry(str(id), ctx, profile)
		if _is_wanted(e, filter):
			out.append(e)
	_apply_sort(out, str(filter.get("sort", SORT_NAME)))
	return out


static func make_entry(id: String, ctx: LoadoutContext, profile: OperatorProfile) -> Dictionary:
	var state := make_state(id, ctx, profile.unlocks)
	var reason := ctx.make_block_reason(id) if state == STATE_NOT_ALLOWED else ""
	var e := {"id": id, "kind": UnlockId.kind_of(id), "name": str(_labels.get(id, SlotCheck.make_name(id))), "pack": UnlockId.pack_of(id),
		"state": state, "price": make_price(id, state), "reason": reason, "detail": "", "tooltip_lines": [],
		"kg": 0.0, "slots": 0, "rating": 0.0, "shape_id": "", "skin_ids": []}
	_apply_details(e)
	e.tooltip_lines = make_tooltip_lines(e)
	return e


static func make_state(id: String, ctx: LoadoutContext, owned: Unlocks) -> String:
	if ctx.make_block_reason(id) != "":
		return STATE_NOT_ALLOWED
	if ctx.is_free(id) or not ctx.is_ownership_checked(UnlockId.kind_of(id)):
		return STATE_FREE
	if owned.owned.has(id):
		return STATE_OWNED
	if owned.is_lost(id):
		return STATE_LOST if ctx.loss_on_death else STATE_OWNED
	return STATE_FOR_SALE


## The credits `id` costs in `state`: the rebuy price when lost, the unlock price when for sale, else 0.
static func make_price(id: String, state: String) -> int:
	match state:
		STATE_LOST:
			return EconomyRules.rebuy_price()
		STATE_FOR_SALE:
			return make_unlock_price(id)
	return 0


static func make_unlock_price(id: String) -> int:
	var kind := UnlockId.kind_of(id)
	var base := make_base_price(id)
	return maxi(int(ceil(float(base) * EconomyRules.make_multiplier(kind) - 0.0001)), EconomyRules.min_price())


## The price before the kind's multiplier: a flat base, or the extraction catalog's rating-based price.
static func make_base_price(id: String) -> int:
	var kind := UnlockId.kind_of(id)
	var ref := UnlockId.ref_of(id)
	var flat := EconomyRules.make_flat_base(kind)
	if flat > 0:
		return flat
	match kind:
		"weapon", "gear", "pack":
			return ExtractionItems.make_price(id)
		"herc_weapon":
			return ExtractionItems.make_price(ExtractionItems.make_id("salvage", ref))
		"ammo":
			return ExtractionShop.make_buy_price(id)
		"armor":
			return EconomyRules.make_armor_base(str(InfantryCatalog.armor(ref).get("size", "light")))
		"vehicle":
			return ExtractionItems.make_rated_price(EconomyRules.vehicle_base_range(), Packs.combat_rating(Packs.vehicle(ref)))
	return 0


## True when `id` names something the installed packs have (a unit the store can sell).
static func is_known(id: String) -> bool:
	var ref := UnlockId.ref_of(id)
	match UnlockId.kind_of(id):
		"weapon", "ammo", "gear", "pack":
			return ExtractionItems.has(id)
		"herc_weapon":
			return ExtractionItems.has(ExtractionItems.make_id("salvage", ref))
		"armor":
			return not InfantryCatalog.armor(ref).is_empty()
		"vehicle":
			return not Packs.vehicle(ref).is_empty()
		"body", "skin", "herc_skin":
			return Assets.has_pack(UnlockId.pack_of(id)) and UnlockId.shape_of(id) != ""
	return false


static func make_tooltip_lines(e: Dictionary) -> Array:
	var lines := [str(e.name)]
	if str(e.pack) != "":
		lines.append(Packs.pack_name(str(e.pack)))
	if str(e.detail) != "":
		lines.append(str(e.detail))
	match str(e.state):
		STATE_FOR_SALE:
			lines.append("Price %s (first purchase)" % EconomyRules.make_money_text(int(e.price)))
		STATE_LOST:
			lines.append(str((EconomyRules.data().get("tooltips", {}) as Dictionary).get("lost", "%d")) % int(e.price))
		STATE_NOT_ALLOWED:
			lines.append(str((EconomyRules.data().get("tooltips", {}) as Dictionary).get("not_allowed", "%s")) % str(e.reason))
	return lines


# ------------------------------------------------------------------ raid supplies

## The raid shop's stock as entries for the "supplies" category (filter: pack, text, sort). Their ids are stash item ids
## (the string of an unlock id of the same kind, in another container), `stock` is true, the state is always "for_sale"
## and `price` is what one lot (`units`) costs; they go to the stash, not into the unlocks.
static func make_supply_entries(filter: Dictionary) -> Array:
	var out := []
	for kind in SUPPLY_KINDS:
		for r in ExtractionShop.make_offers(kind, str(filter.get("pack", ""))):
			var e := _make_supply_entry(str(r.id), r)
			if _is_wanted(e, filter):
				out.append(e)
	_apply_sort(out, str(filter.get("sort", SORT_NAME)))
	return out


static func _make_supply_entry(id: String, record: Dictionary) -> Dictionary:
	var units := ExtractionShop.make_buy_units(id)
	var price := ExtractionShop.make_buy_price(id)
	var e := {"id": id, "kind": ExtractionItems.kind_of(id), "name": ExtractionItems.make_stack_text(id, units),
		"pack": str(record.get("pack", "")), "state": STATE_FOR_SALE, "price": price, "reason": "", "detail": "",
		"tooltip_lines": [], "kg": float(record.get("kg", 0.0)) * units, "slots": 0, "rating": float(record.get("rating", 0.0)),
		"shape_id": "", "skin_ids": [], "stock": true, "units": units}
	e.tooltip_lines = [str(e.name), Packs.pack_name(str(e.pack)) if str(e.pack) != "" else "Any game",
		"Stock for the raid kit: lost with the kit if you die", "Price %s" % EconomyRules.make_money_text(price)]
	return e


# ------------------------------------------------------------------ candidates

static func _kinds_of(category: String) -> Array:
	for c in CATEGORIES:
		if c.id == category:
			return c.kinds
	return UnlockId.KINDS


static func _make_candidate_ids(kinds: Array) -> Array:
	var ids := []
	for kind in kinds:
		match str(kind):
			"weapon", "ammo", "gear", "pack":
				ids.append_array(ExtractionItems.items_of_kind(str(kind)).map(func(r: Dictionary) -> String: return UnlockId.make(str(kind), str(r.ref))))
			"herc_weapon":
				ids.append_array(ExtractionItems.items_of_kind("salvage").map(func(r: Dictionary) -> String: return UnlockId.make("herc_weapon", str(r.ref))))
			"armor":
				ids.append_array(_make_armor_ids())
			"vehicle":
				ids.append_array(Packs.pilotable().map(func(v: Dictionary) -> String: return UnlockId.make("vehicle", str(v.id))))
			"body", "skin":
				ids.append_array(_make_body_ids(str(kind)))
			"herc_skin":
				ids.append_array(_make_herc_skin_ids())
	return ids


static func _make_armor_ids() -> Array:
	var out := []
	for pack in InfantryCatalog.INFANTRY_PACKS:
		for a in InfantryCatalog.armors_of(pack):
			out.append(UnlockId.make("armor", str(a.id)))
	return out


## Body ids (kind "body") or skin ids (kind "skin") of every body some installed armour can wear.
static func _make_body_ids(kind: String) -> Array:
	var out := []
	var seen := {}
	for armor_id in _make_armor_ids().map(func(id: String) -> String: return UnlockId.ref_of(id)):
		for b in CatalogBridge.make_bodies(str(armor_id)):
			var shape := str(b.id)
			if seen.has(shape):
				continue
			seen[shape] = true
			if kind == "body":
				out.append(_make_labelled("body", shape, "%s (%s)" % [b.label, shape.get_slice(":", shape.count(":"))]))
			else:
				for s in CatalogBridge.make_skins(shape):
					if str(s.id) != "":
						out.append(_make_labelled("skin", UnlockId.make_skin_ref(shape, str(s.id)), "%s (%s)" % [s.label, shape.get_slice(":", shape.count(":"))]))
	return out


## An unlock id of `kind` and `ref`, remembering the readable name the catalogs gave it.
static func _make_labelled(kind: String, ref: String, label: String) -> String:
	var id := UnlockId.make(kind, ref)
	_labels[id] = label
	return id


static func _make_herc_skin_ids() -> Array:
	var out := []
	var seen := {}
	for v in Packs.pilotable():
		var shape := SkinCatalog.make_vehicle_shape(str(v.id))
		if seen.has(shape):
			continue
		seen[shape] = true
		for s in SkinCatalog.make_skin_choices(shape):
			if str(s.id) != "":
				out.append(_make_labelled("herc_skin", UnlockId.make_skin_ref(shape, str(s.id)), "%s (%s)" % [s.label, Packs.vehicle(str(v.id)).get("name", shape)]))
	return out


# ------------------------------------------------------------------ filtering

static func _apply_details(e: Dictionary) -> void:
	var ref := UnlockId.ref_of(str(e.id))
	match str(e.kind):
		"weapon", "ammo", "gear", "pack":
			var item := ExtractionItems.item(str(e.id))
			e.kg = float(item.get("kg", 0.0))
			e.rating = float(item.get("rating", 0.0))
			e.slots = 1 if str(e.kind) == "weapon" else 0
		"herc_weapon":
			e.rating = float(ExtractionItems.item(ExtractionItems.make_id("salvage", ref)).get("rating", 0.0))
		"vehicle":
			e.rating = Packs.combat_rating(Packs.vehicle(ref))
			e.shape_id = SkinCatalog.make_vehicle_shape(ref)
			e.skin_ids = SkinCatalog.make_vehicle_skin_choices(ref).map(func(s: Dictionary) -> String: return str(s.id))
		"armor":
			var a := InfantryCatalog.armor(ref)
			e.shape_id = str(a.get("shape", ""))
			e.slots = int(a.get("max_weapons", 0))
			e.detail = "%d weapons" % e.slots
		"body", "skin", "herc_skin":
			e.shape_id = UnlockId.shape_of(str(e.id))


static func _is_wanted(e: Dictionary, filter: Dictionary) -> bool:
	var pack := str(filter.get("pack", ""))
	var text := str(filter.get("text", "")).strip_edges().to_lower()
	if pack != "" and str(e.pack) != pack:
		return false
	if text != "" and not str(e.name).to_lower().contains(text):
		return false
	if bool(filter.get("owned_only", false)) and not OWNED_STATES.has(e.state):
		return false
	if bool(filter.get("allowed_only", false)) and e.state == STATE_NOT_ALLOWED:
		return false
	var row_key := str(filter.get("fits_slot", ""))
	return row_key == "" or not filter.get("slot") is CharacterSlot or LoadoutLayout.is_fit(filter.slot, row_key, UnlockId.make_part_of(str(e.id)))


static func _apply_sort(entries: Array, sort: String) -> void:
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		match sort:
			SORT_PRICE:
				if a.price != b.price:
					return a.price < b.price
			SORT_RATING:
				if not is_equal_approx(float(a.rating), float(b.rating)):
					return a.rating > b.rating
		return str(a.name) < str(b.name) or (a.name == b.name and str(a.id) < str(b.id)))

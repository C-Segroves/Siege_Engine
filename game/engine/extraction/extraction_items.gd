class_name ExtractionItems
extends RefCounted
## The extraction mode's item catalog, built from the installed packs (docs/design/extraction.md section 4):
##   weapon/<weapon id>    an infantry hand weapon (category "infantry"); price by its strength among its game's
##                         hand weapons (damage per second and range percentiles, CombatRating)
##   ammo/<weapon id>      rounds for a hand weapon that uses ammunition; a stack holds the largest armour load
##   gear/<item id>        grenades, mines and repair kits (InfantryGear hand items the remake models)
##   pack/<pack id>        backpacks the remake models
##   salvage/<weapon id>   a Herc weapon crate (category "herc"): heavy, sold for its rating-based price
##   valuable/<key>        the rules' trade goods (power cells, navigation computers, Cybrid cores)
##   callin/<vehicle id>   a call-in token for a pilotable vehicle; price by its combat rating
##   (free_weapons in the rules, the Tribes 1 Blaster: price 0, standard issue, see is_free_weapon)
##   armor/<armor id>      an infantry armour (InfantryCatalog): worn in a raid, dropped on death; light armours
##                         are standard issue (price 0: free, never stashed nor dropped, is_free_armor)
## Record: {id, kind, ref (the catalog id it stands for), name, pack, kg (per unit), stack (units per slot),
## price (per unit, credits), rating (0..1)}. Values are the remake's design (ExtractionRules), not original data.

const SEPARATOR := "/"
const KINDS := ["weapon", "ammo", "gear", "pack", "salvage", "valuable", "callin", "armor"]
const ARMOR_KIND := "armor"
const GEAR_KINDS := ["grenade", "concussion", "mine", "repair_kit"]
const GEAR_PRICE_RANK := {"grenade": 0.3, "concussion": 0.2, "mine": 0.6, "repair_kit": 1.0}
const MIN_AMMO_STACK := 10

static var _items := {}
static var _key := ""


## Item record by id ({} when unknown).
static func item(id: String) -> Dictionary:
	_ensure_built()
	return _items.get(id, {})


static func has(id: String) -> bool:
	return not item(id).is_empty()


## Every item of `kind`, optionally only those of `packs` (valuables belong to every pack), in id order.
static func items_of_kind(kind: String, packs: Array = []) -> Array:
	_ensure_built()
	var out := []
	for id in _sorted_ids():
		var r: Dictionary = _items[id]
		if r.kind == kind and (packs.is_empty() or str(r.pack) == "" or packs.has(r.pack)):
			out.append(r)
	return out


static func make_id(kind: String, ref: String) -> String:
	return kind + SEPARATOR + ref


static func kind_of(id: String) -> String:
	return id.get_slice(SEPARATOR, 0)


## The catalog id an item stands for (weapon id, gear id, vehicle id ...).
static func ref_of(id: String) -> String:
	return id.substr(id.find(SEPARATOR) + 1)


static func make_name(id: String) -> String:
	return str(item(id).get("name", id))


## Credits `units` of `id` cost when bought (a round of ammunition may cost a fraction of a credit).
static func make_price(id: String, units := 1) -> int:
	return int(ceil(float(item(id).get("price", 0)) * units - 0.0001))


## Credits `units` of `id` sell for (ExtractionRules sell_fraction of the price).
static func make_sell_price(id: String, units := 1) -> int:
	return int(floor(float(item(id).get("price", 0)) * units * float(ExtractionRules.data().get("sell_fraction", 0.5)) + 0.0001))


## "Disc Launcher", "Disc Launcher ammo x15".
static func make_stack_text(id: String, count: int) -> String:
	return make_name(id) if count == 1 else "%s x%d" % [make_name(id), count]


## Drops the cache (tests, pack reloads).
static func reload() -> void:
	_items.clear()
	_key = ""


# ------------------------------------------------------------------ building

static func _ensure_built() -> void:
	var key := "%d|%d|%s" % [Packs.vehicles.size(), Packs.weapons.size(), str(Packs.packs.keys())]
	if key == _key:
		return
	_key = key
	_items.clear()
	_add_hand_weapons()
	_add_gear()
	_add_salvage()
	_add_valuables()
	_add_callins()
	_add_armors()


static func _sorted_ids() -> Array:
	var ids := _items.keys()
	ids.sort()
	return ids


static func _add(kind: String, ref: String, fields: Dictionary) -> void:
	var rules := ExtractionRules.item_kind(kind)
	var r := {"id": make_id(kind, ref), "kind": kind, "ref": ref, "pack": "", "kg": float(rules.get("kg", 1.0)),
		"stack": maxi(int(rules.get("stack", 1)), 1), "rating": 0.5}
	r.merge(fields, true)
	if not r.has("price"):
		r["price"] = make_rated_price(rules.get("price", [0, 0]), float(r.rating))
	_items[r.id] = r


## A price inside [lo, hi] by `rating` (0 = weakest of its group, 1 = strongest).
static func make_rated_price(pair: Array, rating: float) -> int:
	if pair.size() < 2:
		return 0
	return int(round(lerpf(float(pair[0]), float(pair[1]), clampf(rating, 0.0, 1.0))))


static func _add_hand_weapons() -> void:
	var by_pack := {}
	for id in Packs.weapons:
		var w: Dictionary = Packs.weapons[id]
		if str(w.get("category", "")) == "infantry" and Packs.is_enabled(str(w.pack), "infantry_weapons"):
			if not by_pack.has(w.pack):
				by_pack[w.pack] = []
			by_pack[w.pack].append(w)
	for pack in by_pack:
		var ratings := make_group_ratings(by_pack[pack])
		for w in by_pack[pack]:
			var rating := float(ratings[w.id])
			var fields := {"name": str(w.get("display_name", w.name)), "pack": str(pack), "rating": rating}
			if is_free_weapon(str(w.id)):
				fields["price"] = 0
			elif make_weapon_override(str(w.id)).has("price"):
				fields["price"] = int(make_weapon_override(str(w.id)).price)
			_add("weapon", str(w.id), fields)
			_add_ammo(w, rating)


## {weapon id: 0..1}: the percentile mean of damage per second and range among `weapons` (CombatRating weights).
static func make_group_ratings(weapons: Array) -> Dictionary:
	var dps := []
	var ranges := []
	for w in weapons:
		var s := CombatRating.make_weapon_stats(w)
		dps.append(float(s.dps))
		ranges.append(float(s.range))
	dps.sort()
	ranges.sort()
	var out := {}
	for w in weapons:
		var s := CombatRating.make_weapon_stats(w)
		out[w.id] = CombatRating.WEAPON_WEIGHTS.dps * CombatRating.make_percentile(dps, float(s.dps)) \
			+ CombatRating.WEAPON_WEIGHTS.range * CombatRating.make_percentile(ranges, float(s.range))
	return out


## Rounds for weapon `w` when some armour carries ammunition for it; a stack is the largest armour load.
static func _add_ammo(w: Dictionary, rating: float) -> void:
	var load := make_full_load(str(w.id))
	if load <= 0:
		return
	var weapon_price := make_rated_price(ExtractionRules.item_kind("weapon").get("price", [0, 0]), rating)
	var fraction := float(ExtractionRules.item_kind("ammo").get("load_price_fraction", 0.1))
	_add("ammo", str(w.id), {"name": "%s ammo" % str(w.get("display_name", w.name)), "pack": str(w.pack),
		"stack": maxi(load, MIN_AMMO_STACK), "rating": rating,
		"kg": float(ExtractionRules.item_kind("ammo").get("load_kg", 1.0)) / float(load),
		"price": weapon_price * fraction / float(load)})


## The most rounds of `weapon_id` any installed armour carries (0: no armour uses ammunition for it).
static func make_full_load(weapon_id: String) -> int:
	var most := 0
	for pack in InfantryCatalog.INFANTRY_PACKS:
		for a in InfantryCatalog.armors_of(pack):
			most = maxi(most, int((a.get("ammo", {}) as Dictionary).get(weapon_id, 0)))
	return most


static func _add_gear() -> void:
	for r in InfantryGear.all_items():
		var kind := str(r.get("kind", ""))
		if bool(r.get("mapped", false)) and kind in GEAR_KINDS:
			_add("gear", str(r.id), {"name": str(r.get("name", r.id)), "pack": str(r.id).get_slice(":", 0),
				"rating": float(GEAR_PRICE_RANK.get(kind, 0.5))})
	for r in InfantryGear.all_packs():
		if bool(r.get("mapped", false)):
			_add("pack", str(r.id), {"name": str(r.get("name", r.id)), "pack": str(r.id).get_slice(":", 0)})


static func _add_salvage() -> void:
	for id in Packs.weapons:
		var w: Dictionary = Packs.weapons[id]
		if str(w.get("category", "herc")) == "herc" and Packs.is_enabled(str(w.pack), "herc_weapons"):
			_add("salvage", str(id), {"name": "%s (salvage)" % str(w.get("display_name", w.name)), "pack": str(w.pack),
				"rating": Packs.weapon_rating(w)})


static func _add_valuables() -> void:
	for v in ExtractionRules.data().get("valuables", []):
		_add("valuable", str(v.key), {"name": str(v.name), "kg": float(v.get("kg", 1.0)), "stack": int(v.get("stack", 1)),
			"price": int(v.get("price", 0)), "cybrid_only": bool(v.get("cybrid_only", false)), "task_only": bool(v.get("task_only", false))})


static func _add_callins() -> void:
	for v in Packs.pilotable():
		_add("callin", str(v.id), {"name": "Call-in: %s" % str(v.get("name", v.id)), "pack": str(v.pack),
			"rating": Packs.combat_rating(v)})


static func _add_armors() -> void:
	var rules := ExtractionRules.item_kind(ARMOR_KIND)
	for pack in InfantryCatalog.INFANTRY_PACKS:
		for a in InfantryCatalog.armors_of(pack):
			var size := str(a.get("size", "light"))
			_add(ARMOR_KIND, str(a.id), {"name": "%s (%s)" % [str(a.get("name", a.id)), Packs.pack_name(pack)], "pack": pack,
				"kg": float((rules.get("kg_by_size", {}) as Dictionary).get(size, 10.0)),
				"price": int((rules.get("price_by_size", {}) as Dictionary).get(size, 0))})


## True for the rules' standard-issue weapons (free_weapons: the Tribes 1 Blaster, playtest X5): price 0, given to a
## raider who brings no weapon, never rolled as loot nor left in a bag.
static func is_free_weapon(weapon_id: String) -> bool:
	return (ExtractionRules.data().get("free_weapons", []) as Array).has(weapon_id)


## The rules' raid tuning of hand weapon `weapon_id` ({} = none): {damage_scale, refire_scale, price}.
static func make_weapon_override(weapon_id: String) -> Dictionary:
	var o = (ExtractionRules.data().get("weapon_overrides", {}) as Dictionary).get(weapon_id, {})
	return o if o is Dictionary else {}


## True for standard issue (a free weapon or free armour): items worth nothing that every raider may have.
static func is_standard_issue(id: String) -> bool:
	match kind_of(id):
		"weapon":
			return is_free_weapon(ref_of(id))
		ARMOR_KIND:
			return is_free_armor(ref_of(id))
	return false


## The item id of armour `armor_id`.
static func make_armor_id(armor_id: String) -> String:
	return make_id(ARMOR_KIND, armor_id)


## True for standard-issue armour (price 0): worn for free, never stashed, sold or dropped.
static func is_free_armor(armor_id: String) -> bool:
	return int(item(make_armor_id(armor_id)).get("price", 0)) <= 0

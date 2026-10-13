class_name CampaignAvailability
extends RefCounted
## Which Hercs, tanks and weapons a campaign lets the player field
## (docs/formats/campaign_availability.md §2, §3). Every campaign selection UI asks this class.
##
## An availability context is a Dictionary built by the campaign provider (availability_context()):
##   native_pack        pack whose campaign is running ("es1", "es2", "starsiege")
##   side               "herc" (default) or "cybrid": the side the player fights for
##   era                timeline position of the campaign (default Packs.era(native_pack))
##   unlocked_vehicles  native vehicle ids unlocked so far
##   unlocked_weapons   native weapon ids unlocked so far (unlimited); racks by base id ("es1:MLRS6")
##   salvage_stock      {weapon id: count} counted stock (salvage, awards); shared with the career
##   carried_vehicles / carried_weapons   saga carry-over from earlier stages (count as earlier era)
##   mission_vehicles   vehicles the current mission hands the player (always offered)
##   cybrid_weapons_on_hercs  Cybrid-only weapons allowed on Hercs and tanks (by hardpoint size)
## The empty context {} means no limits on Hercs and weapons (arena / skirmish / versus / co-op
## skirmish); make_open_context(mode) adds the match mode's cybrid_weapons_on_hercs rule (§2:
## arena, versus and skirmish allow them, campaign and co-op keep Cybrid weapons on Cybrids).

const UNLIMITED := -1
const REASON_UNLOCKED := "unlocked"
const REASON_OLDER := "older design"
const REASON_EQUIVALENT := "equivalent to %s"
const REASON_CARRIED := "carried over"
const REASON_MISSION := "mission Herc"
const REASON_STOCK := "in stock"
const SIDE_HERC := "herc"
const SIDE_CYBRID := "cybrid"
const CYBRID_RULE := WeaponFit.RULE_CYBRID_WEAPONS_ON_HERCS
## Match modes whose Hercs may mount Cybrid-only weapons (campaign_availability.md §2).
const CYBRID_WEAPON_MODES := ["arena", "skirmish", "vs", "versus"]
const HERC_CATEGORY := "herc"
## Vehicle families a player may field (Hercs, tanks, Tribes vehicles); infantry armors are not vehicles.
const FIELDED_CATEGORIES := ["herc", "vehicle"]
## Missile guidance suffixes: a rack's stock and unlocks are kept under its base id.
const GUIDANCE_SUFFIXES := ["_SARH", "_ARH", "_ARM", "_EO"]
## Ratings this close count as equal ("more or less equivalent").
const RATING_TOLERANCE := 0.02


## A restricted context for a campaign of `native_pack` with nothing unlocked yet.
static func make_context(native_pack: String, side := SIDE_HERC) -> Dictionary:
	return {"native_pack": native_pack, "side": side, "era": Packs.era(native_pack),
		"unlocked_vehicles": [], "unlocked_weapons": [], "salvage_stock": {},
		"carried_vehicles": [], "carried_weapons": [], "mission_vehicles": []}


## Unrestricted context for a match mode ("skirmish", "vs", "coop", "campaign" ...).
static func make_open_context(mode: String) -> Dictionary:
	return {CYBRID_RULE: CYBRID_WEAPON_MODES.has(mode)}


## True when a vehicle of `side` may mount Cybrid-only weapons under `ctx` (the context doubles as
## the WeaponFit rules dictionary: same key).
static func allows_cybrid_weapons(ctx: Dictionary, side: String) -> bool:
	return WeaponFit.allows_cybrid_weapons({"side": side}, ctx)


static func is_restricted(ctx: Dictionary) -> bool:
	return ctx.has("native_pack")


## "es1:MLRS6_SARH" -> "es1:MLRS6"; other ids unchanged.
static func base_weapon(wid: String) -> String:
	for suffix in GUIDANCE_SUFFIXES:
		if wid.ends_with(suffix):
			return wid.substr(0, wid.length() - str(suffix).length())
	return wid


# ------------------------------------------------------------------ vehicles

## Vehicles the player may field: [{vehicle, reason}], native first, then by era and mass.
static func offered_vehicles(ctx: Dictionary) -> Array:
	var out: Array = []
	var reference := _make_vehicle_reference(ctx)
	for v in Packs.pilotable([], str(ctx.get("side", ""))):
		if not FIELDED_CATEGORIES.has(str(v.get("category", HERC_CATEGORY))):
			continue
		var reason := make_vehicle_reason(ctx, v, reference)
		if reason != "":
			out.append({"vehicle": v, "reason": reason})
	if is_restricted(ctx):
		out.sort_custom(func(a, b): return _make_vehicle_order(ctx, a.vehicle) < _make_vehicle_order(ctx, b.vehicle))
	return out


## Why `v` is offered ("" = not offered). `reference` from _make_vehicle_reference (built when empty).
static func make_vehicle_reason(ctx: Dictionary, v: Dictionary, reference := {}) -> String:
	if not is_restricted(ctx):
		return REASON_UNLOCKED
	var id := str(v.get("id", ""))
	if (ctx.get("mission_vehicles", []) as Array).has(id):
		return REASON_MISSION
	if (ctx.get("unlocked_vehicles", []) as Array).has(id):
		return REASON_UNLOCKED
	if (ctx.get("carried_vehicles", []) as Array).has(id):
		return REASON_CARRIED
	var pack := str(v.get("pack", ""))
	if pack == str(ctx.native_pack):
		return ""
	if Packs.era(pack) < int(ctx.get("era", Packs.era(str(ctx.native_pack)))):
		return REASON_OLDER
	if reference.is_empty():
		reference = _make_vehicle_reference(ctx)
	return _make_equivalent_reason(reference, CombatRating.vehicle_kind(v), Packs.combat_rating(v))


static func is_vehicle_offered(ctx: Dictionary, vid: String) -> bool:
	var v := Packs.vehicle(vid)
	return not v.is_empty() and make_vehicle_reason(ctx, v) != ""


## Native unlocked (and carried) vehicles by kind: {kind: [[rating, name], ...]} sorted by rating.
## Tanks fall back to the Herc list when the campaign has no tanks of its own (tanks stay available).
static func _make_vehicle_reference(ctx: Dictionary) -> Dictionary:
	var ref := {}
	if not is_restricted(ctx):
		return ref
	for id in (ctx.get("unlocked_vehicles", []) as Array) + (ctx.get("carried_vehicles", []) as Array):
		var v := Packs.vehicle(str(id))
		if not v.is_empty():
			_append_rated(ref, CombatRating.vehicle_kind(v), Packs.combat_rating(v), str(v.get("name", id)))
	if not ref.has(CombatRating.KIND_TANK) and ref.has(CombatRating.KIND_HERC):
		ref[CombatRating.KIND_TANK] = ref[CombatRating.KIND_HERC]
	return ref


static func _make_vehicle_order(ctx: Dictionary, v: Dictionary) -> Array:
	var native := 0 if str(v.pack) == str(ctx.native_pack) else 1
	return [native, Packs.era(str(v.pack)), str(v.pack), CombatRating.vehicle_kind(v), float(v.get("mass", 0.0))]


# ------------------------------------------------------------------ weapons

## Herc weapons the player may mount: [{weapon, count, reason}] (count UNLIMITED or stock left).
static func offered_weapons(ctx: Dictionary) -> Array:
	var out: Array = []
	var reference := _make_weapon_reference(ctx)
	for id in Packs.weapons:
		var w: Dictionary = Packs.weapons[id]
		if not _is_herc_weapon_for(ctx, w):
			continue
		var count := make_weapon_count(ctx, str(id), reference)
		if count != 0:
			out.append({"weapon": w, "count": count, "reason": make_weapon_reason(ctx, str(id), reference)})
	out.sort_custom(func(a, b): return str(a.weapon.id) < str(b.weapon.id))
	return out


## Units of `wid` available: UNLIMITED, the counted stock, or 0 (not offered).
static func make_weapon_count(ctx: Dictionary, wid: String, reference := {}) -> int:
	var reason := make_weapon_reason(ctx, wid, reference)
	if reason == "":
		return 0
	if reason == REASON_STOCK:
		return int(ctx.salvage_stock.get(base_weapon(wid), 0))
	return UNLIMITED


## Why `wid` is offered: unlocked / older design / equivalent to X / carried over / salvaged ("" = not).
static func make_weapon_reason(ctx: Dictionary, wid: String, reference := {}) -> String:
	if not is_restricted(ctx):
		return REASON_UNLOCKED
	var base := base_weapon(wid)
	if (ctx.get("unlocked_weapons", []) as Array).has(base):
		return REASON_UNLOCKED
	if (ctx.get("carried_weapons", []) as Array).has(base):
		return REASON_CARRIED
	var timeline := _make_foreign_weapon_reason(ctx, Packs.weapon(wid), reference)
	if timeline != "":
		return timeline
	return REASON_STOCK if int(ctx.get("salvage_stock", {}).get(base, 0)) > 0 else ""


static func _make_foreign_weapon_reason(ctx: Dictionary, w: Dictionary, reference: Dictionary) -> String:
	var pack := str(w.get("pack", ""))
	if w.is_empty() or pack == str(ctx.native_pack):
		return ""
	if Packs.era(pack) < int(ctx.get("era", Packs.era(str(ctx.native_pack)))):
		return REASON_OLDER
	if reference.is_empty():
		reference = _make_weapon_reference(ctx)
	return _make_equivalent_reason(reference, Packs.weapon_family(w), Packs.weapon_rating(w))


## True when weapon `wid` may sit on a hardpoint while `in_use` other hardpoints already hold it.
static func can_mount(ctx: Dictionary, wid: String, in_use: int) -> bool:
	if wid == "":
		return true
	var count := make_weapon_count(ctx, wid)
	return count == UNLIMITED or count > in_use


## Of the hardpoint `choices` (weapon ids, "" = empty), the ones the context offers.
static func filter_choices(ctx: Dictionary, choices: Array) -> Array:
	if not is_restricted(ctx):
		return choices.duplicate()
	var reference := _make_weapon_reference(ctx)
	return choices.filter(func(wid): return str(wid) == "" or make_weapon_count(ctx, str(wid), reference) != 0)


## Native unlocked (and carried) weapons by family: {family: [[rating, name], ...]} sorted by rating.
static func _make_weapon_reference(ctx: Dictionary) -> Dictionary:
	var ref := {}
	if not is_restricted(ctx):
		return ref
	for base in (ctx.get("unlocked_weapons", []) as Array) + (ctx.get("carried_weapons", []) as Array):
		for w in _weapons_with_base(str(base)):
			_append_rated(ref, Packs.weapon_family(w), Packs.weapon_rating(w), str(w.get("display_name", w.get("name", base))))
	return ref


static func _weapons_with_base(base: String) -> Array:
	var w := Packs.weapon(base)
	if not w.is_empty():
		return [w]
	var out: Array = []
	for suffix in GUIDANCE_SUFFIXES:
		var variant := Packs.weapon(base + str(suffix))
		if not variant.is_empty():
			out.append(variant)
	return out


static func _is_herc_weapon_for(ctx: Dictionary, w: Dictionary) -> bool:
	if str(w.get("category", HERC_CATEGORY)) != HERC_CATEGORY or not Packs.is_enabled(str(w.pack), "herc_weapons"):
		return false
	return not w.get("cybrid_only", false) or allows_cybrid_weapons(ctx, str(ctx.get("side", SIDE_HERC)))


# ------------------------------------------------------------------ stock (salvage)

## Adds salvaged weapons (ids, one unit each) to a stock dictionary.
static func apply_salvage(stock: Dictionary, weapon_ids: Array) -> void:
	for wid in weapon_ids:
		var base := base_weapon(str(wid))
		if base != "" and not Packs.weapon(str(wid)).is_empty():
			stock[base] = int(stock.get(base, 0)) + 1


## Hardpoint change from `old_wid` to `new_wid` ("" = empty): a counted weapon taken off goes back
## to the stock, a counted weapon put on uses one unit. Unlimited weapons leave the stock alone.
static func apply_arming(ctx: Dictionary, old_wid: String, new_wid: String) -> void:
	if not is_restricted(ctx) or base_weapon(old_wid) == base_weapon(new_wid):
		return
	var stock: Dictionary = ctx.salvage_stock
	if old_wid != "" and _is_counted(ctx, old_wid):
		stock[base_weapon(old_wid)] = int(stock.get(base_weapon(old_wid), 0)) + 1
	if new_wid != "" and _is_counted(ctx, new_wid):
		stock[base_weapon(new_wid)] = maxi(0, int(stock.get(base_weapon(new_wid), 0)) - 1)


static func _is_counted(ctx: Dictionary, wid: String) -> bool:
	var reason := make_weapon_reason(ctx, wid)
	return reason == REASON_STOCK or reason == ""


## Short count label: "" when unlimited, else "x<n>".
static func make_count_label(count: int) -> String:
	return "" if count == UNLIMITED else "x%d" % count


# ------------------------------------------------------------------ equivalence

static func _append_rated(ref: Dictionary, key: String, rating: float, name: String) -> void:
	if not ref.has(key):
		ref[key] = []
	ref[key].append([rating, name])
	(ref[key] as Array).sort_custom(func(a, b): return a[0] < b[0])


## "equivalent to <the weakest native item at least as strong>" or "" when stronger than them all.
static func _make_equivalent_reason(reference: Dictionary, key: String, rating: float) -> String:
	for entry in reference.get(key, []):
		if rating <= float(entry[0]) + RATING_TOLERANCE:
			return REASON_EQUIVALENT % str(entry[1])
	return ""


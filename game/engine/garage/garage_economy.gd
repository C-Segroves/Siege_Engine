class_name GarageEconomy
extends RefCounted
## A campaign's salvage economy (docs/formats/campaign_availability.md section 7): what Hercs and
## weapons cost, what repairs cost, what wrecks are worth. Money is salvage in kilograms (the shells
## show it / 1000 as tons). Data: <pack>/gameplay/economy.json (tools/export_economy.py) - Earthsiege
## from GO.EXE and CFG/DAMAGE.DAT, Earthsiege 2 from SHELL0/GAM HERC_INF / DAMAGE / WEAPONS.DAT. A game
## without the file has no economy (Starsiege: inventories only): everything is free (is_enabled()).
##
## Repair (VSHELL 0x413628 / 0x4139f7, GO.EXE 0x387ac): every Herc type has six armour-part costs and
## nine system costs, cost = fixmul(factor, fixmul(weight, price)), fixmul(a, b) = a * b >> 10; every
## weapon a repair cost fixmul(weapon factor, cost). Bringing a part from c % to t % costs
## (t - c) * cost / 100. Parts = the 13 armour components grouped (armour_parts, their average).
## Remake approximation: systems are not simulated, so each system's condition is the mean armour
## condition; a remake weapon component has one hit point, so a "destroyed" weapon is repaired from
## 0 % instead of being lost.
## Vehicles and weapons missing from the game's tables (another game's, Cybrids) are priced by their
## combat rating inside the table's price range.

const FILE := "gameplay/economy.json"
const KG_PER_TON := 1000
const PERCENT := 100.0
## The originals' fixed-point multiply (VSHELL 0x450a84: a * b >> 10).
const FIXED_SHIFT := 10
## Destroyed enemies' wreck value scale (DBSIM results.dat 0x4241d0: fixmul(2500, sum of values)).
const WRECK_SALVAGE_SCALE := 2500
## A wreck without its cockpit is worth half (DBSIM 0x418f12).
const COCKPIT_LOST_FACTOR := 0.5
## Unit tables holding the value word (Earthsiege units "threat_value", tools/units.py DAT 0x52).
const UNIT_TABLE := "gameplay/hercs.json"
## Value of a unit type without one (the Earthsiege Hercs' 1024).
const DEFAULT_UNIT_VALUE := 1024
## Earthsiege 2 mission var 20 pays a bonus per point (DBSIM 0x4241df: var20 x 25000 kg); the
## campaign scripts raise it when structures and groups are destroyed.
const BONUS_VAR := 20
const BONUS_PER_POINT_KG := 25000
## Weapons at or above this condition are kept when a Herc is scrapped, the rest are sold
## (VSHELL 0x413b50 values weapons below 80 %).
const KEEP_WEAPON_FRACTION := 0.8
const WEAPON_COMPONENT := "WEAPON %d"

var pack := ""
var _data := {}

static var _cache := {}
static var _unit_values := {}


## The economy of `p_pack`'s campaign (disabled when the game has no economy table).
static func make_for_pack(p_pack: String) -> GarageEconomy:
	if not _cache.has(p_pack):
		var e := GarageEconomy.new()
		e.pack = p_pack
		var j = Assets.load_json(FILE, p_pack) if p_pack != "" else null
		e._data = j if j is Dictionary else {}
		_cache[p_pack] = e
	return _cache[p_pack]


## The economy carried by an availability context (a disabled one when it has none).
static func of_context(ctx: Dictionary) -> GarageEconomy:
	var e = ctx.get("economy")
	return e if e is GarageEconomy else make_for_pack("")


func is_enabled() -> bool:
	return not _data.is_empty()


static func fixmul(a: int, b: int) -> int:
	return (a * b) >> FIXED_SHIFT


static func make_tons_text(kg: int) -> String:
	return "%d t" % int(floor(kg / float(KG_PER_TON)))


# ------------------------------------------------------------------ campaign data

## New-campaign salvage: base + rand(steps) x step (Earthsiege 2: 100000 + rand(11) x 1000 kg).
func make_start_pool(seed: int) -> int:
	var p: Dictionary = _data.get("start_pool", {})
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var steps := int(p.get("random_steps", 0))
	return int(p.get("base_kg", 0)) + (rng.randi_range(0, steps - 1) * int(p.get("step_kg", 0)) if steps > 0 else 0)


## The pilot roster: one name chain per crew slot (pilot, replacement 1, replacement 2).
func make_pilot_names() -> Array:
	return _data.get("pilots", [])


## Wingmen a squad may take (both games: 3, the three wingman windows / squad.h).
func make_squad_max() -> int:
	return int(_data.get("squad_max", 0))


## The campaign's starting weapon inventory: {base weapon id: units} (Earthsiege 2 WEAPONS.DAT tail).
func make_start_weapons() -> Dictionary:
	var out := {}
	for w in _data.get("start_weapons", []):
		var wid := CampaignAvailability.base_weapon(str(w.get("weapon", "")))
		if is_known_weapon(wid):
			out[wid] = int(out.get(wid, 0)) + 1
	return out


## True when the catalog has weapon `base` (a missile rack under any of its guidance variants).
static func is_known_weapon(base: String) -> bool:
	if not Packs.weapon(base).is_empty():
		return true
	return CampaignAvailability.GUIDANCE_SUFFIXES.any(func(s): return not Packs.weapon(base + str(s)).is_empty())


## Herc types the shell offers from the start (HERC_INF.DAT available flag); [] when not recorded.
func make_start_vehicles() -> Array:
	return _make_available(_data.get("hercs", {}))


## Weapons the shell may fabricate from the start (WEAPONS.DAT available flag).
func make_start_weapon_ids() -> Array:
	return _make_available(_data.get("weapons", {}))


static func _make_available(table: Dictionary) -> Array:
	return table.keys().filter(func(id): return bool(table[id].get("available", false)))


func make_write_off_fraction() -> float:
	return float(_data.get("repair", {}).get("write_off_percent", 0)) / PERCENT


## Repair targets the shells offer (percent: 100, 90, 80, 60, 30).
func make_repair_levels() -> Array:
	return (_data.get("repair", {}).get("levels", [PERCENT]) as Array).filter(func(l): return int(l) > 1)


# ------------------------------------------------------------------ prices

## Price of building a Herc of type `vid`, kg (0 = free).
func make_vehicle_price(vid: String) -> int:
	return _make_table_price(_data.get("hercs", {}), vid, Packs.combat_rating(Packs.vehicle(vid)))


## Missions a new Herc of type `vid` takes to build (0 = ready at once).
func make_build_missions(vid: String) -> int:
	var row = _data.get("hercs", {}).get(vid)
	return int(row.get("build_missions", 0)) if row is Dictionary else 0


## Fabrication price of a weapon, kg (0 = the game does not fabricate weapons).
func make_weapon_price(wid: String) -> int:
	var w := Packs.weapon(wid)
	return _make_table_price(_data.get("weapons", {}), CampaignAvailability.base_weapon(wid), Packs.weapon_rating(w))


## A table's price for `id`, else one interpolated by `rating` (0..1) inside the table's range.
static func _make_table_price(table: Dictionary, id: String, rating: float) -> int:
	if table.is_empty():
		return 0
	var row = table.get(id)
	if row is Dictionary:
		return int(row.get("price_kg", 0))
	var prices: Array = table.values().map(func(r): return int(r.get("price_kg", 0))).filter(func(p): return p > 0)
	if prices.is_empty():
		return 0
	var tons := lerpf(float(prices.min()), float(prices.max()), clampf(rating, 0.0, 1.0)) / KG_PER_TON
	return roundi(tons) * KG_PER_TON


# ------------------------------------------------------------------ repair

## Salvage it takes to bring garage entry `e` to `target` (0..1) everywhere.
func make_repair_cost(e: Dictionary, target := 1.0) -> int:
	if not is_enabled():
		return 0
	var target_pc := roundi(target * PERCENT)
	var cost := 0
	for part in make_parts(e):
		cost += maxi(0, target_pc - int(part.percent)) * int(part.cost) / int(PERCENT)
	return cost


## What scrapping `e` brings (VSHELL 0x413b50): its parts' worth at their condition, plus the weapons
## too worn to keep.
func make_scrap_value(e: Dictionary) -> int:
	if not is_enabled():
		return 0
	var value := 0
	for part in make_parts(e):
		if part.kind != "weapon" or float(part.percent) < KEEP_WEAPON_FRACTION * PERCENT:
			value += int(part.percent) * int(part.cost) / int(PERCENT)
	return value


## Salvage from a destroyed enemy (DBSIM 0x418e60, summed into results.dat by 0x4241d0): the unit
## type's value word (DAT 0x52, "threat_value": Mongoose 600 .. Hyperion 2000, Hercs 1024) times the
## wreck's remaining health (0..1), halved when its first component (the cockpit) is gone, times
## 2500 / 1024. A few hundred kilograms a kill; the mission's var 20 bonus pays more.
## Approximation: the health function 0x41537c is taken as the hit-point weighted integrity.
static func make_wreck_salvage(vid: String, condition: Array) -> int:
	var value := float(make_unit_value(vid)) * HercCondition.make_integrity(vid, condition)
	if not condition.is_empty() and float(condition[0]) <= 0.0:
		value *= COCKPIT_LOST_FACTOR
	return fixmul(WRECK_SALVAGE_SCALE, roundi(value))


## A unit type's salvage value word (DAT 0x52; DEFAULT_UNIT_VALUE for other games' vehicles).
static func make_unit_value(vid: String) -> int:
	var pack := vid.get_slice(":", 0)
	if not _unit_values.has(pack):
		var j = Assets.load_json(UNIT_TABLE, pack)
		_unit_values[pack] = j if j is Dictionary else {}
	var row = _unit_values[pack].get(vid.get_slice(":", 1))
	return int(row.get("threat_value", DEFAULT_UNIT_VALUE)) if row is Dictionary and row.get("threat_value") != null else DEFAULT_UNIT_VALUE


## The repairable parts of `e`: [{kind, name, percent, cost}] - six armour parts, nine systems and
## one per mounted weapon (Earthsiege layout); vehicles without it are one armour part.
func make_parts(e: Dictionary) -> Array:
	var vid := str(e.get("vehicle", ""))
	var r: Dictionary = _data.get("repair", {})
	var price := make_vehicle_price(vid)
	var fractions := HercCondition.make_fractions(vid, e.get("condition", []))
	var defs := HercCondition.make_component_defs(vid)
	var armour := _make_armour_percents(defs, fractions, r.get("armour_parts", []))
	var parts: Array = []
	var weights: Array = r.get("armour_weights", [])
	for i in weights.size():
		parts.append({"kind": "armour", "name": "armour %d" % (i + 1), "percent": armour[i % armour.size()],
			"cost": fixmul(int(r.get("factor", 0)), fixmul(int(weights[i]), price))})
	var mean := roundi(armour.reduce(func(a, b): return a + b, 0) / float(armour.size()))
	for i in (r.get("system_weights", []) as Array).size():
		parts.append({"kind": "system", "name": "system %d" % (i + 1), "percent": mean,
			"cost": fixmul(int(r.get("factor", 0)), fixmul(int(r.get("system_weights")[i]), price))})
	parts.append_array(_make_weapon_parts(e, defs, fractions, mean))
	return parts


## Percent per armour part: the average of its components ([integrity] when the vehicle lacks them).
static func _make_armour_percents(defs: Array, fractions: Array, groups: Array) -> Array:
	var by_index := {}
	for i in defs.size():
		by_index[int(defs[i].get("index", i))] = float(fractions[i])
	var out: Array = []
	for g in groups:
		var have: Array = (g as Array).filter(func(ci): return by_index.has(int(ci)))
		if have.is_empty():
			continue
		out.append(roundi(have.reduce(func(a, ci): return a + by_index[int(ci)], 0.0) / have.size() * PERCENT))
	if out.is_empty():
		var hp_total := 0.0
		var hp_left := 0.0
		for i in defs.size():
			hp_total += float(defs[i].get("hp", 1.0))
			hp_left += float(defs[i].get("hp", 1.0)) * float(fractions[i])
		out.append(roundi(hp_left / maxf(hp_total, 1.0) * PERCENT))
	return out


func _make_weapon_parts(e: Dictionary, defs: Array, fractions: Array, fallback: int) -> Array:
	var r: Dictionary = _data.get("repair", {})
	var guns: Array = Packs.vehicle(str(e.get("vehicle", ""))).get("guns", [])
	var out: Array = []
	var loadout: Array = e.get("loadout", [])
	for i in loadout.size():
		var wid := str(loadout[i])
		if wid == "":
			continue
		var slot := int(guns[i].get("loadout_slot", i)) if i < guns.size() else i
		var ci := _find_component(defs, WEAPON_COMPONENT % (slot + 1))
		var pc := roundi(float(fractions[ci]) * PERCENT) if ci >= 0 else fallback
		var base_cost := _make_table_cost(r.get("weapon_costs", {}), CampaignAvailability.base_weapon(wid), Packs.weapon_rating(Packs.weapon(wid)))
		out.append({"kind": "weapon", "name": wid, "percent": pc, "cost": fixmul(int(r.get("weapon_factor", 0)), base_cost)})
	return out


static func _make_table_cost(table: Dictionary, id: String, rating: float) -> int:
	if table.has(id):
		return int(table[id])
	var costs: Array = table.values().map(func(c): return int(c)).filter(func(c): return c > 0)
	return roundi(lerpf(float(costs.min()), float(costs.max()), clampf(rating, 0.0, 1.0))) if not costs.is_empty() else 0


static func _find_component(defs: Array, component_name: String) -> int:
	for i in defs.size():
		if str(defs[i].get("name", "")) == component_name:
			return i
	return -1

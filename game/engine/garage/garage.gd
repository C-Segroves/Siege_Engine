class_name Garage
extends RefCounted
## A campaign's persistent hangar, the same for every game (docs/formats/campaign_availability.md
## sections 6-8): the Hercs the player owns with their loadouts, condition and pilots, the one selected
## for the next mission, the armory stock of counted weapons, the salvage pool and the crew.
##
##   vehicles   [{uid, vehicle, name, loadout, pilot_id, condition, build_left}]  vehicle = qualified id
##              ("es1:RAPTOR"); loadout = weapon id per hardpoint in the vehicle's gun order ("" =
##              empty); pilot_id = the crew pilot flying it ("" = none, or the player); condition =
##              HercCondition fractions ([] = pristine); build_left = missions until it is built
##   selected   index of the Herc the player takes into the next mission
##   stock      {base weapon id: units in the armory}; counted weapons only (salvage, start stock)
##   salvage_kg the salvage pool (kg) that pays for building, repairing and fabricating
##   crew       the pilot roster (Crew); squad / squad_auto: the wingmen chosen (SquadRoster)
##   last_report  the last mission's outcome for the garage (GarageReport summary)
##
## Build / scrap / arm / repair take the campaign's availability context (CampaignAvailability). Its
## `salvage_stock` is the armory these draw from: the provider passes this garage's `stock` (Earthsiege,
## Earthsiege 2) or a view of its own inventory (Starsiege: inventory minus what is mounted), so arming
## a counted weapon uses a unit and unarming or scrapping returns it. Unlimited weapons never touch it,
## except where the game fabricates weapons for salvage (Earthsiege 2): then a weapon put on is taken
## from the armory or paid for, and one taken off goes into the armory. Its `economy` (GarageEconomy)
## prices everything; without one everything is free.
## Campaign providers own their garage and seed it (Es1Tech, Es2Tech, SSInventory); the saga merges a
## finished stage's garage into the next one's.

const MAX_VEHICLES := 16
const EMPTY := ""

var vehicles: Array = []
var selected := 0
var stock := {}
var salvage_kg := 0
var crew := Crew.new()
var squad: Array = []            ## uids of the Hercs chosen as wingmen (SquadRoster)
var squad_auto := true           ## true until the player picks the wingmen: the first eligible fly
var last_report := {}            ## the last mission's GarageReport summary (shown in the hangar)
var _next_uid := 1


## A garage holding `entries` (see make_entry) and `p_stock`.
static func make(entries: Array, p_stock: Dictionary) -> Garage:
	var g := Garage.new()
	g.vehicles = entries
	g.stock = p_stock
	g._apply_sanitize()
	return g


## One owned Herc: vehicle `vid` with `loadout` (fitted to its hardpoint count; [] = all empty). A
## fixed-loadout vehicle always holds its standard weapons.
static func make_entry(vid: String, loadout: Array = []) -> Dictionary:
	var v := Packs.vehicle(vid)
	var lo := (v.get("loadout", []) as Array).duplicate() if PackVehicleLoader.has_fixed_loadout(v) else loadout.duplicate()
	lo.resize(WeaponFit.hardpoint_masks(v).size())
	for i in lo.size():
		lo[i] = str(lo[i]) if lo[i] != null and Packs.weapons.has(str(lo[i])) else EMPTY
	return {"uid": 0, "vehicle": str(v.get("id", vid)), "name": str(v.get("name", vid)), "loadout": lo,
		"pilot_id": "", "condition": [], "build_left": 0}


## `names`: the campaign's pilot name chains (GarageEconomy.make_pilot_names) for the saved crew.
static func from_dict(d: Dictionary, names: Array = []) -> Garage:
	var saved_stock: Dictionary = d.get("stock", {}) if d.get("stock") is Dictionary else {}
	var counts := {}
	for wid in saved_stock:
		counts[str(wid)] = int(saved_stock[wid])   # JSON numbers come back as floats
	var g := make((d.get("vehicles", []) as Array).duplicate(true) if d.get("vehicles") is Array else [], counts)
	g.selected = clampi(int(d.get("selected", 0)), 0, maxi(g.vehicles.size() - 1, 0))
	g.salvage_kg = int(d.get("salvage_kg", 0))
	g.crew = Crew.from_dict(d.get("crew", {}) if d.get("crew") is Dictionary else {}, names)
	g.squad = (d.get("squad", []) as Array).map(func(u): return int(u)) if d.get("squad") is Array else []
	g.squad_auto = bool(d.get("squad_auto", true))
	g.last_report = (d.get("last_report", {}) as Dictionary).duplicate(true) if d.get("last_report") is Dictionary else {}
	return g


## A saved garage of a campaign with `economy`; saves from before the economy start with the
## campaign's start pool (`seed`) and a fresh crew in the pilotless Hercs.
static func from_saved(d: Dictionary, economy: GarageEconomy, seed: int) -> Garage:
	var g := from_dict(d, economy.make_pilot_names())
	if not d.has("salvage_kg"):
		g.salvage_kg = economy.make_start_pool(seed)
	SquadRoster.apply_auto_assign(g)
	return g


func to_dict() -> Dictionary:
	return {"vehicles": vehicles.duplicate(true), "selected": selected, "stock": stock.duplicate(),
		"salvage_kg": salvage_kg, "crew": crew.to_dict(), "squad": squad.duplicate(), "squad_auto": squad_auto,
		"last_report": last_report.duplicate(true)}


# ------------------------------------------------------------------ queries

func is_empty() -> bool:
	return vehicles.is_empty()


func is_full() -> bool:
	return vehicles.size() >= MAX_VEHICLES


## The selected Herc's entry ({} when the garage is empty).
func selected_entry() -> Dictionary:
	return vehicles[selected] if selected >= 0 and selected < vehicles.size() else {}


## Index of the Herc with `uid` (-1 = none).
func find_uid(uid: int) -> int:
	for i in vehicles.size():
		if int(vehicles[i].uid) == uid:
			return i
	return -1


## True when entry `e` is built (not waiting for missions in the factory).
static func is_ready(e: Dictionary) -> bool:
	return int(e.get("build_left", 0)) <= 0


## What the battle needs for the player: {vehicle, loadout, name, garage} of the selected Herc, or of
## the first built one while the selected Herc is still in the factory ({} when none is built).
func make_battle_entry() -> Dictionary:
	var e := selected_entry()
	if not is_ready(e):
		var ready := vehicles.filter(func(x): return is_ready(x))
		e = ready[0] if not ready.is_empty() else {}
	if e.is_empty():
		return {}
	return {"vehicle": str(e.vehicle), "loadout": (e.loadout as Array).duplicate(), "name": str(e.name),
		"garage": make_battle_tag(e)}


## The garage identity a battle Herc carries back in the mission result ({uid, pilot_id, condition}).
static func make_battle_tag(e: Dictionary) -> Dictionary:
	return {"uid": int(e.uid), "pilot_id": str(e.get("pilot_id", "")), "condition": (e.get("condition", []) as Array).duplicate()}


## Hardpoints of entry `e` holding a weapon.
static func make_armed_count(e: Dictionary) -> int:
	return (e.get("loadout", []) as Array).filter(func(w): return str(w) != EMPTY).size()


## {base weapon id: units mounted on any owned Herc} (fixed weapons are part of their vehicle, not stock).
func make_mounted_counts() -> Dictionary:
	var out := {}
	for e in vehicles:
		if PackVehicleLoader.has_fixed_loadout(Packs.vehicle(str(e.vehicle))):
			continue
		for wid in e.loadout:
			if str(wid) != EMPTY:
				var base := CampaignAvailability.base_weapon(str(wid))
				out[base] = int(out.get(base, 0)) + 1
	return out


## True when weapon `wid` may go on hardpoint `i` of the selected Herc under `ctx`: it fits the
## hardpoint (WeaponFit) and is offered with a unit left (or fabricated for salvage the pool holds),
## or it is already there. A fixed-loadout vehicle's weapons never change.
func can_arm(ctx: Dictionary, i: int, wid: String) -> bool:
	var e := selected_entry()
	if e.is_empty() or i < 0 or i >= (e.loadout as Array).size():
		return false
	if PackVehicleLoader.has_fixed_loadout(Packs.vehicle(str(e.vehicle))):
		return false
	if wid == EMPTY or wid == str(e.loadout[i]):
		return true
	if not WeaponFit.fits(Packs.weapon(wid), Packs.vehicle(str(e.vehicle)), i, ctx):
		return false
	return CampaignAvailability.can_mount(ctx, wid, 0) and make_arming_price(ctx, wid) <= salvage_kg


## Salvage arming `wid` costs: its fabrication price when the game fabricates it and no unit of it
## waits in the armory (0 otherwise).
func make_arming_price(ctx: Dictionary, wid: String) -> int:
	if not _is_fabricated(ctx, wid) or int(stock.get(CampaignAvailability.base_weapon(wid), 0)) > 0:
		return 0
	return GarageEconomy.of_context(ctx).make_weapon_price(wid)


## True when `vid` may be built under `ctx` (offered, affordable and the garage has room).
func can_build(ctx: Dictionary, vid: String) -> bool:
	return not is_full() and CampaignAvailability.is_vehicle_offered(ctx, vid) \
		and GarageEconomy.of_context(ctx).make_vehicle_price(vid) <= salvage_kg


func can_scrap() -> bool:
	return vehicles.size() > 1


## Salvage repairing Herc `i` to `target` (0..1) costs.
func make_repair_cost(ctx: Dictionary, i: int, target := 1.0) -> int:
	return GarageEconomy.of_context(ctx).make_repair_cost(vehicles[i], target) if i >= 0 and i < vehicles.size() else 0


## Salvage repairing every Herc completely costs.
func make_repair_all_cost(ctx: Dictionary) -> int:
	var total := 0
	for i in vehicles.size():
		total += make_repair_cost(ctx, i)
	return total


## The best repair level (0..1, the shell's 100 / 90 / 80 / 60 / 30 %) Herc `i` can afford; 0 = none.
func make_affordable_repair(ctx: Dictionary, i: int) -> float:
	var economy := GarageEconomy.of_context(ctx)
	for level in economy.make_repair_levels():
		var target := float(level) / GarageEconomy.PERCENT
		var cost := make_repair_cost(ctx, i, target)
		if cost <= salvage_kg and (cost > 0 or HercCondition.make_integrity(str(vehicles[i].vehicle), vehicles[i].condition) >= target):
			return target
	return 0.0


# ------------------------------------------------------------------ changes

## A new campaign's salvage pool and crew from its economy (the pilots sit in the Hercs besides the
## player's own).
func apply_campaign_start(economy: GarageEconomy, seed: int) -> void:
	salvage_kg = economy.make_start_pool(seed)
	crew = Crew.make(economy.make_pilot_names())
	SquadRoster.apply_auto_assign(self)


func apply_select(i: int) -> void:
	if not vehicles.is_empty():
		selected = posmod(i, vehicles.size())


## Puts `wid` ("" = none) on hardpoint `i` of the selected Herc; a counted weapon taken off goes back
## to the armory, one put on uses a unit (or is fabricated for salvage). Does nothing when can_arm() says no.
func apply_arm(ctx: Dictionary, i: int, wid: String) -> void:
	if not can_arm(ctx, i, wid):
		return
	var e := selected_entry()
	var old := str(e.loadout[i])
	if old == wid:
		return
	salvage_kg -= make_arming_price(ctx, wid)
	_apply_fabricated_stock(ctx, old, wid)
	CampaignAvailability.apply_arming(ctx, old, wid)
	e.loadout[i] = wid


## Fabricated weapons are owned units: one taken off joins the armory, one put on comes out of it.
func _apply_fabricated_stock(ctx: Dictionary, old_wid: String, new_wid: String) -> void:
	if old_wid != EMPTY and _is_fabricated(ctx, old_wid):
		var base := CampaignAvailability.base_weapon(old_wid)
		stock[base] = int(stock.get(base, 0)) + 1
	if new_wid != EMPTY and _is_fabricated(ctx, new_wid):
		var base := CampaignAvailability.base_weapon(new_wid)
		stock[base] = maxi(0, int(stock.get(base, 0)) - 1)


## Unlimited (unlocked) weapons the game sells for salvage.
static func _is_fabricated(ctx: Dictionary, wid: String) -> bool:
	return CampaignAvailability.make_weapon_reason(ctx, wid) != CampaignAvailability.REASON_STOCK \
		and CampaignAvailability.make_weapon_count(ctx, wid) == CampaignAvailability.UNLIMITED \
		and GarageEconomy.of_context(ctx).make_weapon_price(wid) > 0


## Builds a Herc of type `vid` for its price: it takes the game's build time in missions, comes with
## its standard weapons as far as the armory allows (a fixed-loadout vehicle with its own) and is
## selected. Returns its index, -1 when it can't be built.
func apply_build(ctx: Dictionary, vid: String) -> int:
	if not can_build(ctx, vid):
		return -1
	var economy := GarageEconomy.of_context(ctx)
	salvage_kg -= economy.make_vehicle_price(vid)
	var e := make_entry(vid)
	e.build_left = economy.make_build_missions(vid)
	vehicles.append(e)
	_apply_uids()
	selected = vehicles.size() - 1
	if PackVehicleLoader.has_fixed_loadout(Packs.vehicle(vid)):
		return selected
	var standard: Array = Packs.vehicle(vid).get("loadout", [])
	for i in mini(standard.size(), (selected_entry().loadout as Array).size()):
		var wid := str(standard[i]) if standard[i] != null else EMPTY
		if wid != EMPTY and can_arm(ctx, i, wid) and make_arming_price(ctx, wid) == 0:
			apply_arm(ctx, i, wid)
	return selected


## Scraps the selected Herc: its counted weapons go back to the armory, its parts' worth to the pool.
## The last Herc stays.
func apply_scrap(ctx: Dictionary) -> void:
	if not can_scrap():
		return
	salvage_kg += GarageEconomy.of_context(ctx).make_scrap_value(selected_entry())
	for i in (selected_entry().loadout as Array).size():
		apply_arm(ctx, i, EMPTY)
	apply_remove(selected)


## Repairs Herc `i` to the best level the pool affords (completely when it can) and pays for it.
func apply_repair(ctx: Dictionary, i: int) -> void:
	if i < 0 or i >= vehicles.size():
		return
	var target := make_affordable_repair(ctx, i)
	if target <= 0.0:
		return
	salvage_kg -= make_repair_cost(ctx, i, target)
	var e: Dictionary = vehicles[i]
	e.condition = HercCondition.make_repaired(str(e.vehicle), e.condition, target)
	if HercCondition.is_pristine(e.condition):
		e.condition = []


## Repairs every Herc, the selected one first, as far as the pool goes.
func apply_repair_all(ctx: Dictionary) -> void:
	apply_repair(ctx, selected)
	for i in vehicles.size():
		apply_repair(ctx, i)


## Takes Herc `i` out of the garage (written off or scrapped); its pilot is free again.
func apply_remove(i: int) -> void:
	squad.erase(int(vehicles[i].uid))
	vehicles.remove_at(i)
	selected = clampi(selected if selected < i else selected - 1, 0, maxi(vehicles.size() - 1, 0))


func apply_rename(text: String) -> void:
	if not selected_entry().is_empty():
		selected_entry()["name"] = text


## Adds a finished saga stage's Hercs (while there is room), armory, salvage and crew to this garage.
func apply_merge(other: Garage) -> void:
	for e in other.vehicles:
		if not is_full():
			var copy := (e as Dictionary).duplicate(true)
			copy.uid = 0
			copy.pilot_id = ""
			vehicles.append(copy)
	_apply_uids()
	for wid in other.stock:
		stock[wid] = int(stock.get(wid, 0)) + int(other.stock[wid])
	salvage_kg += other.salvage_kg
	crew.apply_merge(other.crew)
	SquadRoster.apply_auto_assign(self)


## Drops Hercs whose pack is gone and fixes loadout lengths (saves from older builds, disabled packs).
func _apply_sanitize() -> void:
	var keep: Array = []
	for e in vehicles:
		if e is Dictionary and not Packs.vehicle(str(e.get("vehicle", ""))).is_empty():
			keep.append(_make_sanitized(e))
	vehicles = keep
	selected = clampi(selected, 0, maxi(vehicles.size() - 1, 0))
	_apply_uids()


static func _make_sanitized(e: Dictionary) -> Dictionary:
	var fixed := make_entry(str(e.vehicle), e.get("loadout", []) if e.get("loadout") is Array else [])
	fixed.uid = int(e.get("uid", 0))
	fixed.name = str(e.get("name", fixed.name))
	fixed.pilot_id = str(e.get("pilot_id", ""))
	fixed.condition = (e.get("condition", []) as Array).map(func(f): return float(f)) if e.get("condition") is Array else []
	fixed.build_left = int(e.get("build_left", 0))
	return fixed


## Gives every Herc without one a unique id (saves from before the ids, new and merged Hercs).
func _apply_uids() -> void:
	for e in vehicles:
		_next_uid = maxi(_next_uid, int(e.uid) + 1)
	for e in vehicles:
		if int(e.uid) <= 0:
			e.uid = _next_uid
			_next_uid += 1

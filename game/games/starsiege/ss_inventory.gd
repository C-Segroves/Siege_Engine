class_name SSInventory
extends RefCounted
## Starsiege campaign inventories: what vehicles and weapons each planet (and the player's stash)
## holds, as the original scripts set them (scripts/hu_planet_init.cs / cy_planet_init.cs, exported
## to campaigns/<variant>.json "inventory_init") and change them (missionStdLib.cs
## updatePlanetInventory and vehicle::salvage, recorded by StarsiegeMissionRuntime).
##
## Original calls (hu_planet_init.cs header):
##   Inventory{Weapon,Vehicle}Set(planet, id, amount)     planet name or -1 = stash; id -1 = all;
##   Inventory{Weapon,Vehicle}Adjust(planet, id, delta)    amount -1 = infinite supply
## Components and pilots are not modelled. Ids map to catalog keys via gameplay/ids.json.
##
## State (saved with the campaign): {"planets": {planet: {"vehicles": {id: n}, "weapons": {id: n}}}}
## with planet names lower-cased and the stash under STASH.

const PACK := "starsiege"
const STASH := "stash"
const ALL := -1
const INFINITE := -1
const KIND_BY_CALL := {"inventoryweaponset": "weapons", "inventoryweaponadjust": "weapons",
	"inventoryvehicleset": "vehicles", "inventoryvehicleadjust": "vehicles"}
const ID_TABLE_BY_KIND := {"weapons": "weapons", "vehicles": "vehicles"}

static var _ids := {}


## Inventory state after the campaign's initial script (`inventory_init` call list).
static func make_initial(calls: Array) -> Dictionary:
	var state := {"planets": {}}
	apply_calls(state, calls)
	return state


## Applies recorded Inventory* calls ([name, planet, id, amount], any case) to `state`.
static func apply_calls(state: Dictionary, calls: Array) -> void:
	for c in calls:
		if c is Array and c.size() >= 4:
			_apply_call(state, str(c[0]).to_lower(), c[1], int(float(str(c[2]))), int(float(str(c[3]))))


static func _apply_call(state: Dictionary, call: String, planet: Variant, id: int, amount: int) -> void:
	if not KIND_BY_CALL.has(call):
		return
	var kind: String = KIND_BY_CALL[call]
	var table: Dictionary = _make_planet(state, make_planet_key(planet))[kind]
	var keys: Array = [str(id)] if id != ALL else (_id_table(kind).keys())
	for key in keys:
		if call.ends_with("set"):
			table[key] = amount
		else:
			table[key] = _make_adjusted(int(table.get(key, 0)), amount)


## Adjusting an infinite supply leaves it infinite; counts never go below zero.
static func _make_adjusted(current: int, delta: int) -> int:
	if current == INFINITE or delta == INFINITE:
		return INFINITE
	return maxi(0, current + delta)


## "Mars" / "mars" -> "mars"; -1 (or "-1") -> the stash.
static func make_planet_key(planet: Variant) -> String:
	var s := str(planet).strip_edges().to_lower()
	return STASH if s == "-1" or s == "-1.0" else s


static func _make_planet(state: Dictionary, key: String) -> Dictionary:
	if not state.planets.has(key):
		state.planets[key] = {"vehicles": {}, "weapons": {}}
	return state.planets[key]


## Adds salvaged catalog weapons ("starsiege:LAS") to the stash, as vehicle::salvage does for
## weapons the planet doesn't stock.
static func apply_salvage(state: Dictionary, weapon_ids: Array) -> void:
	var by_key := _catalog_to_original("weapons")
	var stash: Dictionary = _make_planet(state, STASH).weapons
	for wid in weapon_ids:
		var key := str(by_key.get(CampaignAvailability.base_weapon(str(wid)), ""))
		if key != "":
			stash[key] = _make_adjusted(int(stash.get(key, 0)), 1)


# ------------------------------------------------------------------ queries

## Catalog ids of vehicles available on `planet` (planet or stash count > 0, or infinite).
static func make_vehicle_ids(state: Dictionary, planet: String) -> Array:
	var counts := make_counts(state, planet, "vehicles")
	return counts.keys().filter(func(id): return int(counts[id]) != 0)


## The campaign's starting garage: one Herc per stash vehicle unit (an infinite supply gives one),
## standard loadouts; the armory is the inventory itself (see the provider's availability_context).
static func make_start_garage(state: Dictionary) -> Garage:
	var entries: Array = []
	var counts := make_counts(state, "", "vehicles")
	for vid in counts:
		var units := 1 if int(counts[vid]) == INFINITE else int(counts[vid])
		for i in mini(units, Garage.MAX_VEHICLES - entries.size()):
			entries.append(Garage.make_entry(str(vid), Packs.vehicle(str(vid)).get("loadout", [])))
	return Garage.make(entries, {})


## {catalog weapon id: count} on `planet` plus the stash (INFINITE wins over counts).
static func make_counts(state: Dictionary, planet: String, kind: String) -> Dictionary:
	var out := {}
	var names := _id_table(kind)
	for source in [make_planet_key(planet), STASH]:
		var table: Dictionary = state.get("planets", {}).get(source, {}).get(kind, {})
		for key in table:
			if not names.has(str(key)):
				continue
			var id := "%s:%s" % [PACK, names[str(key)]]
			var n := int(table[key])
			out[id] = INFINITE if n == INFINITE or int(out.get(id, 0)) == INFINITE else int(out.get(id, 0)) + n
	return out


## Original numeric id -> catalog key (gameplay/ids.json "vehicles" / "weapons").
static func _id_table(kind: String) -> Dictionary:
	if _ids.is_empty():
		var j = Assets.load_json("gameplay/ids.json", PACK)
		_ids = j if j is Dictionary else {"missing": true}
	return _ids.get(ID_TABLE_BY_KIND.get(kind, kind), {})


static func _catalog_to_original(kind: String) -> Dictionary:
	var out := {}
	var names := _id_table(kind)
	for key in names:
		out["%s:%s" % [PACK, names[key]]] = str(key)
	return out

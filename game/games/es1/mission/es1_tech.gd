class_name Es1Tech
extends RefCounted
## Earthsiege tech releases: which Herc types and weapons a career may build and arm, by missions
## flown (docs/formats/shell.md §7b, docs/formats/campaign_availability.md).
##
## Original: GO.EXE 0x158ff loads BST\TECH_0.DAT (career; TECH_SNG.DAT for single missions) into the
## career's tech object: per Herc type and weapon {early, late} mission counts, -1 = never. After
## every mission 0x1f78(missions flown) releases an item once missions >= late, or already at
## missions >= early while the pilot's standing (0x36837, a rank table lookup) is good, and shows
## TechReleaseAlert. Exported to shell/hangar.json "career_tech" by tools/export_shell.py --hangar.
## Approximation: "good standing" = the last mission was won (0x36837's inputs are not decoded).
## Starting garage: CAR\CAR_INIT.DAT ("career_init": 2 Roadrunners, 2 Gunslingers, weapons per GL
## loadout slot) and the CAR\C_ARMORY.DAT stock ("career_armory").

const NEVER := -1
const PACK := "es1"
const NO_WEAPON := 17               # CAR_INIT.DAT weapon index of an empty hardpoint
const NO_MISSILE_TYPE := 5          # CAR_INIT.DAT missile type of a non-rack weapon
const HANGAR_FILE := "hangar.json"

static var _hangar_data := {}


## shell/hangar.json (tools/export_shell.py --hangar), {} when not exported.
static func load_hangar_data() -> Dictionary:
	if _hangar_data.is_empty():
		var j = ShellData.json(HANGAR_FILE)
		_hangar_data = j if j is Dictionary else {"missing": true}
	return _hangar_data if not _hangar_data.has("missing") else {}


## True when tech record `entry` ({early, late}) is released after `missions` missions.
static func is_released(entry: Dictionary, missions: int, good_standing: bool) -> bool:
	var early := int(entry.get("early", NEVER))
	var late := int(entry.get("late", NEVER))
	if early == NEVER or late == NEVER:
		return false
	return missions >= late or (good_standing and missions >= early)


## Catalog ids of the Herc types released so far ("es1:RAPTOR").
static func make_released_vehicles(missions: int, good_standing: bool) -> Array:
	return _make_released("herc", "hercs", missions, good_standing)


## Catalog weapon ids released so far (missile racks by base id, "es1:MLRS6").
static func make_released_weapons(missions: int, good_standing: bool) -> Array:
	return _make_released("weapon", "tech_weapons", missions, good_standing)


static func _make_released(kind: String, names_key: String, missions: int, good_standing: bool) -> Array:
	var d := load_hangar_data()
	var names: Array = d.get(names_key, [])
	var out: Array = []
	for entry in d.get("career_tech", []):
		var i := int(entry.get("index", -1))
		if str(entry.get("kind", "")) != kind or i < 0 or i >= names.size():
			continue
		if is_released(entry, missions, good_standing):
			var n = names[i]
			out.append("%s:%s" % [PACK, str(n.unit if n is Dictionary else n)])
	return out


## The new-career armory stock from C_ARMORY.DAT: {weapon id: count}.
static func make_start_armory() -> Dictionary:
	var d := load_hangar_data()
	var names: Array = d.get("weapons", [])
	var armory := {}
	for a in d.get("career_armory", []):
		var wi := int(a.get("weapon", -1))
		if wi >= 0 and wi < names.size():
			armory["%s:%s" % [PACK, str(names[wi])]] = int(a.get("count", 0))
	return armory


## The new-career garage: the CAR_INIT.DAT Hercs with their weapons and the C_ARMORY.DAT stock.
static func make_start_garage() -> Garage:
	var d := load_hangar_data()
	var entries: Array = []
	for rec in d.get("career_init", []):
		var units: Array = d.get("hercs", [])
		var t := int(rec.get("type", -1))
		if t < 0 or t >= units.size():
			continue
		var vid := "%s:%s" % [PACK, str(units[t].unit)]
		if not Packs.vehicle(vid).is_empty():
			entries.append(Garage.make_entry(vid, _make_init_loadout(Packs.vehicle(vid), rec, d)))
	return Garage.make(entries, make_start_armory())


## CAR_INIT.DAT weapons (by GL loadout slot) in the vehicle's gun order; racks get their missile type.
static func _make_init_loadout(v: Dictionary, rec: Dictionary, d: Dictionary) -> Array:
	var names: Array = d.get("weapons", [])
	var types: Array = d.get("missile_types", [])
	var slots: Array = rec.get("weapons", [])
	var missiles: Array = rec.get("missiles", [])
	var out: Array = []
	for g in v.get("guns", []):
		var s := int(g.get("loadout_slot", out.size()))
		var wi := int(slots[s]) if s < slots.size() else NO_WEAPON
		var mt := int(missiles[s]) if s < missiles.size() else NO_MISSILE_TYPE
		var wid := "%s:%s" % [PACK, str(names[wi])] if wi >= 0 and wi < names.size() else ""
		if wid != "" and mt >= 0 and mt < types.size() and Packs.weapons.has("%s_%s" % [wid, types[mt]]):
			wid = "%s_%s" % [wid, types[mt]]
		out.append(wid)
	return out


## Availability context of an Earthsiege career: released Hercs/weapons, `stock` = the armory, the
## career's salvage economy (GO.EXE prices, CFG/DAMAGE.DAT repairs).
static func make_context(missions: int, good_standing: bool, stock: Dictionary) -> Dictionary:
	var ctx := CampaignAvailability.make_context(PACK)
	ctx.unlocked_vehicles = make_released_vehicles(missions, good_standing)
	ctx.unlocked_weapons = make_released_weapons(missions, good_standing)
	ctx.salvage_stock = stock
	ctx.economy = GarageEconomy.make_for_pack(PACK)
	return ctx

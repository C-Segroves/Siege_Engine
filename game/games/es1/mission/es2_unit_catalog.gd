class_name ES2UnitCatalog
extends RefCounted
## Maps Earthsiege 2 mission records to catalog content: herc type names to vehicle ids (with
## Earthsiege 1 stand-ins for units the es2 pack lacks), WEAPONS.DAT ids to weapon ids and base
## records to structure shapes.

## herc types that fly (NAM/MECHS.NAM 8 = RAZOR); everything else walks
const FLYING_HERCS := ["RAZOR"]
## Cybrid / new units without an es2 shape fall back to the closest Earthsiege 1 unit
const FALLBACK_VEHICLE := {"PITBULL": "es1:BULLDOG", "STINGRAY": "es1:SCORPION", "HYPERION": "es1:APOLLO",
	"DIABLO": "es1:APOLLO", "HEADHUNT": "es1:ACHILLES", "SCARAB": "es1:MONGOOSE", "CERBERUS": "es1:APOLLO",
	"SPIDER": "es1:SPIDER", "MONGOOSE": "es1:MONGOOSE", "MIRIMAC": "es1:MIRIMAC", "RAMSES": "es1:RAMSES",
	"ACHILLES": "es1:ACHILLES", "OUTLAW": "es1:ROADRUNN", "RAPTOR2": "es1:RAPTOR", "TOMAHAWK": "es1:TOMAHAWK",
	"SAMSON": "es1:HERCULES", "COLOSSUS": "es1:COLOSSUS", "APOCA": "es1:COLOSSUS", "OGRE": "es1:HERCULES",
	"MAVERICK": "es1:PANTHER", "RAZOR": "es1:SKIMMER", "SKIMMER": "es1:SKIMMER"}
const DEFAULT_FALLBACK_VEHICLE := "es1:MONGOOSE"
## WEAPONS.DAT record -> engine weapon name (tools/export_es2_weapons.py); missile racks take the
## guidance from the herc's ammo word (0 SARH, 1 ARH, 2 ARM, 3 EO; 5 = default -> SARH)
const WEAPON_NAMES := ["", "ATC20", "ATC35", "ATC50", "ATC75", "ATC100", "ELF", "EMP", "LAS100", "LAS200",
	"LAS300", "LAS400", "LAS500", "MSL6", "MSL8", "MSL10", "FLYMSL", "PBEAM", "ECM", "EMP_BULL", "PBEAM_BULL",
	"MISSL_BULL", "ELF2", "EMP2", "PBW2", "PLAS", "LAEW", "MINE", "MAGN", "TARG", "SHIELD", "TURBO", "ENERGY"]
const GUIDANCE := ["SARH", "ARH", "ARM", "EO"]
const DEFAULT_AMMO_WORD := 5
const DEFAULT_PLAYER_VEHICLE := "es2:OUTLAW"
## ES1 base shapes used when the es2 pack has no BASES_<n> (6 shapes).
const ES1_BASE_SHAPE_COUNT := 6


## Vehicle id for an ES2 herc record (falls back to the closest Earthsiege 1 unit if the es2 pack
## has no such vehicle).
static func vehicle_for(type_name) -> String:
	var n := String(type_name if type_name != null else "MONGOOSE")
	var vid := "es2:%s" % n
	if not Packs.vehicle(vid).is_empty():
		return vid
	return FALLBACK_VEHICLE.get(n, DEFAULT_FALLBACK_VEHICLE)


## Engine weapon ids for an ES2 herc record (one per hardpoint slot of the vehicle's gun list).
static func loadout_for(vid: String, weapons: Array, ammo: Array) -> Array:
	var v := Packs.vehicle(vid)
	var pack := String(v.get("pack", "es2"))
	var out := []
	var any := false
	var guns: Array = v.get("guns", [])
	for gi in guns.size():
		var slot := int(guns[gi].get("loadout_slot", gi))
		var full := _weapon_id(pack, _weapon_name(weapons, ammo, slot))
		out.append(full)
		if full != "":
			any = true
	return out if any else v.get("loadout", [])


## Engine weapon name of a hardpoint slot ("" = empty); missile racks get their guidance suffix.
static func _weapon_name(weapons: Array, ammo: Array, slot: int) -> String:
	var wid := int(weapons[slot]) if slot >= 0 and slot < weapons.size() else -1
	var name: String = WEAPON_NAMES[wid] if wid > 0 and wid < WEAPON_NAMES.size() else ""
	if name.begins_with("MSL") or name == "FLYMSL":
		var a := int(ammo[slot]) if slot < ammo.size() else DEFAULT_AMMO_WORD
		name = "%s_%s" % [name, GUIDANCE[a] if a >= 0 and a < GUIDANCE.size() else "SARH"]
	return name


## The weapon in the vehicle's pack, else in es2, else "" (unknown weapon = empty hardpoint).
static func _weapon_id(pack: String, name: String) -> String:
	if name == "":
		return ""
	var full := "%s:%s" % [pack, name]
	if Packs.weapon(full).is_empty():
		full = "es2:%s" % name if not Packs.weapon("es2:%s" % name).is_empty() else ""
	return full


## The player's Herc as the mission defines it: (vehicle id, loadout).
static func player_vehicle(mission: Dictionary) -> Array:
	var ps = mission.get("player_start")
	var h = ps.get("herc") if ps is Dictionary else null
	if not h is Dictionary:
		return [DEFAULT_PLAYER_VEHICLE, []]
	var vid := vehicle_for(h.get("type_name"))
	return [vid, loadout_for(vid, MissionRuntime._arr(h.get("weapons")), MissionRuntime._arr(h.get("ammo")))]


## Structure shape of a bases.json record: its (enemy) shape, else BASES_<n> of es2, else of es1.
static func structure_shape(row, t: int, team: int) -> String:
	if row is Dictionary:
		var key := "shape_enemy" if team == 1 and row.get("shape_enemy") != null else "shape"
		if row.get(key) != null:
			var sid := String(row.get(key))
			return sid if sid.contains(":") else "es2:%s" % sid
	var idx := int(row_number(row, "shape_index", float(t)))
	var es2_shape := "es2:BASES_%d" % idx
	if Assets.shape(es2_shape).get("lods", [{}])[0].get("pieces", []).is_empty():
		return "es1:BASES_%d" % (idx % ES1_BASE_SHAPE_COUNT)
	return es2_shape


## A number from a bases.json record (dictionary records, or ES1-style [type, shape, -, -, hp] rows).
static func row_number(row, key: String, dflt: float) -> float:
	if row is Dictionary and row.get(key) != null:
		return float(row[key])
	if row is Array and key == "hp" and row.size() > 4:
		return float(row[4])
	if row is Array and key == "shape_index" and row.size() > 1:
		return float(row[1])
	return dflt

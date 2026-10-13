extends Node
## Registry of installed content packs (one per original game) and the unified catalog of
## pilotable vehicles and weapons across all of them, converted to real-world units.
##
## Each pack folder (gamedata/<pack>/) may contain:
##   pack.json              {"name", "default_palette", "world_metres_per_unit"?, "weapon_pack"?}
##   units.json             code-derived conversions (tools/units_calib.py; docs/formats/units.md)
##   gameplay/hercs.json    unit definitions (3Space v1 games: ES1, Battledrome)
##   gameplay/weapons.json  weapon + projectile tables
##
## SCALE POLICY: every game measured its world in its own units. We place all games in one
## metric world using the size Dynamix documented for the Hercs (Earthsiege 2 manual heights and
## km/h table, which use the same models as Earthsiege 1 -> 1/256 m per unit). Battledrome's only
## readout has no unit label, so its Hercs are scaled to the same average size; Tribes is natively
## in metres. Times and rates always come from each game's code. Override per pack in pack.json.
const WORLD_SCALE := {"es1": 1.0 / 256.0, "es2": 1.0 / 256.0, "bd": 0.00215, "tribes": 1.0,
	"starsiege": 1.0, "tribes2": 1.0}

## Fallback simulation rate for packs without units.json.
const TICK_HZ := 10.0
const ANGLE := TAU / 65536.0

var packs := {}          # pack -> pack.json dict
var units := {}          # pack -> units.json dict
var vehicles := {}       # "pack:NAME" -> normalized vehicle definition
var weapons := {}        # "pack:NAME" -> normalized weapon definition


## Content kinds a pack can provide; each can be switched on/off per pack (user://content.json).
const CONTENT_KINDS := {
	"hercs": "Hercs", "cybrids": "Cybrids", "herc_weapons": "Herc weapons",
	"infantry": "Infantry armors", "infantry_weapons": "Infantry weapons",
	"vehicles": "Vehicles", "vehicle_weapons": "Vehicle weapons",
	"arenas": "Arenas", "worlds": "Worlds / terrain", "missions": "Missions & campaign",
}
## In the current store (UserStore).
var CONTENT_FILE: String:
	get: return UserStore.path("content.json")
var content_enabled := {}   # pack -> {kind: bool}


func _ready() -> void:
	_load_content_settings()
	reload()


func _load_content_settings() -> void:
	var f := FileAccess.open(CONTENT_FILE, FileAccess.READ)
	if f:
		var j = JSON.parse_string(f.get_as_text())
		if j is Dictionary:
			content_enabled = j


func set_enabled(pack: String, kind: String, on: bool) -> void:
	if not content_enabled.has(pack):
		content_enabled[pack] = {}
	content_enabled[pack][kind] = on
	var f := FileAccess.open(CONTENT_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(content_enabled, "  "))


func is_enabled(pack: String, kind: String) -> bool:
	return bool(content_enabled.get(pack, {}).get(kind, true))


## What a pack provides: kind -> item count (only kinds with content).
func pack_contents(pack: String) -> Dictionary:
	var out := {}
	for id in vehicles:
		var v: Dictionary = vehicles[id]
		if v.pack != pack:
			continue
		var k := _vehicle_kind(v)
		out[k] = int(out.get(k, 0)) + 1
	for id in weapons:
		var w: Dictionary = weapons[id]
		if w.pack != pack:
			continue
		var k := "%s_weapons" % w.get("category", "herc")
		out[k] = int(out.get(k, 0)) + 1
	var arenas = Assets.load_json("arenas/_index.json", pack)
	if arenas is Array and not arenas.is_empty():
		out["arenas"] = arenas.size()
	if DirAccess.dir_exists_absolute(Assets.path("worlds", pack)):
		out["worlds"] = DirAccess.get_files_at(Assets.path("worlds", pack)).size()
	var msn_dir := Assets.path("missions/msn", pack)
	if DirAccess.dir_exists_absolute(msn_dir):
		out["missions"] = DirAccess.get_files_at(msn_dir).size()
	return out


func _vehicle_kind(v: Dictionary) -> String:
	match String(v.get("category", "herc")):
		"infantry":
			return "infantry"
		"vehicle":
			return "vehicles"
	return "cybrids" if v.get("side", "herc") == "cybrid" else "hercs"


func reload() -> void:
	packs.clear()
	units.clear()
	vehicles.clear()
	weapons.clear()
	for p in Assets.installed_packs():
		var meta = Assets.load_json("pack.json", p)
		packs[p] = meta if meta != null else {"name": p, "default_palette": "WORLD0"}
		var u = Assets.load_json("units.json", p)
		units[p] = u if u is Dictionary else {}
	var weapon_loader := PackWeaponLoader.new(self)
	for p in packs:
		weapons.merge(weapon_loader.load_pack(p), true)
	var vehicle_loader := PackVehicleLoader.new(self)
	for p in packs:
		vehicles.merge(vehicle_loader.load_pack(p), true)
	_compute_balance()
	# measured pods and look-alike choices depend on which packs are installed
	WeaponPodFit.clear_cache()
	WeaponLookalike.clear_cache()
	FxLibrary.clear_cache()


## Cross-game balance: per weight class, the factor that brings a pack's mean top speed to the
## reference pack's (Earthsiege) mean. Used when a match enables "balanced" stats.
const BALANCE_REFERENCE := "es1"


func _compute_balance() -> void:
	var sums := {}
	for id in vehicles:
		var v: Dictionary = vehicles[id]
		if v.side != "herc" or not _is_balanced_family(v):
			continue
		var key: String = "%s/%s" % [v.pack, v.weight]
		var e: Array = sums.get(key, [0.0, 0])
		sums[key] = [e[0] + float(v.max_speed), e[1] + 1]
	for id in vehicles:
		var v: Dictionary = vehicles[id]
		var own: Array = sums.get("%s/%s" % [v.pack, v.weight], [0.0, 0])
		var ref: Array = sums.get("%s/%s" % [BALANCE_REFERENCE, v.weight], [0.0, 0])
		var known: bool = own[1] > 0 and ref[1] > 0 and own[0] > 0.0 and _is_balanced_family(v)
		v["speed_balance"] = (ref[0] / ref[1]) / (own[0] / own[1]) if known else 1.0


## Only Herc-family vehicles are balanced against the Earthsiege Hercs; Tribes vehicles keep their speeds.
static func _is_balanced_family(v: Dictionary) -> bool:
	return str(v.get("category", "herc")) == "herc"


## Metres per original world unit in the shared world (see SCALE POLICY).
func metres_per_unit(pack: String) -> float:
	var meta: Dictionary = packs.get(pack, {})
	if meta.has("world_metres_per_unit"):
		return float(meta.world_metres_per_unit)
	if WORLD_SCALE.has(pack):
		return float(WORLD_SCALE[pack])
	var u: Dictionary = units.get(pack, {})
	return float(u.get("metres_per_unit", Assets.UNIT))


## Ratio applied to distances/speeds that units.json expresses at the game's code-derived scale.
func code_to_world(pack: String) -> float:
	var u: Dictionary = units.get(pack, {})
	var code := float(u.get("metres_per_unit", 0.0))
	return metres_per_unit(pack) / code if code > 0.0 else 1.0


## Geometry scale for a pack's shapes relative to the engine base unit.
func shape_scale(pack: String) -> float:
	return metres_per_unit(pack) / Assets.UNIT


func pack_name(pack: String) -> String:
	return str(packs.get(pack, {}).get("name", pack))


func default_palette(pack: String) -> String:
	return "%s:%s" % [pack, packs.get(pack, {}).get("default_palette", "WORLD0")]


## Vehicles a player can pilot, optionally filtered by pack and side ("herc", "cybrid").
func pilotable(pack_filter := [], side := "") -> Array:
	var out := []
	for id in vehicles:
		var v: Dictionary = vehicles[id]
		if not v.pilotable or not is_enabled(v.pack, _vehicle_kind(v)):
			continue
		if not pack_filter.is_empty() and not pack_filter.has(v.pack):
			continue
		if side != "" and v.side != side:
			continue
		out.append(v)
	out.sort_custom(func(a, b): return a.mass < b.mass if a.pack == b.pack else a.pack < b.pack)
	return out


func vehicle(id: String) -> Dictionary:
	return vehicles.get(Assets.qualify(id), {})


func weapon(id: String) -> Dictionary:
	return weapons.get(Assets.qualify(id), {})


# ------------------------------------------------------------------ weapons

## ES1 weapon size classes for hardpoint compatibility (hardpoint masks 7 small/missile,
## 15 medium, 31 large): which mask a weapon needs at minimum.
const ES1_SIZE := PackWeaponLoader.ES1_SIZE
const SIZE_MASK := PackWeaponLoader.SIZE_MASK
const ES1_MISSILE_GUIDANCE := PackWeaponLoader.ES1_MISSILE_GUIDANCE


## True if weapon `w` fits a hardpoint with the given original mask (size classes, WeaponFit).
func fits(w: Dictionary, hardpoint_mask: int) -> bool:
	return WeaponFit.fits_mask(w, hardpoint_mask)


## Weapon families never mix: Herc weapons, infantry (Tribes armor) weapons, vehicle (Tribes
## vehicle) weapons. Every weapon and every platform has a category.
const CATEGORIES := ["herc", "infantry", "vehicle"]


## All weapons (any pack) of a family that fit a hardpoint, sorted by id. `include_cybrid` = Cybrid-
## only weapons may go there: pass WeaponFit.allows_cybrid_weapons(vehicle, rules), or set
## rules[WeaponFit.RULE_CYBRID_WEAPONS_ON_HERCS] (either one allows them).
func weapons_for_mask(hardpoint_mask: int, include_cybrid := false, category := "herc", rules := {}) -> Array:
	var cybrid_ok := include_cybrid or bool(rules.get(WeaponFit.RULE_CYBRID_WEAPONS_ON_HERCS, false))
	var out := []
	for id in weapons:
		var w: Dictionary = weapons[id]
		if w.get("category", "herc") != category or not is_enabled(w.pack, "%s_weapons" % category):
			continue
		if WeaponFit.fits_mask(w, hardpoint_mask, cybrid_ok):
			out.append(w)
	out.sort_custom(func(a, b): return a.id < b.id)
	return out


# ------------------------------------------------------------------ vehicles

## Picks a sensible weapon for each hardpoint from the hardpoint size mask.
func default_loadout(v: Dictionary) -> Array:
	return PackVehicleLoader.new(self).default_loadout(v)


# ------------------------------------------------------------------ timeline and ratings

## In-universe timeline (docs/formats/campaign_availability.md §1), used when an older pack.json
## has no "era"/"year". A pack in neither sorts last.
const ERA_DEFAULTS := {"es1": [1, 2471], "bd": [2, 2480], "es2": [3, 2495], "starsiege": [4, 2829],
	"tribes": [5, 3940], "tribes2": [5, 3941]}
const ERA_UNKNOWN := 99


## Position of a pack on the timeline (1 = Earthsiege ... 5 = Tribes); ERA_UNKNOWN when unknown.
func era(pack: String) -> int:
	var meta: Dictionary = packs.get(pack, {})
	if meta.has("era"):
		return int(meta.era)
	return int(ERA_DEFAULTS.get(pack, [ERA_UNKNOWN])[0])


## In-universe year of a pack's setting (0 when unknown).
func year(pack: String) -> int:
	var meta: Dictionary = packs.get(pack, {})
	if meta.has("year"):
		return int(meta.year)
	return int(ERA_DEFAULTS.get(pack, [0, 0])[1])


## 0..1 strength of a pilotable vehicle among vehicles of its kind (Hercs vs Hercs, tanks vs tanks).
func combat_rating(v: Dictionary) -> float:
	return CombatRating.vehicle_rating(self, v)


## 0..1 strength of a Herc weapon among weapons of its family (beam, cannon, missile, special).
func weapon_rating(w: Dictionary) -> float:
	return CombatRating.weapon_rating(self, w)


## beam / cannon / missile / special.
func weapon_family(w: Dictionary) -> String:
	return CombatRating.weapon_family(w)

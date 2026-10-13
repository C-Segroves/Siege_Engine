class_name PackWeaponLoader
extends RefCounted
## Builds the catalog weapon definitions of one pack (docs/formats/weapon_schema.md) for Packs:
## either already in engine units (gameplay/weapons_engine.json) or from a 3Space v1 weapon table
## (gameplay/weapons.json + units.json conversions: ES1, Battledrome).

## ES1 weapon size classes for hardpoint compatibility (hardpoint masks 7 small/missile,
## 15 medium, 31 large): which mask a weapon needs at minimum.
const ES1_SIZE := {"ATC20": "light", "LAS100": "light", "ATC35": "medium", "LAS200": "medium",
	"ELF": "medium", "GREN": "medium", "ATC50": "heavy", "LAS300": "heavy", "PBEAM": "heavy", "EMP": "heavy",
	"MLRS6": "missile", "MLRS8": "missile", "MLRS10": "missile", "ECM": "special"}
const SIZE_MASK := {"light": 7, "missile": 7, "medium": 15, "heavy": 31, "special": 7}
const ES1_MISSILE_GUIDANCE := {"SARH": "sarh", "ARH": "arh", "ARM": "arm", "EO": "eo"}
## Projectile table rows used when a weapon names none (3Space v1 weapons.json).
const DEFAULT_MISSILE_ROW := 10
const DEFAULT_GRENADE_ROW := 7
## Original range / damage defaults (weapon table units).
const DEFAULT_RANGE_UNITS := 50000.0
const DEFAULT_DAMAGE := 500.0
const SPLASH_DENOMINATOR := 1024.0
## ELF leech amount (ES1 code).
const ELF_LEECH := 150
## MLRS racks fire pairs.
const MLRS_BURST := 2
const MLRS_BURST_INTERVAL := 0.25
## Every Earthsiege 1 missile turns at most 0x500 angle units (1/65536 turn) per sim frame: the homing cap
## (DBSIM 0x7085) and the EO missile's full-stick steer (0x7115, docs/MISSILE_CAM.md). At Packs.TICK_HZ frames
## per second: make_missile_turn_rate_deg().
const MISSILE_TURN_PER_FRAME := 0x500
const ANGLE_UNITS_PER_TURN := 65536.0
## The player steers an EO missile for its whole rocket lifetime (ROCKETS.DAT word 1, frames at Packs.TICK_HZ),
## not just its weapon range (gameplay/projectiles.json "rockets", row = missile type).
const PROJECTILES_FILE := "gameplay/projectiles.json"
const ROCKET_LIFETIME_FIELD := "w1"
const INFANTRY_WEAPONS_FILE := "gameplay/weapons_infantry.json"
## The guns of the Tribes base turrets ("category": "turret", tools/export_tribes_base.py).
const TURRET_WEAPONS_FILE := "gameplay/weapons_turret.json"

var catalog: Node   # the Packs autoload (units, metres_per_unit, code_to_world)


func _init(packs_catalog: Node) -> void:
	catalog = packs_catalog


## All weapon definitions of a pack (id -> def), plus its infantry weapons (gameplay/weapons_infantry.json,
## Tribes armours: tools/export_tribes_infantry.py) and base turret guns (gameplay/weapons_turret.json).
func load_pack(pack: String) -> Dictionary:
	var out := _load_vehicle_weapons(pack)
	for file in [INFANTRY_WEAPONS_FILE, TURRET_WEAPONS_FILE]:
		var extra = Assets.load_json(file, pack)
		if extra is Dictionary:
			out.merge(_engine_weapons(pack, extra), true)
	return out


func _load_vehicle_weapons(pack: String) -> Dictionary:
	var eng = Assets.load_json("gameplay/weapons_engine.json", pack)
	if eng is Dictionary:
		return _engine_weapons(pack, eng)
	var j = Assets.load_json("gameplay/weapons.json", pack)
	if j == null:
		return {}
	var out := {}
	var derived := {}
	for x in catalog.units.get(pack, {}).get("weapons", []):
		derived[x.name] = x
	for w in j.get("weapons", []):
		var def := _table_weapon(pack, w, j.get("projectiles", []), derived.get(w.name, {}))
		if def.kind == "missile" and String(w.name).begins_with("MLRS"):
			_add_mlrs_variants(pack, w, def, out, _rocket_lifetimes(pack))
		out[def.id] = def
	return out


static func _num(v, default: float) -> float:
	return float(v) if (v is int or v is float) else default


static func _table_kind(w: Dictionary, row: Dictionary) -> String:
	var cls: String = w.get("class", "projectile")
	if cls.begins_with("beam"):
		return "beam"
	if cls == "grenade":
		return "grenade"
	if cls == "ecm":
		return "ecm"
	if String(w.name).begins_with("MLRS") or row.get("type_name", "") == "missile":
		return "missile"
	return "cannon"


## The weapon's projectile row; missiles and grenades without one use the shared default rows.
static func _projectile_row(raw: Dictionary, kind: String, rows: Array) -> Dictionary:
	var row := raw
	if kind == "missile" and row.is_empty() and rows.size() > DEFAULT_MISSILE_ROW:
		row = rows[DEFAULT_MISSILE_ROW]
	if kind == "grenade" and row.is_empty() and rows.size() > DEFAULT_GRENADE_ROW:
		row = rows[DEFAULT_GRENADE_ROW]
	return row


## Refire seconds and projectile speed (code units, m/s at the game's own scale).
func _timing(pack: String, w: Dictionary, row: Dictionary, dv: Dictionary) -> Dictionary:
	var u: Dictionary = catalog.units.get(pack, {})
	var refire_s := _num(w.get("refire_delay"), 1000.0) * _num(u.get("refire", {}).get("to_seconds"), 0.001)
	if dv.get("refire_s") != null:
		refire_s = _num(dv.refire_s, refire_s)
	var speed_code := 0.0
	if dv.get("projectile_speed_mps") != null:
		speed_code = _num(dv.get("projectile_speed_mps"), float(0.0))
	if speed_code <= 0.0:
		speed_code = maxf(_num(row.get("speed_or_limit"), float(0)), 0.0) * _num(u.get("projectile_speed", {}).get("to_mps"), 0.06)
	return {"refire": refire_s, "speed": speed_code}


func _table_weapon(pack: String, w: Dictionary, rows: Array, dv: Dictionary) -> Dictionary:
	var name := String(w.name)
	var raw := _raw_row(w)
	var kind := _table_kind(w, raw)
	var row := _projectile_row(raw, kind, rows)
	var timing := _timing(pack, w, row, dv)
	var def := {
		"id": "%s:%s" % [pack, w.name], "pack": pack, "name": w.name, "kind": kind,
		"range": _num(w.get("range"), DEFAULT_RANGE_UNITS) * catalog.metres_per_unit(pack),
		"refire": timing.refire,
		"ammo": int(_num(w.get("ammo"), 0)) if kind in ["cannon", "missile", "grenade"] else -1,
		"per_shot": int(_num(w.get("per_shot"), 0)),
		"min_charge": int(_num(w.get("min_charge"), 0)),
		"beams": int(_num(w.get("beams"), 1)),
		"shield_damage": _num(row.get("shield_damage"), DEFAULT_DAMAGE),
		"armor_damage": _num(row.get("armor_damage"), DEFAULT_DAMAGE),
		"splash": _num(row.get("splash_per1024"), float(0)) / SPLASH_DENOMINATOR,
		"speed": timing.speed * catalog.code_to_world(pack),
		"muzzle": [w.get("muzzle_x", 0), w.get("muzzle_y", 0), w.get("muzzle_z", 0)],
		"shapes": [w.get("shape_group0", -1), w.get("shape_group1", -1), w.get("shape_group2", -1), w.get("shape_group3", -1)],
		"model": _table_pod_model(w),
		"fx": w.get("fx") if w.get("fx") is Dictionary else null,
	}
	if kind == "cannon" and def.ammo > 0 and def.per_shot > 0:
		def.ammo = def.ammo / def.per_shot
	# energy weapons: the table row is damage per 1024 capacitor charge; a shot does
	# row * charge_spent / 1024 (ES1/ES2 code, docs/formats/es2.md section 9)
	def["charge_scaled"] = kind == "beam"
	def["size_class"] = ES1_SIZE.get(name, "heavy" if name.ends_with("_CYBRID") else "medium")
	def["hardpoint_mask"] = SIZE_MASK[def.size_class]
	def["cybrid_only"] = name.ends_with("_CYBRID")
	def["category"] = "herc"
	# size class from the ES1 GL hardpoint mask the weapon needs (WeaponFit ladder)
	def["size"] = WeaponFit.size_for_weapon_mask(def.hardpoint_mask)
	def["display_name"] = name
	_apply_special_effects(def, name)
	_apply_bullet_projectile(def, row)
	return def


## EMP rows are bullets in the original (projectile table type 2: a flying bitmap ball, bullet.cpp), not
## instant bolts: they fly at the row's speed while still paying from the capacitor.
static func _apply_bullet_projectile(def: Dictionary, row: Dictionary) -> void:
	if def.kind == "emp" and row.get("type_name", "") == "bullet" and float(def.speed) > 0.0:
		def["projectile"] = {"speed": def.speed, "guidance": "none"}


## Pod placement data of a 3Space v1 weapon record (weapon_mounts.md section 1): the pod's half extent
## (+0x46 x, +0x48, +0x4a z; DBSIM 0xbbd4 pushes the pod out by it per mount group) and the muzzle
## (+0x40..0x44, pod frame; DBSIM 0xadd4), original units.
static func _table_pod_model(w: Dictionary) -> Dictionary:
	return {"pod_extent": [w.get("unknown_46", 0), w.get("unknown_48", 0), w.get("unknown_4a", 0)],
		"muzzle_units": [w.get("muzzle_x", 0), w.get("muzzle_y", 0), w.get("muzzle_z", 0)]}


static func _raw_row(w: Dictionary) -> Dictionary:
	var row = w.get("projectile_row")
	return row if row is Dictionary else {}


static func _apply_special_effects(def: Dictionary, name: String) -> void:
	if name == "ELF":
		def["effects"] = {"elf_leech": ELF_LEECH}
	elif name.begins_with("EMP"):
		def["kind"] = "emp"
		def["effects"] = {"emp_shield_drain": def.shield_damage}


## The original rack takes a missile type chosen at loadout: one catalog entry per guidance type
## (the plain entry stays, homing actively).
static func _add_mlrs_variants(pack: String, w: Dictionary, def: Dictionary, out: Dictionary, lifetimes: Array) -> void:
	def["burst"] = MLRS_BURST
	def["burst_interval"] = MLRS_BURST_INTERVAL
	var types := ES1_MISSILE_GUIDANCE.keys()
	for mt in types:
		var v: Dictionary = def.duplicate(true)
		v.id = "%s:%s_%s" % [pack, w.name, mt]
		v.name = "%s_%s" % [w.name, mt]
		v.display_name = "%s (%s)" % [w.name, mt]
		v["projectile"] = {"speed": def.speed, "guidance": ES1_MISSILE_GUIDANCE[mt],
			"turn_rate_deg": make_missile_turn_rate_deg(), "trail": "smoke"}
		var row := types.find(mt)
		if mt == "EO" and row < lifetimes.size():
			v.projectile["lifetime"] = lifetimes[row]
		out[v.id] = v
	def["projectile"] = {"speed": def.speed, "guidance": "arh", "turn_rate_deg": make_missile_turn_rate_deg(), "trail": "smoke"}


## The missiles' turn cap in degrees per second (about 70.3 at 10 Hz).
static func make_missile_turn_rate_deg() -> float:
	return MISSILE_TURN_PER_FRAME / ANGLE_UNITS_PER_TURN * 360.0 * Packs.TICK_HZ


## Rocket lifetimes in seconds per missile type (row), from the pack's rocket table; [] when it has none.
static func _rocket_lifetimes(pack: String) -> Array:
	var j = Assets.load_json(PROJECTILES_FILE, pack)
	var out := []
	if j is Dictionary:
		for r in j.get("rockets", []):
			out.append(_num(r.get(ROCKET_LIFETIME_FIELD), 0.0) / Packs.TICK_HZ)
	return out


## Weapons already converted to the engine schema (docs/formats/weapon_schema.md).
static func _engine_weapons(pack: String, eng: Dictionary) -> Dictionary:
	var out := {}
	for w in eng.get("weapons", []):
		var def := _engine_weapon(pack, w)
		if def.category == WeaponFit.HERC_FAMILY:
			# size class from the game's own hardpoint mask (ES2 INI_*.DAT vs GL masks, Starsiege
			# datWeapon.cs size letter, Battledrome record bay list; weapon_schema.md)
			def["size"] = WeaponFit.size_for_weapon_mask(def.hardpoint_mask)
		out[def.id] = def
	return out


static func _engine_weapon(pack: String, w: Dictionary) -> Dictionary:
	var dmg: Dictionary = w.get("damage", {})
	var en: Dictionary = w.get("energy", {}) if w.get("energy") is Dictionary else {}
	var pr = w.get("projectile")
	var size: String = w.get("size_class", "medium")
	return {
		"id": "%s:%s" % [pack, w.name], "pack": pack, "name": w.name,
		"display_name": w.get("display_name", w.name), "kind": w.get("kind", "cannon"),
		"range": _num(w.get("range"), 200.0), "refire": _num(w.get("refire"), 1.0),
		"burst": int(_num(w.get("burst"), 1.0)), "burst_interval": _num(w.get("burst_interval"), 0.0),
		"spread_deg": _num(w.get("spread_deg"), 0.0), "ammo": int(_num(w.get("ammo"), -1.0)),
		"per_shot": int(_num(en.get("per_shot"), 0.0)), "min_charge": int(_num(en.get("min_charge"), 0.0)),
		"beams": int(_num((w.get("beam") if w.get("beam") is Dictionary else {}).get("count"), 1.0)),
		"shield_damage": _num(dmg.get("shield"), 500.0), "armor_damage": _num(dmg.get("armor"), 500.0),
		"splash": _num(dmg.get("splash"), 0.0), "splash_radius": _num(dmg.get("splash_radius"), 0.0),
		"damage_type": str(dmg.get("type", "")),
		"effects": w.get("effects", {}) if w.get("effects") is Dictionary else {},
		"speed": _num(pr.get("speed"), 0.0) if pr is Dictionary else 0.0,
		"projectile": pr if pr is Dictionary else null,
		"beam": w.get("beam"), "sounds": w.get("sounds", {}) if w.get("sounds") is Dictionary else {},
		"size_class": size,
		"hardpoint_mask": int(_num(w.get("hardpoint_mask"), float(SIZE_MASK.get(size, 15)))),
		"model": w.get("model", {}), "shapes": [],
		"cybrid_only": w.get("cybrid_only", false),
		"category": w.get("category", "herc"),
		"fire_group": int(_num(w.get("fire_group"), 0.0)),
		"fx": w.get("fx") if w.get("fx") is Dictionary else null,
	}

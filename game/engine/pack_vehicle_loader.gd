class_name PackVehicleLoader
extends RefCounted
## Builds the catalog vehicle definitions of one pack for Packs from gameplay/hercs.json, in one of
## three forms: engine-schema records ("engine_schema": 1), Battledrome unit records ("price"), or
## 3Space v1 Herc records (ES1/ES2) converted with the pack's units.json (docs/formats/units.md).
## Weapons must be loaded first (loadouts are checked against the weapon catalog).

const WEIGHTS := ["light", "medium", "heavy", "cybrid"]
const BD_WEIGHTS := ["light", "medium", "heavy"]
const BD_TEXTURE_SETS := ["LIGHT", "MEDIUM", "HEAVY"]
const KMH_PER_MPS := 3.6
## Battledrome: raw word 20 = torso yaw limit, 21 = torso pitch limit (angle units).
const BD_TORSO_LIMIT_WORD := 20
const BD_PITCH_LIMIT_WORD := 21
const BD_DEFAULT_TORSO_LIMIT := 8190.0
const BD_DEFAULT_PITCH_LIMIT := 5460.0
## Battledrome mass field is in quarter units.
const BD_MASS_FACTOR := 4.0
## Battledrome reaches top speed in this many seconds (no accel field decoded).
const BD_ACCEL_SECONDS := 2.5
const BD_TORSO_RATE_DEG := 55.0
## SIM.EXE Animate (0x2a880) torso lookup sequences: 3 = torso pitch, 4 = torso yaw (animation.md).
const BD_PITCH_SEQ := 3
const BD_YAW_SEQ := 4
## 3Space node 0 is the ground tracker, never a torso node.
const GROUND_NODE := 0
## ES1/ES2 lookup sequences: a node turned less than this (angle units, ~5.6 deg) only rides along
## (Bulldog yaw lookup: node 6 by 16 units, the turret node 19 by a full turn).
const ES_LOOKUP_MIN_TURN := 1024
const ANGLE_UNITS_PER_TURN := 65536
const BD_PITCH_RATE_DEG := 44.0
## Weapons by weight class until the AI loadouts are known (gameplay/loadouts.json).
const BD_FALLBACK_WEAPONS := [["LAS200", "ATC20"], ["LAS200", "ATC35", "MLRS6"], ["LAS300", "ATC50", "LAS200", "MLRS8"]]
const MS_PER_S := 1000.0
const ENGINE_FLOAT_FIELDS := ["mass", "max_speed", "reverse_speed", "accel", "turn_rate", "torso_rate", "torso_limit",
	"pitch_rate", "pitch_max", "pitch_min", "shield_max", "shield_recharge", "capacitor_rate", "height_m"]
const ENGINE_REQUIRED_FIELDS := ["max_speed", "reverse_speed", "accel", "turn_rate", "mass"]
## Max signed 16-bit angle (torso limits above it mean "unlimited").
const MAX_ANGLE_UNITS := 32767.0
## 3Space anim rates: 256 = the authored speed.
const ANIM_RATE_UNITS := 256.0

var catalog: Node   # the Packs autoload (units, packs, weapons, metres_per_unit, code_to_world)


func _init(packs_catalog: Node) -> void:
	catalog = packs_catalog


## All vehicle definitions of a pack (id -> def).
func load_pack(pack: String) -> Dictionary:
	var j = Assets.load_json("gameplay/hercs.json", pack)
	if j == null:
		return {}
	var out := {}
	var derived := {}
	for x in catalog.units.get(pack, {}).get("hercs", []):
		derived[String(x.unit)] = x
	for key in j:
		var h: Dictionary = j[key]
		var v: Dictionary
		if h.has("engine_schema"):
			v = _engine_vehicle(pack, key, h)
		elif h.has("price"):
			v = _bd_vehicle(pack, key, h, derived.get(String(h.get("shape", key)), derived.get(key, {})))
		else:
			v = _herc_vehicle(pack, key, h, derived.get(key, {}))
		WeaponFit.apply_hardpoint_sizes(v)
		out[v.id] = v
	return out


static func _num(v, default: float) -> float:
	return float(v) if (v is int or v is float) else default


func _has_weapon(wid: String) -> bool:
	return catalog.weapons.has(wid)


# ------------------------------------------------------------------ 3Space v1 Herc records

## Rate conversions of a pack's units.json (original per-tick values -> per second).
func _rates(pack: String) -> Dictionary:
	var u: Dictionary = catalog.units.get(pack, {})
	var default_rate := Packs.ANGLE * Packs.TICK_HZ
	return {"turn": float(u.get("turn_rate", {}).get("to_rad_per_s", default_rate)),
		"torso": float(u.get("torso_rate", {}).get("to_rad_per_s", default_rate)),
		"shield": float(u.get("shield_recharge", {}).get("to_per_second", Packs.TICK_HZ)),
		"beam": float(u.get("beam_charge", {}).get("to_per_second", Packs.TICK_HZ)),
		"anim_tick_ms": float(u.get("anim_tick_seconds", 0.001)) * 1000.0}


func _herc_vehicle(pack: String, key: String, h: Dictionary, d: Dictionary) -> Dictionary:
	var id := "%s:%s" % [pack, key]
	var sz := int(h.get("size_class", 1))
	var k: float = catalog.code_to_world(pack)
	var r := _rates(pack)
	var v := {
		"id": id, "pack": pack, "shape": id, "name": h.get("name", key), "category": "herc",
		"side": h.get("side", "herc"),
		"pilotable": h.get("side", "herc") in ["herc", "cybrid"] and is_armed(h),
		"flyer": h.get("flyer", false),
		"flight_model": h.get("flight_model", []),
		"size_class": sz,
		"weight": WEIGHTS[clampi(sz, 0, 3)],
		"mass": float(h.get("mass", 6000)),
		"max_speed": float(d.get("top_speed_mps", float(h.get("speed_forward_max", 200)) * 0.1)) * k,
		"reverse_speed": float(d.get("reverse_kmh", 25.0)) / KMH_PER_MPS * k,
		"accel": float(d.get("accel_mps2", 20.0)) * k,
		"turn_rate": float(h.get("turn_rate_max", 600)) * r.turn,
		"torso_rate": float(h.get("torso_yaw_rate", 1000)) * r.torso,
		"torso_limit": minf(float(h.get("torso_yaw_limit", 14000)), MAX_ANGLE_UNITS) * Packs.ANGLE,
		"pitch_rate": float(h.get("torso_pitch_rate", 800)) * r.torso,
		"pitch_max": float(h.get("torso_pitch_max", 8000)) * Packs.ANGLE,
		"pitch_min": float(h.get("torso_pitch_min", -8000)) * Packs.ANGLE,
		"shield_max": float(h.get("shield_max", 3500)),
		"shield_recharge": float(h.get("shield_recharge_per_frame", 4.0)) * r.shield,
		"capacitor_rate": 20.0 * r.beam,
		"shield_radius": float(h.get("shield_radius", 1500)) * catalog.metres_per_unit(pack),
		# contact sphere (DAT 0x6e, returned by the mech vtable slot 0x60 at DBSIM 0x10ec8; collisions 0x14174)
		"collision_radius": float(h.get("unknown_6e", 0)) * catalog.metres_per_unit(pack),
		# DAT 0x4a: blows itself up on contact (the Spider); the simulator's rules: tools/self_destruct_rules.py
		"self_destruct": _self_destruct(pack, h),
		# each damage component's point (COL: its part and first sphere centre; DBSIM vtable slot 0x5c 0x15990)
		"component_points": _component_points(h),
		"guns": h.get("guns", []),
		"damage": h.get("damage", {}),
		"height_m": float(d.get("height_m", 0.0)) * k,
		# ground metres per speed unit for the walk/run sequences (the original moves Hercs by
		# their animations' ground displacement; speed field = animation rate, 256 = 1x)
		"walk_factor": float(d.get("walk_mps_per_speed_unit", 0.0)) * k,
		"run_factor": float(d.get("run_mps_per_speed_unit", 0.0)) * k,
		"run_switch_speed": float(d.get("walk_run_switch_speed", 160)) * float(d.get("walk_mps_per_speed_unit", 0.05)) * k,
		# animation tick length at rate 256 (ES1 1 ms, ES2 1.25 ms): converts the factors to strides
		"anim_tick_ms": r.anim_tick_ms,
		"anim": _es_anim(h, d, r.anim_tick_ms),
		"cockpit": h.get("file", key) if FileAccess.file_exists(Assets.path("cockpits/%s_0.png" % key, pack)) else "",
	}
	if not bool(v.flyer):
		v.merge(_es_torso_nodes(Assets.shape(id), h), true)
	v["loadout"] = _listed_loadout(pack, h) if h.get("loadout") is Array else default_loadout(v)
	return v


## ES1/ES2 torso twist / pitch nodes. DAT +0x1a / +0x22 (hercs.json `torso_yaw_node` / `torso_pitch_node`,
## misnamed) are lookup SEQUENCE ids, not nodes: DBSIM 0x11652 / 0x11682 start an anim thread on that
## sequence (0x1f48) and 0x14ac8 sets its position to yaw >> 2 (0x620c4: sequence list +6, frame lengths
## summed). Hercs: seq 0 turns node 4, seq 5 node 11 (the old defaults); Bulldog seq 0 / 7 turn nodes
## 19 / 20, Pitbull 6 / 19, Headhunter 5 / 12 (its seq 5 also turns node 4), Spider none (-1). -1 = no twist / no pitch node.
## The Spider's self-destruct rules in engine units ({} for every other unit): blast radius in metres, damage
## and timings as the simulator has them (gameplay.md section 2, DAT 0x4a).
func _self_destruct(pack: String, h: Dictionary) -> Dictionary:
	var r = h.get("self_destruct_rules")
	if int(h.get("self_destruct", 0)) == 0 or not (r is Dictionary):
		return {}
	var mpu: float = catalog.metres_per_unit(pack)
	return {"blast_radius_m": float(r.blast_radius) * mpu, "blast_damage": float(r.blast_damage),
		"self_damage": float(r.self_damage), "component_hit_chance": float(r.component_hit_chance),
		"walk_s": [float(r.walk_ms[0]) / MS_PER_S, float(r.walk_ms[1]) / MS_PER_S],
		"lunge_s": [float(r.lunge_ms[0]) / MS_PER_S, float(r.lunge_ms[1]) / MS_PER_S],
		"lunge_steps": int(r.lunge_steps), "retarget_s": float(r.retarget_ms) / MS_PER_S,
		"shields_absorb": bool(r.shields_absorb), "skips_self": bool(r.skips_self),
		"reach_adds_unit_radius": bool(r.reach_adds_unit_radius)}


## Component index -> [part id, [x, y, z] original units] from the COL sphere sets ([] where none: such a
## component sits at the unit's centre, as slot 0x5c falls back to it).
static func _component_points(h: Dictionary) -> Array:
	var out := []
	for entry in h.get("collision", []):
		for part in entry.get("parts", []):
			var i := int(part.get("component", -1))
			var spheres: Array = part.get("spheres", [])
			if i < 0 or spheres.is_empty():
				continue
			while out.size() <= i:
				out.append([])
			if (out[i] as Array).is_empty():
				var c: Array = spheres[0]
				out[i] = [int(entry.get("node", -1)), [c[0], c[1], c[2]]]
	return out


static func _es_torso_nodes(shape: Dictionary, h: Dictionary) -> Dictionary:
	var torso := _es_lookup_node(shape, int(h.get("torso_yaw_node", -1)), -1)
	return {"torso_node": torso, "cockpit_node": _es_lookup_node(shape, int(h.get("torso_pitch_node", -1)), torso)}


## Topmost node lookup sequence `seq` really turns (riders below ES_LOOKUP_MIN_TURN ignored); of several,
## the one under `prefer_under` (the pitch node that twists with the torso), else the lowest index.
static func _es_lookup_node(shape: Dictionary, seq: int, prefer_under: int) -> int:
	var seqs: Array = shape.get("sequences", [])
	if seq < 0 or seq >= seqs.size():
		return -1
	var turned := {}
	var parts: Array = seqs[seq].get("parts", [])
	for p in parts.size():
		if int(parts[p]) != GROUND_NODE and _lookup_turn(shape, seqs[seq], p) >= ES_LOOKUP_MIN_TURN:
			turned[int(parts[p])] = true
	var roots: Array = turned.keys().filter(func(i): return not _has_ancestor_in(shape.nodes, i, turned))
	if roots.is_empty():
		return -1
	roots.sort()
	for i in roots:
		if prefer_under >= 0 and _has_ancestor_in(shape.nodes, i, {prefer_under: true}):
			return i
	return roots[0]


## Largest rotation (angle units, wrapped) of part `p` away from its first frame over the sequence.
static func _lookup_turn(shape: Dictionary, seq: Dictionary, p: int) -> int:
	var n: int = seq.parts.size()
	var first: Array = shape.transforms[int(seq.tf[p])]
	var most := 0
	for f in seq.frames.size():
		var tf: Array = shape.transforms[int(seq.tf[f * n + p])]
		for axis in 3:
			var d := posmod(int(tf[axis]) - int(first[axis]), ANGLE_UNITS_PER_TURN)
			most = maxi(most, mini(d, ANGLE_UNITS_PER_TURN - d))
	return most


## ES1/ES2 gait sequences (docs/formats/animation.md): walk/run ids from units.json (DAT +0x0c/+0x0e),
## turn in place DAT +0x7a, collapse DAT +0x44 (hercs.json anim_seq_7a / anim_seq_shutdown).
static func _es_anim(h: Dictionary, d: Dictionary, tick_ms: float) -> Dictionary:
	if d.get("walk_seq") == null:
		return {}
	return {"walk": int(d.walk_seq), "run": int(d.get("run_seq", d.walk_seq)),
		"turn": int(h.get("anim_seq_7a", -1)), "death": int(h.get("anim_seq_shutdown", -1)),
		"tick_seconds": tick_ms / 1000.0}


## Battledrome gait sequences from units.json (SIM.EXE Animate, docs/formats/animation.md): run above the
## anim rate w24, collapse at the fixed rate w25.
func _bd_anim(pack: String, d: Dictionary) -> Dictionary:
	if d.get("walk_seq") == null:
		return {}
	return {"stand": int(d.stand_seq), "walk": int(d.walk_seq), "run": int(d.run_seq), "turn": int(d.turn_seq),
		"death": int(d.death_seq),
		"run_switch_rate": float(d.get("anim_rate_run_threshold", ANIM_RATE_UNITS)) / ANIM_RATE_UNITS,
		"death_rate": float(d.get("anim_rate_seq6", ANIM_RATE_UNITS)) / ANIM_RATE_UNITS,
		"tick_seconds": float(catalog.units.get(pack, {}).get("anim_tick_seconds", 0.001))}


## A unit's own default loadout from hercs.json (weapon names of its pack, one per hardpoint;
## null = empty hardpoint). Unknown weapons become empty hardpoints.
func _listed_loadout(pack: String, h: Dictionary) -> Array:
	var out := []
	for n in h.loadout:
		var wid := "" if n == null else (String(n) if String(n).contains(":") else "%s:%s" % [pack, n])
		out.append(wid if _has_weapon(wid) else "")
	return out


# ------------------------------------------------------------------ engine-schema records

## Vehicle records already in engine units ("engine_schema": 1, e.g. tools/export_starsiege_gameplay.py):
## metres, m/s, rad, Earthsiege damage scale; "default_loadout" = weapon id per hardpoint.
func _engine_vehicle(pack: String, key: String, h: Dictionary) -> Dictionary:
	var v: Dictionary = h.duplicate(true)
	v["id"] = "%s:%s" % [pack, key]
	v["pack"] = pack
	v["shape"] = Assets.qualify(String(h.get("shape", key)), pack)
	v["name"] = String(h.get("name", key))
	v["category"] = String(h.get("category", "herc"))
	v["side"] = String(h.get("side", "herc"))
	v["flyer"] = String(h.get("kind", "")) == "flyer"
	v["pilotable"] = _is_player_vehicle(h, v.flyer)
	var sz := int(_num(h.get("size_class"), 1.0))
	v["size_class"] = sz
	v["weight"] = String(h.get("weight", ["light", "medium", "heavy", "heavy"][clampi(sz, 0, 3)]))
	for k in ENGINE_FLOAT_FIELDS:
		if h.has(k) and h[k] != null:
			v[k] = float(h[k])
	for k in ENGINE_REQUIRED_FIELDS:
		if not v.has(k):
			v[k] = 0.0
	v["turn_rate_still"] = _num(h.get("turn_rate_still"), float(v.turn_rate))
	if h.get("run_switch_speed") == null:
		v.erase("run_switch_speed")
	v["guns"] = h.get("guns", [])
	v["damage"] = h.get("damage", {})
	v["cockpit"] = String(h.get("cockpit", ""))
	var lo := []
	for w in h.get("default_loadout", []):
		var wid := Assets.qualify(String(w), pack) if w != null and String(w) != "" else ""
		lo.append(wid if _has_weapon(wid) else "")
	v["loadout"] = lo if not lo.is_empty() else default_loadout(v)
	return v


# ------------------------------------------------------------------ Battledrome records

## Battledrome unit records: per-Herc speeds/turn rates from units.json (code-derived), scaled to
## the shared world; weapons from the weapon pack (Earthsiege) by weight until BD pods are decoded.
func _bd_vehicle(pack: String, key: String, h: Dictionary, d: Dictionary) -> Dictionary:
	var k: float = catalog.code_to_world(pack)
	var sz := clampi(BD_TEXTURE_SETS.find(String(h.get("texture_set", "MEDIUM"))), 0, 2)
	var raw: Array = h.get("raw_words", [])
	var top_kmh := float(d.get("top_speed_kmh_animated", d.get("top_speed_kmh_nominal", 40.0)))
	var torso_limit := float(raw[BD_TORSO_LIMIT_WORD]) if raw.size() > BD_TORSO_LIMIT_WORD else BD_DEFAULT_TORSO_LIMIT
	var pitch_limit := float(raw[BD_PITCH_LIMIT_WORD]) if raw.size() > BD_PITCH_LIMIT_WORD else BD_DEFAULT_PITCH_LIMIT
	var v := {
		"id": "%s:%s" % [pack, key], "pack": pack, "shape": "%s:%s" % [pack, h.get("shape", key)], "category": "herc",
		"name": String(h.get("name", key)).capitalize(), "side": "herc", "pilotable": true,
		"size_class": sz, "weight": BD_WEIGHTS[sz],
		"mass": float(h.get("mass?", 2000)) * BD_MASS_FACTOR,
		"max_speed": top_kmh / KMH_PER_MPS * k,
		"reverse_speed": float(d.get("reverse_kmh", 21.0)) / KMH_PER_MPS * k,
		"accel": top_kmh / KMH_PER_MPS * k / BD_ACCEL_SECONDS,
		"turn_rate": deg_to_rad(float(d.get("turn_rate_moving_deg_s", 20.0))),
		"turn_rate_still": deg_to_rad(float(d.get("turn_rate_in_place_deg_s", 30.0))),
		"torso_rate": deg_to_rad(BD_TORSO_RATE_DEG),
		"torso_limit": torso_limit * Packs.ANGLE,
		"pitch_rate": deg_to_rad(BD_PITCH_RATE_DEG),
		"pitch_max": pitch_limit * Packs.ANGLE,
		"pitch_min": -pitch_limit * Packs.ANGLE,
		"shield_max": 3500.0, "shield_recharge": 40.0, "capacitor_rate": 200.0,
		"height_m": float(d.get("height_m", 0.0)) * k,
		"guns": [], "damage": {}, "cockpit": "", "price": h.get("price", 0),
		"anim": _bd_anim(pack, d),
	}
	v.merge(_bd_torso_nodes(Assets.shape(String(v.shape))), true)
	var mounts := _bd_mounts(pack, String(h.get("shape", key)), sz)
	v["guns"] = mounts.guns
	v["loadout"] = mounts.loadout
	return v


## Torso yaw node = the node the yaw lookup sequence turns, cockpit (pitch + view) node = the pitch
## lookup's (Stryder 11 / 12, Talon 13 / 13, Slayer 13 / 14); the 3Space defaults 4 / 11 are a leg on the
## Talon, Nomad and Slayer.
static func _bd_torso_nodes(shape: Dictionary) -> Dictionary:
	var yaw := _lookup_root(shape, BD_YAW_SEQ)
	var pitch := _lookup_root(shape, BD_PITCH_SEQ)
	if yaw < 0 or pitch < 0:
		return {}
	return {"torso_node": yaw, "cockpit_node": pitch}


## Topmost node a lookup sequence turns; sibling nodes turned together give their parent (the Talon yaws
## its three pod nodes). -1 = none.
static func _lookup_root(shape: Dictionary, seq: int) -> int:
	var seqs: Array = shape.get("sequences", [])
	if seq < 0 or seq >= seqs.size():
		return -1
	var turned := {}
	for p in seqs[seq].get("parts", []):
		if int(p) != GROUND_NODE:
			turned[int(p)] = true
	var roots := turned.keys().filter(func(i): return not _has_ancestor_in(shape.nodes, i, turned))
	if roots.size() == 1:
		return roots[0]
	var parents := {}
	for i in roots:
		parents[int(shape.nodes[i].parent)] = true
	return parents.keys()[0] if parents.size() == 1 else -1


static func _has_ancestor_in(nodes: Array, i: int, turned: Dictionary) -> bool:
	var p := int(nodes[i].parent)
	while p >= 0:
		if turned.has(p):
			return true
		p = int(nodes[p].parent)
	return false


## Real hardpoints (pods / mine pod / missile pods) with muzzle positions and the AI pilots' most
## common loadout (gameplay/loadouts.json from tools/export_bd_weapons.py), else generic mounts.
func _bd_mounts(pack: String, shape_key: String, sz: int) -> Dictionary:
	var lj = Assets.load_json("gameplay/loadouts.json", pack)
	var guns := []
	var lo := []
	if lj is Dictionary and lj.get("pods", {}).has(shape_key):
		var slots: Array = lj.get(shape_key, [])
		for p in lj.pods[shape_key]:
			var gun := {"hardpoint_mask": int(p.get("hardpoint_mask", 7)), "mount_node": -1,
				"muzzle_units": p.get("muzzle_units"), "name": p.get("hardpoint", ""), "bay": p.get("bay", "")}
			gun.merge(_bd_muzzle_on_node(p), true)
			gun.merge(_bd_baked_pod(p), true)
			guns.append(gun)
			var slot := int(p.get("slot", 0))
			var wname = slots[slot] if slot < slots.size() else null
			lo.append("%s:%s" % [pack, wname] if wname != null else "")
	else:
		var wpack: String = catalog.packs.get(pack, {}).get("weapon_pack", pack)
		for n in BD_FALLBACK_WEAPONS[sz]:
			guns.append({"hardpoint_mask": 31, "mount_node": -1})
			lo.append("%s:%s" % [wpack, n])
	return {"guns": guns, "loadout": lo}


## The muzzle on the pod's own node (logical part node, the torso; bd_weapons.md section 6: muzzle = part
## transform x offset, default node rotations 0), so the pod turns with the torso twist and pitch.
## The pod baked into the Herc shape at a bay hardpoint (bd_weapons.md section 6, weapon_mounts.md section 3):
## its cells (hidden when another game's weapon takes the hardpoint) and its box in the muzzle frame
## ("pod_box_units": loadouts.json box around the logical-part point, minus the muzzle offset).
static func _bd_baked_pod(pod: Dictionary) -> Dictionary:
	var box = pod.get("pod_box_units")
	var muzzle: Array = pod.get("muzzle_offset", [])
	if not box is Dictionary or muzzle.size() < 3:
		return {}
	var shift := func(v: Array) -> Array: return [float(v[0]) - float(muzzle[0]), float(v[1]) - float(muzzle[1]), float(v[2]) - float(muzzle[2])]
	return {"pod_cells": pod.get("pod_cells", []), "pod_box_units": {"min": shift.call(box.min), "max": shift.call(box.max)}}


static func _bd_muzzle_on_node(pod: Dictionary) -> Dictionary:
	var part: Dictionary = pod.get("logical_part", {})
	var off: Array = part.get("offset", [])
	var muzzle: Array = pod.get("muzzle_offset", [])
	if int(part.get("node", -1)) < 0 or off.size() < 3 or muzzle.size() < 3:
		return {}
	return {"attach_node": int(part.node), "muzzle_units": [float(off[0]) + float(muzzle[0]),
		float(off[1]) + float(muzzle[1]), float(off[2]) + float(muzzle[2])]}


# ------------------------------------------------------------------ default loadouts

## Picks a sensible weapon for each hardpoint from the hardpoint size mask.
func default_loadout(v: Dictionary) -> Array:
	var pack: String = v.pack
	var out := []
	var heavy_toggle := false
	for g in v.guns:
		var mask := int(g.get("hardpoint_mask", 15))
		var name := "LAS100"
		if v.side == "cybrid":
			name = "PBEAM_CYBRID" if mask >= 31 else ("LAS200" if mask >= 15 else "MISSL_CYBRID")
		else:
			match v.weight:
				"light":
					name = "LAS200" if mask >= 31 else ("LAS100" if mask >= 15 else "MLRS6")
				"medium":
					name = "ATC35" if mask >= 31 else ("LAS200" if mask >= 15 else "MLRS6")
				_:
					heavy_toggle = not heavy_toggle
					name = ("LAS300" if heavy_toggle else "ATC50") if mask >= 31 else ("LAS200" if mask >= 15 else "MLRS8")
		var wid := "%s:%s" % [pack, name]
		if not _has_weapon(wid):
			wid = "%s:LAS100" % pack
		out.append(wid)
	return out


## A player can field a vehicle only if it can carry weapons (user rule 2026-10-09): transports,
## cargo drones and unarmed scouts stay AI-only, even when the original flags them pilotable.
static func _is_player_vehicle(h: Dictionary, flyer: bool) -> bool:
	return is_armed(h) and (bool(h.get("pilotable", false)) or flyer)


## Vehicles whose weapons are part of the design (Tribes 1 / Tribes 2 vehicles, docs/formats/tribes_vehicles.md):
## the standard loadout is always fielded and never armed, unarmed, offered other weapons or salvaged.
static func has_fixed_loadout(v: Dictionary) -> bool:
	return bool(v.get("fixed_loadout", false))


## Weapon hardpoints, or fixed weapons in its standard loadout (e.g. the ES2 Landskimmer's laser).
static func is_armed(h: Dictionary) -> bool:
	if not (h.get("guns", []) as Array).is_empty():
		return true
	for key in ["loadout", "default_loadout"]:
		for w in h.get(key, []):
			if w != null and str(w) != "":
				return true
	return false

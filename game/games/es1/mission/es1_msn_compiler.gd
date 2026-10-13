extends MsnRecordCompiler
## Earthsiege 1 MSN compiler (GO.EXE 0x3276c; tools/mission.py Compiler). Used as
## MissionCompiler.Compiler; see MsnRecordCompiler for the shared record rules.

## Campaign terrain of the 8 Earthsiege campaigns (header word 0 in campaign mode).
const CAMPAIGN_TERRAIN := [1, 2, 2, 0, 0, 3, 3, 3]
const OP_EQUAL := 0x114
const OP_NOT_EQUAL := 0x115
const OP_LESS := 0x116
const OP_GREATER := 0x117
const HEADER_WORDS := 10
## Difficulty word set by the shell in campaign mode.
const CAMPAIGN_DIFFICULTY := 2
const TERRAIN_TYPES := 4
const HERC_COPY := ["block", "weapons", "type", "var", "op", "ammo", "f62", "health", "point", "heading",
	"alert_region", "death_region"]
const HERC_SKIP := {"block": 0, "weapons": -1, "ammo": 5, "type": -1, "point": -1, "heading": -1, "var": -1,
	"op": -1, "f62": 2, "alert_region": -1, "death_region": -1, "health": 100}
const FLYER_COPY := ["block", "point", "heading", "type", "var", "op", "alert_region", "death_region", "health"]
const FLYER_SKIP := {"block": 0, "type": -1, "point": -1, "heading": -1, "var": -1, "op": -1,
	"alert_region": -1, "death_region": -1, "health": 100}
const STRUCT_COPY := ["type", "point", "heading", "var", "op", "alert_region", "death_region", "health"]
const STRUCT_SKIP := {"type": -1, "point": -1, "heading": -1, "var": -1, "op": -1, "alert_region": -1,
	"death_region": -1, "health": 100}
const GROUP_MERGE_FIELDS := ["kind", "formation", "orders", "point", "heading", "path", "team", "target_kind",
	"target", "spawn_region", "u52", "var", "op"]

var options := {}
var R := []                # regions
var OA := []               # hercs
var OB := []               # flyers
var OC := []               # structures
var G := []                # groups


func _init(msn: Dictionary, mvars, p_rng: MissionRng, p_campaign, p_options: Dictionary) -> void:
	m = msn
	rng = p_rng if p_rng != null else MissionRng.new(-1)
	campaign = p_campaign
	mode = 1 if campaign != null else 0
	options = MissionCompiler._options(p_options)
	if mvars != null:
		vars = mvars.duplicate()
	else:
		vars = MissionCompiler.default_mission_vars(campaign, 0, p_options, rng)


func _compare(op: int, v: int, x: int) -> bool:
	match op:
		OP_EQUAL: return v == x
		OP_NOT_EQUAL: return v != x
		OP_LESS: return v < x
		OP_GREATER: return v > x
	return false


func _regions() -> Array:
	return R


func run():
	run_conditions()
	_do_header()
	_do_points()
	_do_headings()
	_do_paths()
	_do_areas()
	_do_regions()
	OA = _objs(m["herc"], HERC_COPY, HERC_SKIP)
	OB = _objs(m["flyer"], FLYER_COPY, FLYER_SKIP)
	OC = _objs(m["struct"], STRUCT_COPY, STRUCT_SKIP)
	_do_groups()
	_finish_header()
	return self


## Header: word 0 defaults to 1, the others to 0; kept records override (legacy MSNs are fixed).
func _do_header() -> void:
	var f := [1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	for h in m["hdr"]:
		if cond_ok(h["cond"]):
			var v: Array = h["f"]
			if v[0] != 1:
				f[0] = v[0]
			for i in range(1, HEADER_WORDS):
				if v[i] != 0:
					f[i] = v[i]
	if m.get("legacy", false):
		f = m["fixed_header"].duplicate()
	msn_header = f.duplicate()
	header = f


## Shell overrides: campaign mode fixes ammo/damage/difficulty and the terrain; single missions take
## the player's options and a random terrain.
func _finish_header() -> void:
	var f := header
	if mode == 1:
		f[5] = 0
		f[6] = 0
		f[7] = CAMPAIGN_DIFFICULTY
		var c: int = campaign
		if c >= 0 and c < CAMPAIGN_TERRAIN.size():
			f[0] = CAMPAIGN_TERRAIN[c]
	else:
		f[5] = options["ammo"]
		f[6] = options["damage"]
		f[7] = options["difficulty"]
		f[8] = options["visibility"]
		f[9] = options["time_of_day"]
		f[0] = rng.call_n(TERRAIN_TYPES)
	f[2] = mode
	header = f


func _do_regions() -> void:
	var arr := []
	var na := A.size()
	for r0 in m["region"]:
		var r: Dictionary = r0.duplicate()
		if not cond_ok(r["cond"]):
			continue
		var n := arr.size()
		var ai := []
		for x in r["areas"]:
			ai.append(sidx(A, na, x) if x != -1 else -1)
		r["ai"] = ai
		var dup := sidx(arr, n, r["id"])
		if dup != -1 and dup < n:
			var o: Dictionary = arr[dup]
			for k in ["type", "param", "var", "op"]:
				if r[k] != -1:
					o[k] = r[k]
			o["ai"] = _zip_keep(o["ai"], r["ai"], -1)
		else:
			arr.append(r)
	R = arr


func _do_groups() -> void:
	var arr := []
	for g0 in m["group"]:
		var g: Dictionary = g0.duplicate()
		if not cond_ok(g["cond"]):
			continue
		var n := arr.size()
		_resolve_group_refs(g, arr, n)
		var dup := sidx(arr, n, g["id"])
		if dup != -1 and dup < n:
			_merge_group(arr[dup], g)
		else:
			arr.append(g)
	G = arr


func _member_tables() -> Dictionary:
	return {0: OA, 1: OB, 2: OC}


## Group references: target kind 0 = an earlier group, 1..3 = herc / flyer / structure, else raw.
func _resolve_group_refs(g: Dictionary, arr: Array, n: int) -> void:
	var tbls := _member_tables()
	g["point_i"] = sidx(P, P.size(), g["point"])
	g["heading_i"] = sidx(H, H.size(), g["heading"])
	g["path_i"] = sidx(T, T.size(), g["path"])
	g["spawn_region_i"] = sidx(R, R.size(), g["spawn_region"])
	var tk: int = g["target_kind"]
	if tk == 0:
		g["target_i"] = sidx(arr, n, g["target"])
	elif tk >= 1 and tk <= 3:
		var t: Array = tbls[tk - 1]
		g["target_i"] = sidx(t, t.size(), g["target"])
	else:
		g["target_i"] = g["target"]
	var mt = tbls.get(g["kind"])
	var mi := []
	for x in g["members"]:
		mi.append(sidx(mt, mt.size(), x) if (x != -1 and mt != null) else -1)
	g["members_i"] = mi


static func _merge_group(o: Dictionary, g: Dictionary) -> void:
	o["block"] = _zip_keep(o["block"], g["block"], 0)
	o["members_i"] = _zip_keep(o["members_i"], g["members_i"], -1)
	o["members"] = _zip_keep(o["members"], g["members"], -1)
	_overwrite_set_fields(o, g, GROUP_MERGE_FIELDS)
	if g["target_kind"] != -1 or g["target"] != -1:
		o["target_i"] = g["target_i"] if g["target"] != -1 else o.get("target_i", -1)


## script.dat content (only records with id != -1, in order).
func script() -> Dictionary:
	var out := script_geometry()
	var rs := []
	for r in keep(R):
		rs.append([r["type"], r["param"], r["ai"], r["var"], r["op"]])
	out.merge({"header": header, "regions": rs, "hercs": keep(OA), "flyers": keep(OB), "structs": keep(OC),
		"groups": keep(G)})
	return out

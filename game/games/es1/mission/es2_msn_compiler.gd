extends MsnRecordCompiler
## Earthsiege 2 MSN compiler (VSHELL 0x417b67; tools/mission_es2.py Compiler). Used as
## MissionCompilerES2.Compiler2; see MsnRecordCompiler for the shared record rules. Adds text and
## value tables, timers, order records, objectives, briefing/debriefing records and region targets.

const OP_EQUAL := 0x119
const OP_NOT_EQUAL := 0x11a
const OP_LESS := 0x11b
const OP_LESS_EQUAL := 0x11c
const OP_GREATER := 0x11d
const OP_GREATER_EQUAL := 0x11e
const BASE_HEADER_WORDS := 10
## ES2 headers have 30 extra words (default -1).
const HEADER_WORDS := 40
const CAMPAIGN_THEATERS := 5
## Records with pick -99 are not picked (ES2 export marker).
const NOT_PICKED := -99
const HERC_COPY := ["block", "weapons", "point", "heading", "type", "n_actions", "actions", "ammo", "f88",
	"alert_region", "death_region", "health"]
const HERC_SKIP := {"block": 0, "weapons": -1, "ammo": 5, "type": -1, "point": -1, "heading": -1, "actions": -1,
	"f88": 2, "alert_region": -1, "death_region": -1, "health": 100}
const FLYER_COPY := ["block", "point", "heading", "type", "n_actions", "actions", "alert_region",
	"death_region", "health"]
const FLYER_SKIP := {"block": 0, "type": -1, "point": -1, "heading": -1, "actions": -1, "alert_region": -1,
	"death_region": -1, "health": 100}
const STRUCT_COPY := ["type", "point", "heading", "n_actions", "actions", "alert_region", "death_region",
	"health"]
const STRUCT_SKIP := {"type": -1, "point": -1, "heading": -1, "actions": -1, "alert_region": -1, "death_region": -1,
	"health": 100}
const ORDER_MERGE_FIELDS := ["type", "arg", "point", "path", "target_kind", "target", "region"]
const GROUP_MERGE_FIELDS := ["kind", "formation", "point", "heading", "path", "team", "spawn_region", "w81"]

var eng: Array
var TX := []               # texts
var text_by_id := {}
var VAL := []              # values
var value_by_id := {}
var brief = null
var deb = null
var R := []                # regions
var TM := []               # timers
var OA := []               # hercs
var OB := []               # flyers
var OC := []               # structures
var D := []                # orders
var G := []                # groups
var J := []                # objectives


func _init(msn: Dictionary, p_eng: Array, mvars, p_rng: MissionRng, p_campaign) -> void:
	m = msn
	eng = p_eng
	rng = p_rng
	campaign = p_campaign
	mode = 1 if campaign != null else 0
	if mvars != null:
		vars = mvars.duplicate()
	else:
		vars = MissionCompilerES2.default_mission_vars(campaign, 0, rng)
	while vars.size() < MissionCompilerES2.NVARS:
		vars.append(0)


func _compare(op: int, v: int, x: int) -> bool:
	match op:
		OP_EQUAL: return v == x
		OP_NOT_EQUAL: return v != x
		OP_LESS: return v < x
		OP_LESS_EQUAL: return v <= x
		OP_GREATER: return v > x
		OP_GREATER_EQUAL: return v >= x
	return false


func _regions() -> Array:
	return R


func _is_unpicked(pick: int) -> bool:
	return pick == -1 or pick == NOT_PICKED


func run():
	run_conditions()
	_do_header()
	_do_texts_and_values()
	for b in m["briefing"]:
		if cond_ok(b["cond"]):
			brief = b
	_do_points()
	_do_headings()
	_do_paths()
	_do_areas()
	_do_regions()
	_do_timers()
	OA = _objs(m["herc"], HERC_COPY, HERC_SKIP)
	OB = _objs(m["flyer"], FLYER_COPY, FLYER_SKIP)
	OC = _objs(m["struct"], STRUCT_COPY, STRUCT_SKIP)
	_do_orders()
	_do_groups()
	_do_deferred_targets()
	_do_objectives()
	for d in m["debrief"]:
		if cond_ok(d["cond"]):
			deb = d
	return self


func _do_header() -> void:
	var f := [1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	for i in HEADER_WORDS - BASE_HEADER_WORDS:
		f.append(-1)
	for h in m["hdr"]:
		if cond_ok(h["cond"]):
			_overlay_header(f, h["f"])
	msn_header = f.duplicate()
	# shell overrides (VSHELL 0x41c73d): campaign word0 = career theater (C1..C5 -> 0..4), w5/w6 = 0
	if mode == 1:
		if campaign != null and int(campaign) > 0:
			f[0] = clampi(int(campaign) - 1, 0, CAMPAIGN_THEATERS - 1)
		f[5] = 0
		f[6] = 0
	else:
		f[0] = 1
	header = f


## Word 0 overrides unless 1, words 1..9 unless 0, the extra words unless -1.
static func _overlay_header(f: Array, v: Array) -> void:
	if v[0] != 1:
		f[0] = v[0]
	for i in range(1, BASE_HEADER_WORDS):
		if v[i] != 0:
			f[i] = v[i]
	for i in range(BASE_HEADER_WORDS, HEADER_WORDS):
		if v[i] != -1:
			f[i] = v[i]


func _do_texts_and_values() -> void:
	TX = _keyed(eng, "text")
	for t in TX:
		text_by_id[t["id"]] = t["text"]
	VAL = _keyed(m["value"], "value")
	for v in VAL:
		value_by_id[v["id"]] = v["value"]


## Kept {id, field} records; a repeated id replaces the earlier record.
func _keyed(src: Array, field: String) -> Array:
	var out := []
	for r in src:
		if not cond_ok(r["cond"]):
			continue
		var dup := sidx(out, out.size(), r["id"])
		var rec := {"id": r["id"], field: r[field]}
		if dup != -1:
			out[dup] = rec
		else:
			out.append(rec)
	return out


func text(tid: int) -> Variant:
	return text_by_id.get(tid) if tid != -1 else null


func texts(ids: Array) -> Array:
	var out := []
	for t in ids:
		if t != -1 and text(t) != null:
			out.append(text(t))
	return out


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
			_merge_region(arr[dup], r)
		else:
			arr.append(r)
	R = arr


static func _merge_region(o: Dictionary, r: Dictionary) -> void:
	for k in ["type", "param", "target"]:
		if r[k] != -1:
			o[k] = r[k]
	o["message"] = r["message"]
	o["ai"] = _zip_keep(o["ai"], r["ai"], -1)
	o["actions"] = _zip_pairs(o["actions"], r["actions"])
	o["texts"] = _zip_keep(o["texts"], r["texts"], -1)
	o["n_actions"] = maxi(o["n_actions"], r["n_actions"])


func _do_timers() -> void:
	var arr := []
	var nr := R.size()
	for t0 in m["timer"]:
		var t: Dictionary = t0.duplicate()
		if not cond_ok(t["cond"]):
			continue
		var n := arr.size()
		t["trigger_i"] = sidx(R, nr, t["trigger"])
		var fi := []
		for x in t["fire"]:
			fi.append(sidx(R, nr, x) if x != -1 else -1)
		t["fire_i"] = fi
		var dup := aidx(arr, n, t["id"])
		if dup != -1:
			_merge_timer(arr[dup], t)
		else:
			arr.append(t)
	TM = arr


static func _merge_timer(o: Dictionary, t: Dictionary) -> void:
	for k in ["trigger", "delay"]:
		if t[k] != -1:
			o[k] = t[k]
	if t["trigger"] != -1:
		o["trigger_i"] = t["trigger_i"]
	o["fire_i"] = _zip_keep(o["fire_i"], t["fire_i"], -1)


## Target index of kind 1..3 (herc / flyer / structure); group targets (0) are resolved later.
func _target_i(kind: int, tid: int) -> Variant:
	if tid == -1:
		return -1
	var tables := {1: OA, 2: OB, 3: OC}
	if tables.has(kind):
		var t: Array = tables[kind]
		return sidx(t, t.size(), tid)
	return null


func _do_orders() -> void:
	var arr := []
	for r0 in m["order"]:
		var r: Dictionary = r0.duplicate()
		if not cond_ok(r["cond"]):
			continue
		var n := arr.size()
		r["point_i"] = sidx(P, P.size(), r["point"])
		r["path_i"] = sidx(T, T.size(), r["path"])
		r["region_i"] = sidx(R, R.size(), r["region"])
		r["target_i"] = _target_i(r["target_kind"], r["target"])
		var dup := aidx(arr, n, r["id"])
		if dup != -1:
			var o: Dictionary = arr[dup]
			_overwrite_set_fields(o, r, ORDER_MERGE_FIELDS)
			if r["target"] != -1:
				o["target_i"] = r["target_i"]
		else:
			arr.append(r)
	D = arr


func _do_groups() -> void:
	var arr := []
	for g0 in m["group"]:
		var g: Dictionary = g0.duplicate()
		if not cond_ok(g["cond"]):
			continue
		var n := arr.size()
		_resolve_group_refs(g)
		var dup := sidx(arr, n, g["id"])
		if dup != -1 and dup < n:
			_merge_group(arr[dup], g)
		else:
			arr.append(g)
	G = arr


func _resolve_group_refs(g: Dictionary) -> void:
	g["point_i"] = sidx(P, P.size(), g["point"])
	g["heading_i"] = sidx(H, H.size(), g["heading"])
	g["path_i"] = sidx(T, T.size(), g["path"])
	g["spawn_region_i"] = sidx(R, R.size(), g["spawn_region"])
	var mt = {0: OA, 1: OB, 2: OC}.get(g["kind"])
	var mi := []
	for x in g["members"]:
		mi.append(sidx(mt, mt.size(), x) if (x != -1 and mt != null) else -1)
	g["members_i"] = mi
	var oi := []
	for x in g["orders"]:
		oi.append(sidx(D, D.size(), x) if x != -1 else -1)
	g["orders_i"] = oi


static func _merge_group(o: Dictionary, g: Dictionary) -> void:
	o["block"] = _zip_keep(o["block"], g["block"], 0)
	for f in ["members", "members_i", "orders", "orders_i"]:
		o[f] = _zip_keep(o[f], g[f], -1)
	_overwrite_set_fields(o, g, GROUP_MERGE_FIELDS)
	o["actions"] = _zip_pairs(o["actions"], g["actions"])
	o["n_actions"] = maxi(o["n_actions"], g["n_actions"])


## Group targets of orders and the targets of regions (types 7..10) need the final tables.
func _do_deferred_targets() -> void:
	for r in D:
		if r["target_kind"] == 0:
			r["target_i"] = sidx(G, G.size(), r["target"])
	var tables := {7: OA, 8: OB, 9: OC, 10: G}
	for r in R:
		var t = tables.get(r["type"])
		r["target_i"] = sidx(t, t.size(), r["target"]) if t != null else -1


func _do_objectives() -> void:
	var arr := []
	for r0 in m["objective"]:
		var r: Dictionary = r0.duplicate()
		if not cond_ok(r["cond"]):
			continue
		r["point_i"] = sidx(P, P.size(), r["point"])
		r["path_i"] = sidx(T, T.size(), r["path"])
		if r["target_kind"] == 0:
			r["target_i"] = sidx(G, G.size(), r["target"])
		else:
			r["target_i"] = _target_i(r["target_kind"], r["target"])
		arr.append(r)
	J = arr


func script() -> Dictionary:
	var out := script_geometry()
	out.merge({"header": header, "regions": keep(R), "timers": keep(TM), "hercs": keep(OA), "flyers": keep(OB),
		"structs": keep(OC), "orders": keep(D), "groups": keep(G), "objectives": J})
	return out

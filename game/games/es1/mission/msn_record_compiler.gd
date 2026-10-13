class_name MsnRecordCompiler
extends RefCounted
## What the Earthsiege 1 shell (GO.EXE 0x3276c) and the Earthsiege 2 shell (VSHELL 0x417b67) share
## when they "compile" an MSN for one play: the condition records (variable tests, random rolls,
## random cases, pick keys) decide which records are kept; picked records copy an earlier
## record's values; records with an id already seen overwrite (merge into) that record.
## Ports of tools/mission.py / tools/mission_es2.py; subclasses add their record tables.

## Condition record kinds.
const COND_VAR_TEST := 0
const COND_RANDOM := 1
const COND_CASE := 2
const COND_PICK := 3
## Range bounds of a case record are 16-bit.
const CASE_MASK := 0xffff
## A case whose parent is a pick record matches any roll.
const ANY_ROLL := -99

var m: Dictionary
var rng: MissionRng
var campaign = null
var mode := 0
var vars := []
var logs := []
var K := []                # kept condition records
var msn_header := []
var header := []
var P := []                # points
var H := []                # headings
var T := []                # paths
var A := []                # areas


func var_at(i: int) -> int:
	return vars[i] if i >= 0 and i < vars.size() else 0


## Variable test of a condition record (opcode b, compare var a with c).
func _compare(_op: int, _v: int, _x: int) -> bool:
	return false


## Evaluates the condition records in order; K = the records that hold.
func run_conditions() -> void:
	var kept := []
	for c0 in m["cond"]:
		var c: Dictionary = c0.duplicate()
		match int(c["kind"]):
			COND_VAR_TEST:
				if _cond_ok_in(c["parent"], kept) and _compare(c["b"], var_at(c["a"]), c["c"]):
					kept.append(c)
			COND_RANDOM:
				if _cond_ok_in(c["parent"], kept):
					c["b"] = rng.call_n(c["a"])
					kept.append(c)
			COND_CASE:
				if _case_matches(c, kept):
					kept.append(c)
			COND_PICK:
				if _cond_ok_in(c["parent"], kept):
					kept.append(c)
	K = kept


## A case holds if its parent roll lies in [a, b] (or its parent is a pick record).
static func _case_matches(c: Dictionary, kept: Array) -> bool:
	var v := -1
	for p in kept:
		if p["id"] == c["parent"]:
			if p["kind"] == COND_RANDOM:
				v = p["b"]
				break
			if p["kind"] == COND_PICK:
				v = ANY_ROLL
				break
	return v == ANY_ROLL or ((c["a"] & CASE_MASK) <= v and v <= (c["b"] & CASE_MASK))


func _cond_ok_in(cid: int, kept: Array) -> bool:
	if cid == -1:
		return true
	for c in kept:
		if c["id"] == cid:
			return true
	return false


func cond_ok(cid: int) -> bool:
	return _cond_ok_in(cid, K)


## Rolls pick key `key`: the id of the case record that matches, or null.
func pick_case(key: int) -> Variant:
	for c in K:
		if c["kind"] == COND_PICK and c["a"] == key:
			var roll := rng.call_n(c["c"])
			for k in K:
				if k["kind"] == COND_CASE and k["parent"] == c["id"] and (k["a"] & CASE_MASK) <= roll \
						and roll <= (k["b"] & CASE_MASK):
					return k["id"]
			logs.append("pick %d: no case for roll %d" % [key, roll])
			return null
	logs.append("pick key %d not found" % key)
	return null


## Index of the record (among the first n of arr) picked by `key`, or -1.
func pick_rec(arr: Array, n: int, key: int) -> int:
	var case_id = pick_case(key)
	if case_id == null:
		return -1
	for i in n:
		if arr[i]["cond"] == case_id:
			return i
	logs.append("pick key %d case %d: no record" % [key, case_id])
	return -1


## script index of id (records with id -1 skipped): GO 0x313f1 & friends.
static func sidx(arr: Array, n: int, rid: int) -> int:
	if rid == -1:
		return -1
	var k := 0
	for i in n:
		var id: int = arr[i]["id"]
		if id == -1:
			continue
		if id == rid:
			return k
		k += 1
	return -1


## Array index of id, or -1.
static func aidx(arr: Array, n: int, rid: int) -> int:
	if rid == -1:
		return -1
	for i in n:
		if arr[i]["id"] == rid:
			return i
	return -1


static func _store(arr: Array, rec: Dictionary, dup: int) -> void:
	if dup != -1 and dup < arr.size():
		arr[dup] = rec
	else:
		arr.append(rec)


## [b if b != skip else a for a, b in zip(old, new)]
static func _zip_keep(old: Array, new: Array, skip: int) -> Array:
	var out := []
	for i in mini(old.size(), new.size()):
		out.append(new[i] if new[i] != skip else old[i])
	return out


## Pairwise (var, op) action lists: a new pair replaces the old one unless its var is -1.
static func _zip_pairs(old: Array, new: Array) -> Array:
	var out := []
	for i in mini(old.size(), new.size()):
		out.append(new[i] if new[i][0] != -1 else old[i])
	return out


## Mission variables that are not 0 (index -> value).
func nonzero_vars() -> Dictionary:
	var nonzero := {}
	for i in vars.size():
		if vars[i] != 0:
			nonzero[i] = vars[i]
	return nonzero


## Only records with id != -1 make it into script.dat.
static func keep(arr: Array) -> Array:
	var out := []
	for x in arr:
		if x["id"] != -1:
			out.append(x)
	return out


# ------------------------------------------------------------------ shared record tables

func _do_points() -> void:
	var arr := []
	for p0 in m["point"]:
		var p: Dictionary = p0.duplicate()
		if not cond_ok(p["cond"]):
			continue
		var n := arr.size()
		if p["pick"] != -1:
			var j := pick_rec(arr, n, p["pick"])
			if j != -1:
				for f in ["x", "y", "z"]:
					p[f] = arr[j][f]
		if p["rel"]:
			_resolve_relative_point(p, arr, n)
		_store(arr, p, sidx(arr, n, p["id"]))
	P = arr


## A relative point is the sum of two earlier points (ids in x and y).
func _resolve_relative_point(p: Dictionary, arr: Array, n: int) -> void:
	var a := sidx(arr, n, p["x"])
	var b := sidx(arr, n, p["y"])
	if a < 0 or b < 0:
		logs.append("point %d: bad rel refs" % p["id"])
		return
	p["x"] = arr[a]["x"] + arr[b]["x"]
	p["y"] = arr[a]["y"] + arr[b]["y"]
	p["z"] = arr[a]["z"] + arr[b]["z"]


func _do_headings() -> void:
	var arr := []
	for h0 in m["heading"]:
		var h: Dictionary = h0.duplicate()
		if not cond_ok(h["cond"]):
			continue
		var n := arr.size()
		if h["pick"] != -1:
			var j := pick_rec(arr, n, h["pick"])
			if j != -1:
				h["value"] = arr[j]["value"]
		_store(arr, h, sidx(arr, n, h["id"]))
	H = arr


func _do_paths() -> void:
	var arr := []
	var np := P.size()
	for t0 in m["path"]:
		var t: Dictionary = t0.duplicate()
		var idx := []
		for i in t["points"]:
			idx.append(sidx(P, np, i))
		t["idx"] = idx
		if not cond_ok(t["cond"]):
			continue
		var n := arr.size()
		if t["pick"] != -1:
			var j := pick_rec(arr, n, t["pick"])
			if j != -1:
				t["idx"] = arr[j]["idx"].duplicate()
		_store(arr, t, sidx(arr, n, t["id"]))
	T = arr


func _do_areas() -> void:
	var arr := []
	var np := P.size()
	for a0 in m["area"]:
		var a: Dictionary = a0.duplicate()
		if not cond_ok(a["cond"]):
			continue
		var n := arr.size()
		a["p1i"] = sidx(P, np, a["p1"])
		a["p2i"] = sidx(P, np, a["p2"]) if a["kind"] == 0 else a["p2"]
		_store(arr, a, sidx(arr, n, a["id"]))
	A = arr


## Herc / flyer / structure records: a picked record copies `copy_fields` and the resolved references
## of the picked one; a repeated id merges into the first record (fields equal to `skip` keep the old value).
func _objs(src: Array, copy_fields: Array, skip: Dictionary) -> Array:
	var refs := [["point", P], ["heading", H], ["alert_region", _regions()], ["death_region", _regions()]]
	var arr := []
	for o0 in src:
		var o: Dictionary = o0.duplicate()
		if not cond_ok(o["cond"]):
			continue
		var n := arr.size()
		if _is_unpicked(o["pick"]):
			for rf in refs:
				var tbl: Array = rf[1]
				o[rf[0] + "_i"] = sidx(tbl, tbl.size(), o[rf[0]])
		else:
			_copy_picked(o, arr, n, copy_fields, refs)
		var dup := aidx(arr, n, o["id"])
		if dup != -1:
			_merge(arr[dup], o, skip)
		else:
			arr.append(o)
	return arr


func _copy_picked(o: Dictionary, arr: Array, n: int, copy_fields: Array, refs: Array) -> void:
	var j := pick_rec(arr, n, o["pick"])
	for rf in refs:
		o[rf[0] + "_i"] = arr[j][rf[0] + "_i"] if j != -1 else -1
	if j != -1:
		for f in copy_fields:
			o[f] = arr[j][f]


## Region table used by the alert/death region references.
func _regions() -> Array:
	return []


func _is_unpicked(pick: int) -> bool:
	return pick == -1


static func _merge(dst: Dictionary, src: Dictionary, skip: Dictionary) -> void:
	for f in skip:
		var sk: int = skip[f]
		var v = src[f]
		if f == "actions":
			dst[f] = _zip_pairs(dst[f], v)
			dst["n_actions"] = maxi(dst["n_actions"], src["n_actions"])
		elif v is Array:
			dst[f] = _zip_keep(dst[f], v, sk)
		elif v != sk:
			dst[f] = v
			if src.has(f + "_i"):
				dst[f + "_i"] = src[f + "_i"]


## Copies the fields of `src` that are set (!= -1) into `dst`, with their resolved "_i" index.
static func _overwrite_set_fields(dst: Dictionary, src: Dictionary, fields: Array) -> void:
	for f in fields:
		if src[f] != -1:
			dst[f] = src[f]
			if src.has(f + "_i"):
				dst[f + "_i"] = src[f + "_i"]


## points / headings / paths / areas in script.dat form.
func script_geometry() -> Dictionary:
	var pts := []
	for p in keep(P):
		pts.append([p["x"], p["y"], p["z"]])
	var hs := []
	for h in keep(H):
		hs.append(h["value"])
	var ps := []
	for t in keep(T):
		ps.append(t["idx"])
	var ars := []
	for a in keep(A):
		ars.append([a["kind"], a["p1i"], a["p2i"]])
	return {"points": pts, "headings": hs, "paths": ps, "areas": ars}

extends RefCounted
## Earthsiege 1 mission_json() resolution (tools/mission.py): turns a compiled script.dat
## (MissionCompiler.Compiler.script()) into the runtime mission dictionary with positions, names
## and cross references. Output must stay identical to the Python tools (tools/tests/test_mission_port.py).

const TEAM_NAMES := {0: "human", 1: "cybrid"}
const MODE_NAMES := {1: "campaign", 0: "single"}
## Region circle radii are stored in tens of units.
const CIRCLE_RADIUS_SCALE := 10
const PLAYER_SQUAD_NOTE := "player squad: members come from player.mec, MSN members ignored"

var tb: Dictionary
var comp                   # the compiler (MissionCompiler.Compiler) after run()
var compiled: Dictionary   # comp.script()
var points: Array
var headings: Array
var death_ops: Dictionary


func _init(tables: Dictionary, p_comp) -> void:
	tb = tables
	comp = p_comp
	compiled = comp.script()
	points = compiled["points"]
	headings = compiled["headings"]
	death_ops = tb["death_ops"]


static func _name(tbl: Array, i: int) -> Variant:
	return tbl[i] if i >= 0 and i < tbl.size() else null


static func _tget(tbl: Dictionary, key: int, dflt: Variant) -> Variant:
	return tbl.get(str(key), dflt)


func pt(i: int) -> Variant:
	return points[i].duplicate() if i >= 0 and i < points.size() else null


func head(i: int) -> Variant:
	return headings[i] if i >= 0 and i < headings.size() else null


func _var_action(v: int, op: int) -> Variant:
	return {"var": v, "op": _tget(death_ops, op, op)} if v != -1 else null


func _common(o: Dictionary) -> Dictionary:
	return {"id": o["id"], "point": o["point_i"], "position": pt(o["point_i"]),
		"heading": head(o["heading_i"]), "on_death": _var_action(o["var"], o["op"]),
		"alert_region": o["alert_region_i"], "death_region": o["death_region_i"], "health": o["health"],
		"flag0": o["block"][0] if o.has("block") else null}


func _hercs(s: Dictionary) -> Array:
	var out := []
	for o in s["hercs"]:
		var d := _common(o)
		var rest: Array = o["block"].slice(1)
		var any := false
		for x in rest:
			if x != 0:
				any = true
		d["type"] = o["type"]
		d["type_name"] = _name(tb["herc_types"], o["type"])
		d["weapons"] = o["weapons"]
		d["ammo"] = o["ammo"]
		d["block_rest"] = rest if any else null
		d["f62"] = o["f62"]
		out.append(d)
	return out


func _flyers(s: Dictionary) -> Array:
	var out := []
	for o in s["flyers"]:
		var d := _common(o)
		d["type"] = o["type"]
		d["type_name"] = _name(tb["flyer_types"], o["type"])
		out.append(d)
	return out


func _structures(s: Dictionary) -> Array:
	var out := []
	for o in s["structs"]:
		var d := _common(o)
		d["type"] = o["type"]
		out.append(d)
	return out


func _path_points(s: Dictionary, path_i: int) -> Variant:
	var gpath = s["paths"][path_i] if path_i >= 0 and path_i < s["paths"].size() else null
	if gpath == null or gpath.size() == 0:
		return null
	var out := []
	for i in gpath:
		out.append(pt(i))
	return out


func _groups(s: Dictionary) -> Array:
	var out := []
	for g in s["groups"]:
		out.append(_group(s, g, out.size()))
	return out


func _group(s: Dictionary, g: Dictionary, gi: int) -> Dictionary:
	var orders_tbl: Dictionary = tb["flyer_orders"] if g["kind"] == 1 else tb["herc_orders"]
	var members := []
	for x in g["members_i"]:
		if x != -1:
			members.append(x)
	return {
		"index": gi, "id": g["id"], "kind": _tget(tb["group_kinds"], g["kind"], g["kind"]),
		"team": g["team"], "team_name": TEAM_NAMES.get(g["team"]),
		"formation": g["formation"], "orders": g["orders"], "orders_name": _tget(orders_tbl, g["orders"], null),
		"point": g["point_i"], "position": pt(g["point_i"]), "heading": head(g["heading_i"]),
		"path": g["path_i"], "path_points": _path_points(s, g["path_i"]), "members": members,
		"target": {"kind": _tget(tb["target_kinds"], g["target_kind"], g["target_kind"]),
			"index": g["target_i"]} if g["target"] != -1 else null,
		"spawn_region": g["spawn_region_i"] if g["spawn_region_i"] != -1 else null,
		"on_destroyed": _var_action(g["var"], g["op"]),
		"u4": g["u4"], "u52": g["u52"], "flag0": g["block"][0],
		"note": PLAYER_SQUAD_NOTE if gi == 0 else null}


## [kind, index] of every herc / flyer / structure whose `attr` (alert/death region) is ri.
static func _region_refs(units: Dictionary, attr: String, ri: int) -> Array:
	var out := []
	for kind in ["herc", "flyer", "structure"]:
		var lst: Array = units[kind]
		for i in lst.size():
			if lst[i][attr] == ri:
				out.append([kind, i])
	return out


func _areas(s: Dictionary, area_indices: Array) -> Array:
	var out := []
	for a in area_indices:
		if a == -1:
			continue
		var ar: Array = s["areas"][a]
		if ar[0] == 0:
			out.append({"shape": "rect", "corner1": pt(ar[1]), "corner2": pt(ar[2])})
		else:
			out.append({"shape": "circle", "center": pt(ar[1]), "radius": ar[2] * CIRCLE_RADIUS_SCALE})
	return out


func _regions(s: Dictionary, groups: Array, units: Dictionary) -> Array:
	var out := []
	for r in s["regions"]:
		var ri := out.size()
		var act := []
		for g in groups:
			if g["spawn_region"] != null and g["spawn_region"] == ri:
				act.append(g["index"])
		out.append({"index": ri, "type": r[0], "type_name": _tget(tb["region_types"], r[0], null),
			"param": r[1], "areas": _areas(s, r[2]),
			"on_fire": {"var": r[3], "op": _tget(tb["region_ops"], r[4], r[4])} if r[3] != -1 else null,
			"activates_groups": act, "fired_by_alert_of": _region_refs(units, "alert_region", ri),
			"fired_by_death_of": _region_refs(units, "death_region", ri)})
	return out


func _header(hdr: Array) -> Dictionary:
	var world: int = hdr[0] * 6 + hdr[9] * 2 + hdr[8]
	return {"raw": hdr, "msn_raw": comp.msn_header,
		"terrain": hdr[0], "terrain_name": _name(tb["terrain_names"], hdr[0]),
		"zone": hdr[1], "mode": MODE_NAMES.get(hdr[2], hdr[2]),
		"mission_type": hdr[3], "win_test": _tget(tb["mission_types"], hdr[3], null), "h4": hdr[4],
		"ammo": hdr[5], "damage": hdr[6], "difficulty": hdr[7], "visibility": hdr[8], "time_of_day": hdr[9],
		"world_file": "WORLD%d.WLD" % world, "palette_world": "world%d" % (hdr[0] * 6 + hdr[9] * 2)}


## Player start: group 0's position (or first path point) and its path as nav waypoints.
static func player_start(groups: Array) -> Variant:
	if groups.is_empty():
		return null
	var g0: Dictionary = groups[0]
	var pos = g0["position"]
	if pos == null:
		pos = g0["path_points"][0] if g0["path_points"] != null else null
	return {"group": 0, "position": pos, "waypoints": g0["path_points"]}


## ev: {seed, campaign, texts} of this evaluation.
func build_mission(base: String, raw: Dictionary, ev: Dictionary) -> Dictionary:
	var s := compiled
	var hdr: Array = s["header"]
	var units := {"herc": _hercs(s), "flyer": _flyers(s), "structure": _structures(s)}
	var groups := _groups(s)
	var pts := []
	for p in points:
		pts.append(p.duplicate())
	var out := {
		"name": base,
		"legacy_format": raw.get("legacy", false),
		"header": _header(hdr),
		"evaluation": {"seed": ev.seed if ev.seed >= 0 else null, "campaign": ev.campaign,
			"mission_vars_nonzero": comp.nonzero_vars(), "log": comp.logs},
		"player_start": player_start(groups),
		"points": pts, "headings": headings, "paths": s["paths"],
		"regions": _regions(s, groups, units), "groups": groups, "hercs": units.herc, "flyers": units.flyer,
		"structures": units.structure, "texts": ev.texts,
	}
	if hdr[1] >= 0:
		var zones = MissionCompiler._load("zones.json")
		out["zone"] = zones.get(str(hdr[1])) if zones != null else null
	return out

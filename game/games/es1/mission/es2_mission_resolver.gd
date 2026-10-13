extends RefCounted
## Earthsiege 2 mission resolution (tools/mission_es2.py resolve()): turns a compiled ES2 script
## (MissionCompilerES2.Compiler2.script()) into the runtime mission dictionary. Output must stay
## identical to the Python tools (tools/tests/test_mission_port_es2.py).

const HERC_TYPES := ["OUTLAW", "RAPTOR2", "TOMAHAWK", "SAMSON", "COLOSSUS", "APOCA", "OGRE", "MAVERICK", "RAZOR",
	"MONGOOSE", "STINGRAY", "MIRIMAC", "RAMSES", "ACHILLES", "HYPERION", "PITBULL", "SPIDER", "DIABLO",
	"HEADHUNT", "SCARAB", "CERBERUS"]
const FLYER_TYPES := ["SKIMMER", "HOVTANK", "DROPSHIP"]
const GROUP_KINDS := {0: "herc", 1: "flyer", 2: "structure"}
const TARGET_KINDS := {0: "group", 1: "herc", 2: "flyer", 3: "structure"}
const REGION_TARGET_TYPES := {7: "herc", 8: "flyer", 9: "structure", 10: "group"}
const TEAM_NAMES := {0: "human", 1: "cybrid"}
## At most 10 (var, op) actions per record.
const MAX_ACTIONS := 10
const CIRCLE_RADIUS_SCALE := 10
const BASE_HEADER_WORDS := 10

var comp                   # the compiler (MissionCompilerES2.Compiler2) after run()
var compiled: Dictionary   # comp.script()
var points: Array
var headings: Array
var paths: Array


func _init(p_comp) -> void:
	comp = p_comp
	compiled = comp.script()
	points = compiled["points"]
	headings = compiled["headings"]
	paths = compiled["paths"]


## The first n (var, op) pairs that are set.
static func actions(n: int, pairs: Array) -> Array:
	var out := []
	for i in mini(maxi(0, n), MAX_ACTIONS):
		if i < pairs.size() and pairs[i][0] != -1:
			out.append([pairs[i][0], pairs[i][1]])
	return out


static func _name(tbl: Array, i: int) -> Variant:
	return tbl[i] if i >= 0 and i < tbl.size() else null


func pt(i: int) -> Variant:
	return points[i].duplicate() if i >= 0 and i < points.size() else null


func head(i: int) -> Variant:
	return headings[i] if i >= 0 and i < headings.size() else null


func path_pts(i: int) -> Variant:
	if i < 0 or i >= paths.size() or paths[i].is_empty():
		return null
	var out := []
	for k in paths[i]:
		out.append(pt(k))
	return out


static func _target(kind: int, target: int, index) -> Variant:
	return {"kind": TARGET_KINDS.get(kind, kind), "index": index} if target != -1 else null


func _common(o: Dictionary) -> Dictionary:
	return {"id": o["id"], "point": o["point_i"], "position": pt(o["point_i"]),
		"heading": head(o["heading_i"]), "on_death": actions(o["n_actions"], o["actions"]),
		"alert_region": o["alert_region_i"], "death_region": o["death_region_i"], "health": o["health"],
		"flag0": o["block"][0] if o.has("block") else null}


func _hercs() -> Array:
	var out := []
	for o in compiled["hercs"]:
		var d := _common(o)
		d["type"] = o["type"]
		d["type_name"] = _name(HERC_TYPES, o["type"])
		d["weapons"] = o["weapons"]
		d["ammo"] = o["ammo"]
		d["skill"] = o["block"][1]
		d["f88"] = o["f88"]
		out.append(d)
	return out


func _flyers() -> Array:
	var out := []
	for o in compiled["flyers"]:
		var d := _common(o)
		d["type"] = o["type"]
		d["type_name"] = _name(FLYER_TYPES, o["type"])
		out.append(d)
	return out


func _structures() -> Array:
	var out := []
	for o in compiled["structs"]:
		var d := _common(o)
		d["type"] = o["type"]
		out.append(d)
	return out


func _orders() -> Array:
	var out := []
	for r in compiled["orders"]:
		out.append({"id": r["id"], "type": r["type"], "arg": r["arg"], "point": r["point_i"],
			"position": pt(r["point_i"]), "path": r["path_i"], "path_points": path_pts(r["path_i"]),
			"target": _target(r["target_kind"], r["target"], r["target_i"]),
			"region": r["region_i"] if r["region_i"] != -1 else null})
	return out


func _groups(orders: Array) -> Array:
	var out := []
	for g in compiled["groups"]:
		out.append(_group(g, out.size(), orders))
	return out


## A group's first order gives its order type, target and (without its own) path.
func _group(g: Dictionary, gi: int, orders: Array) -> Dictionary:
	var olist := []
	for i in g["orders_i"]:
		if i != -1:
			olist.append(i)
	var first = orders[olist[0]] if not olist.is_empty() else null
	var gpath: int = g["path_i"] if g["path_i"] != -1 else (first["path"] if first != null else -1)
	var members := []
	for x in g["members_i"]:
		if x != -1:
			members.append(x)
	return {"index": gi, "id": g["id"], "kind": GROUP_KINDS.get(g["kind"], g["kind"]),
		"team": g["team"], "team_name": TEAM_NAMES.get(g["team"]), "formation": g["formation"],
		"orders": first["type"] if first != null else -1, "order_list": olist,
		"point": g["point_i"], "position": pt(g["point_i"]), "heading": head(g["heading_i"]),
		"path": gpath, "path_points": path_pts(gpath), "members": members,
		"target": first["target"] if first != null else null,
		"spawn_region": g["spawn_region_i"] if g["spawn_region_i"] != -1 else null,
		"on_destroyed": actions(g["n_actions"], g["actions"]), "u4": g["u4"], "flag0": g["block"][0],
		"w81": g["w81"]}


static func _region_refs(units: Dictionary, attr: String, ri: int) -> Array:
	var out := []
	for kind in ["herc", "flyer", "structure"]:
		var lst: Array = units[kind]
		for i in lst.size():
			if lst[i][attr] == ri:
				out.append([kind, i])
	return out


func _areas(area_indices: Array) -> Array:
	var all_areas: Array = compiled["areas"]
	var out := []
	for a in area_indices:
		if a == -1 or a >= all_areas.size():
			continue
		var ar: Array = all_areas[a]
		if ar[0] == 0:
			out.append({"shape": "rect", "corner1": pt(ar[1]), "corner2": pt(ar[2])})
		else:
			out.append({"shape": "circle", "center": pt(ar[1]), "radius": ar[2] * CIRCLE_RADIUS_SCALE})
	return out


static func _indices_where(records: Array, key: String, value: int, index_key := "") -> Array:
	var out := []
	for i in records.size():
		if records[i][key] != null and records[i][key] == value:
			out.append(records[i][index_key] if index_key != "" else i)
	return out


func _regions(groups: Array, orders: Array, units: Dictionary) -> Array:
	var out := []
	for r in compiled["regions"]:
		var ri := out.size()
		out.append({"index": ri, "id": r["id"], "type": r["type"], "param": r["param"], "areas": _areas(r["ai"]),
			"on_fire": actions(r["n_actions"], r["actions"]), "texts": comp.texts(r["texts"]), "message": r["message"],
			"target": {"kind": REGION_TARGET_TYPES.get(r["type"]), "index": r["target_i"]} if r["target_i"] != -1 else null,
			"activates_groups": _indices_where(groups, "spawn_region", ri, "index"),
			"activates_orders": _indices_where(orders, "region", ri),
			"fired_by_alert_of": _region_refs(units, "alert_region", ri),
			"fired_by_death_of": _region_refs(units, "death_region", ri)})
	return out


func _timers() -> Array:
	var out := []
	for t in compiled["timers"]:
		var fire := []
		for i in t["fire_i"]:
			if i != -1:
				fire.append(i)
		out.append({"id": t["id"], "trigger": t["trigger_i"] if t["trigger"] != -1 else null, "delay": t["delay"],
			"fire": fire})
	return out


func _objectives() -> Array:
	var out := []
	for r in compiled["objectives"]:
		out.append({"required": r["required"] != 0, "type": r["type"],
			"target": _target(r["target_kind"], r["target"], r["target_i"]),
			"point": r["point_i"], "position": pt(r["point_i"]), "path": r["path_i"],
			"path_points": path_pts(r["path_i"]), "text": comp.text(r["text"]),
			"actions": actions(r["n_actions"], r["actions"])})
	return out


func _texts() -> Dictionary:
	var b = comp.brief
	var d = comp.deb
	return {
		"briefing": " ".join(comp.texts(b["briefing"])) if b != null else "",
		"intel": " ".join(comp.texts(b["intel"])) if b != null else "",
		"objectives": comp.texts(b["objectives"]) if b != null else [],
		"debriefings": ["".join(comp.texts(d["texts"]))] if d != null else [],
		"briefing_clip": comp.value_by_id.get(b["value"], -1) if b != null else -1,
		"debrief_clip": comp.value_by_id.get(d["value"], -1) if d != null else -1}


func _values() -> Dictionary:
	var values := {}
	for v in comp.VAL:
		values[str(v["id"])] = v["value"]
	return values


func _header() -> Dictionary:
	var hdr: Array = compiled["header"]
	return {"raw": hdr.slice(0, BASE_HEADER_WORDS), "extra": hdr.slice(BASE_HEADER_WORDS), "msn_raw": comp.msn_header,
		"terrain": hdr[0], "zone": hdr[1], "mode": "campaign" if comp.mode == 1 else "single",
		"mission_type": hdr[3], "h4": hdr[4], "world": null}


## Player start: group 0's position (or first path point), path and, for a herc squad, the player's herc.
static func _player_start(groups: Array, hercs: Array) -> Variant:
	if groups.is_empty():
		return null
	var g0: Dictionary = groups[0]
	var pos = g0["position"]
	if pos == null:
		pos = g0["path_points"][0] if g0["path_points"] != null else null
	var ph = null
	if not g0["members"].is_empty() and g0["kind"] == "herc":
		ph = hercs[g0["members"][0]]
	return {"group": 0, "position": pos, "waypoints": g0["path_points"], "herc": ph}


func build_mission(base: String, seed: int, camp: Variant) -> Dictionary:
	var units := {"herc": _hercs(), "flyer": _flyers(), "structure": _structures()}
	var orders := _orders()
	var groups := _groups(orders)
	var pts := []
	for p in points:
		pts.append(p.duplicate())
	return {
		"name": base, "pack": "es2", "format": "es2",
		"header": _header(),
		"evaluation": {"seed": seed if seed >= 0 else null, "campaign": camp,
			"mission_vars_nonzero": comp.nonzero_vars(),
			"log": comp.logs},
		"player_start": _player_start(groups, units.herc),
		"points": pts, "headings": headings, "paths": paths,
		"regions": _regions(groups, orders, units), "timers": _timers(), "groups": groups, "orders": orders,
		"hercs": units.herc, "flyers": units.flyer, "structures": units.structure, "objectives": _objectives(),
		"values": _values(), "texts": _texts(),
	}

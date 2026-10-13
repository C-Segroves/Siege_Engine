class_name SSObjectTree
extends RefCounted
## The mission's object tree as Starsiege scripts see it (the .mis "MissionGroup" hierarchy):
## object ids, script paths ("MissionGroup/patrolGroup/patrol1"), bare names, groups with their
## children, and the player-number -> vehicle object map of the Darkstar player manager.
##
## Record: {id, name, path, kind, parent, children[], def (mission json object), node, team, script, alive}.

## First object id handed out (Darkstar object ids are plain integers; the scripts only compare them).
const FIRST_ID := 1000
const VEHICLE_KINDS := ["herc", "tank", "flyer"]
## Kinds that count for isGroupDestroyed (markers, triggers and interiors do not).
const DESTRUCTIBLE_KINDS := ["herc", "tank", "flyer", "static", "turret"]
const ROUTE_POINT_KINDS := ["marker", "nav_marker", "drop_point"]

var objects := {}          # id -> record
var by_path := {}          # lower path -> id (first in tree order)
var by_name := {}          # lower name -> id (first in tree order)
var player_objs := {}      # player num object id -> vehicle object id
var root_id := 0
var _next_id := FIRST_ID


## Builds the tree from the mission's drop points and objects (groups are implied by the paths).
func build(mission: Dictionary) -> void:
	root_id = add_object("MissionGroup", "MissionGroup", "group", 0)
	var all: Array = []
	all.append_array(MissionRuntime._arr(mission.get("drop_points")))
	all.append_array(MissionRuntime._arr(mission.get("objects")))
	for o in all:
		var path := String(o.get("path", ""))
		var cut := path.rfind("/")
		var parent := group_for(path.left(cut)) if cut > 0 else root_id
		add_object(String(o.get("name", "")), path, String(o.get("kind", "")), parent, o)


## Adds a record; objects can share a path (unnamed siblings): the first keeps the path and name keys.
func add_object(name: String, path: String, kind: String, parent: int, def := {}) -> int:
	var id := _next_id
	_next_id += 1
	objects[id] = {"id": id, "name": name, "path": path, "kind": kind, "parent": parent, "children": [],
		"def": def, "node": null, "team": String(def.get("team", "neutral")), "script": String(def.get("script", "")),
		"alive": true}
	if parent > 0:
		objects[parent].children.append(id)
	var key := path.to_lower()
	if not by_path.has(key):
		by_path[key] = id
	if name != "" and not by_name.has(name.to_lower()):
		by_name[name.to_lower()] = id
	return id


## Adds an engine-made object (player squad, group) that owns its path even if the mission used it.
func add_engine_object(name: String, path: String, kind: String, parent: int, def := {}) -> int:
	var id := add_object(name, path, kind, parent, def)
	by_path[path.to_lower()] = id
	return id


## The group object for a path, created (with its parents) on first use.
func group_for(path: String) -> int:
	var key := path.to_lower()
	if by_path.has(key):
		return by_path[key]
	var cut := path.rfind("/")
	var parent := 0 if cut < 0 else group_for(path.left(cut))
	return add_engine_object(path.substr(cut + 1), path, "group", parent)


## Script value -> object id (ids, "MissionGroup/a/b" paths, bare names, player numbers); 0 = none.
func resolve(v) -> int:
	if v is int or v is float:
		return int(v) if _is_known_id(int(v)) else 0
	var s := String(v).strip_edges()
	if s == "":
		return 0
	if s.is_valid_int():
		return int(s) if _is_known_id(int(s)) else 0
	var key := s.replace("\\", "/").to_lower()
	if by_path.has(key):
		return by_path[key]
	if not key.begins_with("missiongroup/") and by_path.has("missiongroup/" + key):
		return by_path["missiongroup/" + key]
	return by_name.get(key, 0)


func _is_known_id(id: int) -> bool:
	return objects.has(id) or player_objs.has(id)


func get_record(id: int) -> Dictionary:
	return objects.get(id, {})


func kind_of(id: int) -> String:
	return String(objects.get(id, {}).get("kind", ""))


func is_vehicle(id: int) -> bool:
	return kind_of(id) in VEHICLE_KINDS


## Callback namespace of an object: vehicle::, turret:: or structure::.
func callback_kind(id: int) -> String:
	if is_vehicle(id):
		return "vehicle"
	return "turret" if kind_of(id) == "turret" else "structure"


## Live scene node of an object (player numbers map to their vehicle); null if none.
func node_of(id: int) -> Node3D:
	if player_objs.has(id):
		id = player_objs[id]
	var n = objects.get(id, {}).get("node")
	if n != null and is_instance_valid(n):
		return n
	return null


## Position of an object (groups: first living member / first child with a position).
func position_of(id: int) -> Vector3:
	var n := node_of(id)
	if n:
		return n.global_position if n.is_inside_tree() else n.position
	var o: Dictionary = objects.get(id, {})
	for c in o.get("children", []):
		if objects[c].get("alive", true) and (node_of(c) != null or objects[c].kind == "group"):
			return position_of(c)
	if o.has("def") and o.def.has("pos"):
		return position_of_def(o.def)
	return Vector3.ZERO


static func position_of_def(o: Dictionary) -> Vector3:
	var p: Array = o.get("pos", [0, 0, 0])
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


## Vehicle object ids in an object (itself, or every vehicle below a group).
func vehicles_in(id: int) -> Array:
	if player_objs.has(id):
		id = player_objs[id]
	var o: Dictionary = objects.get(id, {})
	if o.is_empty():
		return []
	if o.kind in VEHICLE_KINDS:
		return [id]
	var out := []
	for c in o.get("children", []):
		out.append_array(vehicles_in(c))
	return out


func alive_units_in(id: int) -> Array:
	var out := []
	for v in vehicles_in(id):
		var n := node_of(v)
		if n != null and n.get("alive"):
			out.append(v)
	return out


## isGroupDestroyed: every destructible member (objects with a missing shape never existed) is dead.
func is_group_destroyed(id: int) -> bool:
	var o: Dictionary = objects.get(id, {})
	if o.is_empty():
		return true
	if o.kind != "group":
		return not o.get("alive", true)
	for c in o.children:
		var k: String = objects[c].kind
		if k in DESTRUCTIBLE_KINDS:
			if objects[c].get("alive", true) and not objects[c].get("missing_shape", false):
				return false
		elif k == "group" and not is_group_destroyed(c):
			return false
	return true


## Route points of a group (markers in tree order).
func route_points(group_id: int) -> Array[Vector3]:
	var pts: Array[Vector3] = []
	for c in objects.get(group_id, {}).get("children", []):
		if objects[c].kind in ROUTE_POINT_KINDS:
			pts.append(position_of(c))
	return pts


func ids_of_kind(kind: String) -> Array:
	var out := []
	for id in objects:
		if objects[id].kind == kind:
			out.append(id)
	return out


## Object id of a scene node (vehicles carry "ss_id" metadata, structures their ss_id); 0 if none.
static func id_of_node(n: Node) -> int:
	if n == null or not is_instance_valid(n):
		return 0
	if n.has_meta("ss_id"):
		return int(n.get_meta("ss_id"))
	if n is SSStructure:
		return (n as SSStructure).ss_id
	return 0

class_name TribesSimObjects
extends RefCounted
## The script-visible objects of a Tribes / Tribes 2 mission (the engine's SimObjects): the mission tree the
## .mis builds (SimGroups, markers, shapes, items, triggers), the objects scripts create (`new`, newObject),
## the clients and their players. Ids are numbers as in the originals; names and group paths
## ("MissionGroup/Teams/team1/DropPoints", Tribes also "MissionGroup\\teams\\team1") resolve to ids.
##
## A record: {id, class, name, fields {lower field: value}, parent (id, 0 = none), children [ids], datablock
## (lower name, "" = none), node (the Node3D standing for it in the battle, or null), deleted}.
## Positions in `fields.position` are in the original frame (x east, y north, z up); the node's position is in
## the engine frame (to_engine / to_original).

## Client ids start here (Tribes scripts address the first client as 2049: remoteEval(2049, ...)).
const FIRST_CLIENT_ID := 2049
const FIRST_OBJECT_ID := 4096
const PATH_SEPARATORS := ["/", "\\"]

var objects := {}            # id -> record
var _by_name := {}           # lower name -> [ids], most recent last
var _next_object := FIRST_OBJECT_ID
var _next_client := FIRST_CLIENT_ID
var root_id := 0


static func to_engine(p: Vector3) -> Vector3:
	return Vector3(p.x, p.z, -p.y)


static func to_original(p: Vector3) -> Vector3:
	return Vector3(p.x, -p.z, p.y)


## Creates an object (`client`: from the client id range); returns its id.
func create(cls: String, obj_name: String, parent: int, fields := {}, client := false) -> int:
	var id := _next_client if client else _next_object
	if client:
		_next_client += 1
	else:
		_next_object += 1
	var rec := {"id": id, "class": cls, "name": obj_name, "fields": {}, "parent": 0, "children": [],
		"datablock": "", "node": null, "deleted": false}
	for f in fields:
		rec.fields[String(f).to_lower()] = fields[f]
	rec.datablock = DarkstarScript.to_str(rec.fields.get("datablock", "")).to_lower()
	objects[id] = rec
	set_name(id, obj_name)
	if parent > 0:
		add_child(parent, id)
	return id


func set_name(id: int, obj_name: String) -> void:
	var rec := get_record(id)
	if rec.is_empty():
		return
	var old := String(rec.name).to_lower()
	if old != "" and _by_name.has(old):
		(_by_name[old] as Array).erase(id)
	rec.name = obj_name
	if obj_name != "":
		var key := obj_name.to_lower()
		if not _by_name.has(key):
			_by_name[key] = []
		(_by_name[key] as Array).append(id)


## Moves `child` into group `parent` (out of its old group).
func add_child(parent: int, child: int) -> void:
	var rec := get_record(child)
	if rec.is_empty() or not objects.has(parent) or parent == child:
		return
	if objects.has(int(rec.parent)):
		(objects[int(rec.parent)].children as Array).erase(child)
	rec.parent = parent
	(objects[parent].children as Array).append(child)


func remove_child(parent: int, child: int) -> void:
	if objects.has(parent):
		(objects[parent].children as Array).erase(child)
	var rec := get_record(child)
	if not rec.is_empty() and int(rec.parent) == parent:
		rec.parent = 0


## Deletes `id` and everything in it.
func delete(id: int) -> void:
	var rec := get_record(id)
	if rec.is_empty():
		return
	for c in (rec.children as Array).duplicate():
		delete(int(c))
	if objects.has(int(rec.parent)):
		(objects[int(rec.parent)].children as Array).erase(id)
	var key := String(rec.name).to_lower()
	if _by_name.has(key):
		(_by_name[key] as Array).erase(id)
	rec.deleted = true
	objects.erase(id)


func exists(id: int) -> bool:
	return objects.has(id)


func get_record(id: int) -> Dictionary:
	return objects.get(id, {})


## Object id of a script value: an id, a name, or a group path; 0 = none.
func resolve(v) -> int:
	if v is int or v is float:
		return int(v) if objects.has(int(v)) else 0
	var s := String(v).strip_edges()
	if s == "":
		return 0
	if s.is_valid_int():
		return int(s) if objects.has(int(s)) else 0
	if s.is_valid_float():
		return resolve(int(float(s)))
	if s.contains("/") or s.contains("\\"):
		return resolve_path(s)
	var ids: Array = _by_name.get(s.to_lower(), [])
	return int(ids.back()) if not ids.is_empty() else 0


## "MissionGroup/Teams/team1/DropPoints" (either separator, any letter case).
func resolve_path(path: String) -> int:
	var parts := path.replace("\\", "/").split("/", false)
	if parts.is_empty():
		return 0
	var cur := resolve(parts[0])
	for i in range(1, parts.size()):
		cur = find_child(cur, parts[i])
		if cur == 0:
			return 0
	return cur


func find_child(group: int, child_name: String) -> int:
	var key := child_name.to_lower()
	for c in get_record(group).get("children", []):
		if String(objects[int(c)].name).to_lower() == key:
			return int(c)
	return 0


func children_of(group: int) -> Array:
	return (get_record(group).get("children", []) as Array).duplicate()


## Every object under `group` (depth first), groups included.
func descendants_of(group: int) -> Array:
	var out := []
	for c in children_of(group):
		out.append(c)
		out.append_array(descendants_of(int(c)))
	return out


## "MissionGroup/Teams/team1/..." of `id`.
func path_of(id: int) -> String:
	var parts := []
	var cur := id
	var guard := 0
	while objects.has(cur) and guard < 64:
		parts.push_front(String(objects[cur].name))
		cur = int(objects[cur].parent)
		guard += 1
	return "/".join(parts)


## The team of an object: its own "team" field, else the TeamGroup / "team<N>" group it is in (-1 = none).
func team_of(id: int) -> int:
	var rec := get_record(id)
	if rec.is_empty():
		return -1
	if rec.fields.has("team") and DarkstarScript.is_num(rec.fields.team):
		return int(DarkstarScript.num(rec.fields.team))
	var cur := int(rec.parent)
	var guard := 0
	while objects.has(cur) and guard < 64:
		var n := String(objects[cur].name).to_lower()
		if n.begins_with("team") and n.substr(4).is_valid_int():
			return int(n.substr(4))
		cur = int(objects[cur].parent)
		guard += 1
	return -1


## Engine-frame position: the node's, else the record's original `position` field.
func position_of(id: int) -> Vector3:
	var rec := get_record(id)
	if rec.is_empty():
		return Vector3.ZERO
	var node = rec.get("node")
	if node is Node3D and is_instance_valid(node) and (node as Node3D).is_inside_tree():
		return (node as Node3D).global_position
	return to_engine(DarkstarStdLib.make_vector(DarkstarScript.to_str(rec.fields.get("position", "0 0 0"))))


## Every id whose class is `cls` (lower case compare).
func ids_of_class(cls: String) -> Array:
	var out := []
	for id in objects:
		if String(objects[id].class).to_lower() == cls:
			out.append(id)
	return out


## The object whose node is `node` (0 = none).
func id_of_node(node: Object) -> int:
	for id in objects:
		if objects[id].node == node:
			return id
	return 0

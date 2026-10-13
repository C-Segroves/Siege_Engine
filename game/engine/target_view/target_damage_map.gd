class_name TargetDamageMap
extends RefCounted
## Which damage components each visible part of a vehicle model stands for, for every pack
## (docs/formats/cockpit.md section 4.2):
##   * 3Space (Earthsiege 1 / 2): a DMG component's `shape_part` is the damage slot of the shape's
##     cells (ShapeInstance cell slot), so a cell mesh shows the components of its slot; WEAPON n
##     components are the weapon pods on hardpoint n - 1.
##   * Darkstar (Starsiege): components name their DTS node (`ss_name` "LeftCalf" = node "Left_Calf0").
##   * Battledrome and Tribes vehicles have one HULL component: the whole model shows it.
## Parts without a component of their own show their shape node's (inherited from the parent node),
## else the vehicle's root component.

const WEAPON_COMPONENT_PREFIX := "WEAPON "
const WEAPON_MODEL_PREFIX := "weapon"
## DTS node names end in their detail level ("Left_Calf0", "Left_Calf1" ...).
const DIGITS := "0123456789"


## MeshInstance3D of `model` (a ShapeInstance built from `vdef`) -> Array of component indices.
static func make_mesh_components(vdef: Dictionary, model: ShapeInstance) -> Dictionary:
	var comps: Array = vdef.get("damage", {}).get("components", [])
	var by_slot := _make_slot_components(comps)
	var by_node := _make_node_components(comps, model, by_slot)
	var cell_of := model.make_cell_of_meshes()
	var weapons := _make_weapon_components(comps)
	var root := [root_component(comps)]
	var out := {}
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		out[mi] = _components_of_mesh(mi, model, {"cell_of": cell_of, "by_slot": by_slot, "by_node": by_node,
			"weapons": weapons, "root": root})
	return out


static func _components_of_mesh(mi: MeshInstance3D, model: ShapeInstance, maps: Dictionary) -> Array:
	if maps.cell_of.has(mi):
		var slot := model.get_cell_slot(int(maps.cell_of[mi]))
		if maps.by_slot.has(slot):
			return maps.by_slot[slot]
	var weapon := _weapon_index_of(mi, model)
	if weapon >= 0 and maps.weapons.has(weapon):
		return [maps.weapons[weapon]]
	var node: Node = mi.get_parent()
	while node != null and node != model:
		var i := model.nodes.find(node)
		if i >= 0 and maps.by_node.has(i):
			return maps.by_node[i]
		node = node.get_parent()
	return maps.root


## Damage slot -> component indices (3Space DMG `shape_part`).
static func _make_slot_components(comps: Array) -> Dictionary:
	var out := {}
	for i in comps.size():
		var slot := int(comps[i].get("shape_part", -1))
		if slot >= 0:
			if not out.has(slot):
				out[slot] = []
			out[slot].append(i)
	return out


## Shape node index -> component indices: the node's cells' slots (3Space) or its DTS name (Darkstar),
## inherited by child nodes that have none.
static func _make_node_components(comps: Array, model: ShapeInstance, by_slot: Dictionary) -> Dictionary:
	var own := _make_named_node_components(comps, model)
	for ci in model.cell_count():
		var slot := model.get_cell_slot(ci)
		var n := int(model.shape.lods[model.lod].cells[ci].get("node", -1))
		if by_slot.has(slot) and not own.has(n):
			own[n] = by_slot[slot]
	var out := {}
	for i in model.nodes.size():
		var k := i
		while k >= 0 and not own.has(k):
			k = int(model.shape.nodes[k].get("parent", -1))
		if k >= 0:
			out[i] = own[k]
	return out


static func _make_named_node_components(comps: Array, model: ShapeInstance) -> Dictionary:
	var by_name := {}
	for i in comps.size():
		var n := str(comps[i].get("ss_name", ""))
		if n != "":
			by_name[make_node_key(n)] = [i]
	var out := {}
	if by_name.is_empty():
		return out
	var nodes: Array = model.shape.get("nodes", [])
	for i in nodes.size():
		var key := make_node_key(str(nodes[i].get("name", "")))
		if by_name.has(key):
			out[i] = by_name[key]
	return out


## Node / component name without underscores, case and its trailing detail-level digits.
static func make_node_key(n: String) -> String:
	var s := n.replace("_", "").to_lower()
	while s.length() > 0 and DIGITS.contains(s[s.length() - 1]):
		s = s.left(s.length() - 1)
	return s


## Hardpoint index -> its WEAPON component ("WEAPON 1" = hardpoint 0).
static func _make_weapon_components(comps: Array) -> Dictionary:
	var out := {}
	for i in comps.size():
		var n := str(comps[i].get("name", ""))
		if n.begins_with(WEAPON_COMPONENT_PREFIX):
			out[int(n.substr(WEAPON_COMPONENT_PREFIX.length())) - 1] = i
	return out


## Hardpoint index of the weapon model `mi` belongs to (HercModel names them "weapon<i>"), else -1.
static func _weapon_index_of(mi: Node, model: ShapeInstance) -> int:
	var node := mi.get_parent()
	while node != null and node != model:
		var n := str(node.name)
		if n.begins_with(WEAPON_MODEL_PREFIX) and n.substr(WEAPON_MODEL_PREFIX.length()).is_valid_int():
			return int(n.substr(WEAPON_MODEL_PREFIX.length()))
		node = node.get_parent()
	return -1


## The body's component: the first fatal one (3Space FRONT_COCKPIT, Starsiege PELVIS / HEAD, the
## Tribes HULL), else the first (a vehicle listing none gets one HULL, HercDamage.make_components).
static func root_component(comps: Array) -> int:
	for i in comps.size():
		if comps[i].get("fatal", false):
			return i
	return 0

class_name MapWater
extends Node
## The water (and lava, ...) volumes of a map: the map schema's environment "water" boxes (Tribes 2 WaterBlocks:
## surface level, bottom, x/z extent; tools/export_tribes2_maps.py). Child "Water" of the battle world; answers
## whether a point is in liquid (projectile water drag, Projectile).

const NODE_NAME := "MapWater"
const GROUP := "map_water"

var boxes: Array[AABB] = []


## Adds the water of environment `env` under `parent` (nothing when the map has none).
static func build(parent: Node3D, env: Dictionary) -> void:
	var list: Array = env.get("water", [])
	if list.is_empty():
		return
	var w := MapWater.new()
	w.name = NODE_NAME
	for b in list:
		var lo: Array = b.min
		var hi: Array = b.max
		var p := Vector3(float(lo[0]), float(b.bottom), float(lo[1]))
		w.boxes.append(AABB(p, Vector3(float(hi[0]) - p.x, float(b.level) - p.y, float(hi[1]) - p.z)))
	w.add_to_group(GROUP)
	parent.add_child(w)


## True when `pos` is inside any map's liquid.
static func is_in_water(tree: SceneTree, pos: Vector3) -> bool:
	for w in tree.get_nodes_in_group(GROUP):
		for box in (w as MapWater).boxes:
			if box.has_point(pos):
				return true
	return false

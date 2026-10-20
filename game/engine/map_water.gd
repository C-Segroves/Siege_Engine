class_name MapWater
extends Node
## The water (and lava, ...) volumes of a map: the map schema's environment "water" boxes (Tribes 2 WaterBlocks:
## surface level, bottom, x/z extent; tools/export_tribes2_maps.py). Child "Water" of the battle world; answers
## whether a point is in liquid (projectile water drag, Projectile).

const NODE_NAME := "MapWater"
const GROUP := "map_water"

const SURFACE_COLOUR := Color(0.12, 0.32, 0.45, 0.72)

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
		if bool(b.get("visible", false)) and not ServerProfile.is_collision_only():
			w.add_child(_make_surface(Vector2(float(lo[0]), float(lo[1])), Vector2(float(hi[0]), float(hi[1])), float(b.level)))
	w.add_to_group(GROUP)
	parent.add_child(w)


## A translucent sheet at `level` over the box's x/z extent (maps that ask for it: "visible": true).
static func _make_surface(lo: Vector2, hi: Vector2, level: float) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = hi - lo
	var mat := StandardMaterial3D.new()
	mat.albedo_color = SURFACE_COLOUR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.08
	mat.metallic_specular = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	plane.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.position = Vector3((lo.x + hi.x) * 0.5, level, (lo.y + hi.y) * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## True when `pos` is inside any map's liquid.
static func is_in_water(tree: SceneTree, pos: Vector3) -> bool:
	for w in tree.get_nodes_in_group(GROUP):
		for box in (w as MapWater).boxes:
			if box.has_point(pos):
				return true
	return false

extends Node
## Tribes: Vengeance baked BSP lighting (tools/tv_bsp_render.py): every campaign map with a compiled BSP draws its lit
## twin (`bspl_<map>`: polygons with a lightmap `uv2`, materials naming a 512 x 512 lightmap page) and keeps the brush
## shell (`bsp_<map>`) as collision only, and the map builder dresses the lit shape in the lightmap material.
##   godot --headless --audio-driver Dummy --path game res://tests/tv_lightmap_check.tscn
## TV_TEST_ROOT=<folder with tribes_v/> points the check at a scratch data folder (else the installed one).
## Skips (exit 0) when Tribes: Vengeance is not imported.

const WATCHDOG_SECONDS := 240.0
const PACK := "tribes_v"
const MAPS_WITHOUT_BSP := 1                       # SP-War-Ski has no compiled BSP nodes
const SHAPE_CHECKED := ["SP-Prison-Interior", "SP-Revenge-UnderCity", "SP-Captured", "SP-FirstBlood-Interior"]
const BUILT_MAP := "SP-Prison-Interior"
const LIGHTMAP_SHADER := "res://engine/shaders/unified_lit_lightmap.gdshader"
const PAGE_SIZE := 512

var _fails := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void:
		print("FAIL  watchdog: the check hung")
		get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var root := OS.get_environment("TV_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	if not Assets.has_pack(PACK):
		print("tv_lightmap_check: Tribes: Vengeance is not imported, skipped")
		get_tree().quit(0)
		return
	_check_map_entries()
	for id in SHAPE_CHECKED:
		_check_lit_shape(id)
	await _check_built_map(BUILT_MAP)
	print("tv_lightmap_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


## The statics of every map: the lit twin is drawn only and the shell it replaces collides only.
func _check_map_entries() -> void:
	var idx = Assets.load_json("maps/_index.json", PACK)
	var lit_maps := 0
	var bad := 0
	for e in idx:
		var statics: Array = MapBuilder.load_map("%s:%s" % [PACK, e.id]).get("statics", [])
		var lit := statics.filter(func(o: Dictionary) -> bool: return str(o.shape).begins_with("%s:bspl_" % PACK))
		var shell := statics.filter(func(o: Dictionary) -> bool: return str(o.shape).begins_with("%s:bsp_" % PACK))
		if lit.is_empty():
			continue
		lit_maps += 1
		var lit_ok: bool = lit.size() == 1 and not bool(lit[0].collide) and bool(lit[0].get("visual_only", false))
		var shell_ok: bool = shell.size() == 1 and not bool(shell[0].get("drawn", true)) and bool(shell[0].collide)
		bad += 0 if lit_ok and shell_ok else 1
	_expect(lit_maps == idx.size() - MAPS_WITHOUT_BSP, "%d of %d maps draw a lit BSP" % [lit_maps, idx.size()])
	_expect(bad == 0, "each lit twin is drawn only and each shell collides only (%d bad)" % bad)


## The polygons of a lit shape carry a lightmap uv2 in [0, 1] per vertex and name an existing page for their material.
func _check_lit_shape(map_id: String) -> void:
	var sid := "%s:bspl_%s" % [PACK, map_id.to_lower()]
	var shape := Assets.shape(sid)
	var polys: Array = shape.lods[0].pieces[0].polys
	var materials: Array = shape.materials
	var unlit := 0
	var bad_uv := 0
	var missing_page := 0
	for poly in polys:
		var mat: Dictionary = materials[int(poly.m.index)]
		if String(mat.get("lightmap", "")) == "":
			unlit += 1
			continue
		var uv2: Array = poly.get("uv2", [])
		if uv2.size() != (poly.v as Array).size() or not _all_in_unit_square(uv2):
			bad_uv += 1
	for mat in materials:
		var page := String(mat.get("lightmap", ""))
		if page != "" and (Assets.load_image(page, PACK) == null or Assets.load_image(page, PACK).get_width() != PAGE_SIZE):
			missing_page += 1
	_expect(polys.size() > 100, "%s: %d lit polygons" % [map_id, polys.size()])
	_expect(unlit * 10 < polys.size(), "%s: nearly every polygon is lightmapped (%d of %d are not)" % [map_id, unlit, polys.size()])
	_expect(bad_uv == 0, "%s: every lightmapped vertex has a uv2 inside its page (%d bad)" % [map_id, bad_uv])
	_expect(missing_page == 0, "%s: every lightmap page is a %d px image (%d bad)" % [map_id, PAGE_SIZE, missing_page])


static func _all_in_unit_square(uvs: Array) -> bool:
	for t in uvs:
		if not (is_finite(float(t[0])) and is_finite(float(t[1]))) or float(t[0]) < 0.0 or float(t[0]) > 1.0 or float(t[1]) < 0.0 or float(t[1]) > 1.0:
			return false
	return true


## MapBuilder: the shell keeps its collision and loses its meshes, the lit twin has meshes in the lightmap material and no collision.
func _check_built_map(map_id: String) -> void:
	var parent := Node3D.new()
	add_child(parent)
	MapBuilder.build(parent, "%s:%s" % [PACK, map_id])
	await get_tree().process_frame
	await get_tree().process_frame
	var shell := parent.get_node_or_null("%s_bsp_%s" % [PACK, map_id.to_lower()])
	var lit := parent.get_node_or_null("%s_bspl_%s" % [PACK, map_id.to_lower()])
	_expect(shell != null and lit != null, "%s: both BSP statics are placed" % map_id)
	if shell == null or lit == null:
		return
	_expect(not shell.find_children("*", "CollisionShape3D", true, false).is_empty(), "the shell keeps its collision")
	_expect(shell.find_children("*", "MeshInstance3D", true, false).is_empty(), "the shell draws nothing")
	_expect(lit.find_children("*", "CollisionShape3D", true, false).is_empty(), "the lit twin has no collision")
	var meshes := lit.find_children("*", "MeshInstance3D", true, false)
	_expect(not meshes.is_empty(), "the lit twin draws")
	_expect(_count_lightmapped_surfaces(meshes) > 0, "its surfaces use the lightmap material with a %d px page" % PAGE_SIZE)
	parent.queue_free()


func _count_lightmapped_surfaces(meshes: Array) -> int:
	var count := 0
	for mi in meshes:
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s)
			if mat is ShaderMaterial and (mat as ShaderMaterial).shader.resource_path == LIGHTMAP_SHADER:
				var page = (mat as ShaderMaterial).get_shader_parameter("lightmap")
				if page is Texture2D and (page as Texture2D).get_width() == PAGE_SIZE:
					count += 1
	return count

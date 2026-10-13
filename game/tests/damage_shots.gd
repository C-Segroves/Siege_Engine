extends Control
## Renders Hercs intact and heavily damaged (every damage cell in state 1, as HercDamage wrecks components) to
## compare the damaged look with the originals (playtest E5).
##   Godot --path game res://tests/damage_shots.tscn -- --hercs=es1:RAPTOR,es2:OUTLAW --out=../renders/fix_e_damage
## Saves <out>_<pack>_<name>.png (left intact, right damaged); prints per Herc how many damaged-state surfaces
## have no texture although the intact state is textured.

const DAMAGED_STATE := 1
const SETTLE_SECONDS := 1.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var hercs: PackedStringArray = ["es1:RAPTOR", "bd:THOR", "es2:OUTLAW", "starsiege:cy_prom"]
	var out := "../renders/fix_e_damage"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--hercs="):
			hercs = a.substr(8).split(",")
		elif a.begins_with("--out="):
			out = a.substr(6)
	var view := HangarView.new()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(view)
	for vid in hercs:
		view.show_herc(vid, Packs.vehicle(vid).get("loadout", []))
		view.bay.reset_view(true)
		var intact := await _capture()
		var model: ShapeInstance = view.bay.model
		var cells := model.cell_count() if model else 0
		for ci in cells:
			model.set_cell_state(ci, DAMAGED_STATE)
		var damaged := await _capture()
		_print_damaged_materials(model)
		var sheet := Image.create(intact.get_width() * 2, intact.get_height(), false, intact.get_format())
		sheet.blit_rect(intact, Rect2i(Vector2i.ZERO, intact.get_size()), Vector2i.ZERO)
		sheet.blit_rect(damaged, Rect2i(Vector2i.ZERO, damaged.get_size()), Vector2i(intact.get_width(), 0))
		sheet.save_png("%s_%s.png" % [out, vid.replace(":", "_")])
		print("damage_shots: %s cells %d" % [vid, cells])
	get_tree().quit()


func _capture() -> Image:
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## Prints the materials of the damaged-state meshes (shaded polys: ShaderMaterial "shaded.gdshader").
func _print_damaged_materials(model: ShapeInstance) -> void:
	var kinds := {}
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if not m.visible or m.mesh == null:
			continue
		for si in m.mesh.get_surface_count():
			var mat := m.get_active_material(si)
			var k := mat.get_class() + (":" + (mat as ShaderMaterial).shader.resource_path.get_file() if mat is ShaderMaterial else "")
			kinds[k] = int(kinds.get(k, 0)) + 1
	print("damage_shots: visible surface materials ", kinds)

extends Node3D
## Contact sheets of every pack's death effects (needs a window): renders/death_fx_<pack>.png, one row per
## case of DeathFxStage (unit death, component, structure, turret, soldier, grenade burst) at SAMPLES seconds.
## godot --audio-driver Dummy --path game res://tests/death_fx_sheet.tscn [-- --pack=es1 --out=<dir>]

const Stage := preload("res://tests/death_fx_stage.gd")
const CELL := Vector2i(320, 220)
const SAMPLES := [0.1, 0.3, 0.6, 1.0, 1.6]
const SPOT := Vector3(0, 0, 0)
## Camera distance / look height per case kind (metres).
const VIEW := {"vehicle": Vector2(20, 5), "component": Vector2(16, 5), "structure": Vector2(45, 8),
	"turret": Vector2(18, 3), "infantry": Vector2(7, 1.2), "burst": Vector2(12, 1)}
const BACKGROUND := Color(0.16, 0.17, 0.2)
const GROUND := Color(0.28, 0.27, 0.24)

var _out_dir := ""
var _only_pack := ""
var _cam: Camera3D
var _caption: Label


func _ready() -> void:
	_out_dir = ProjectSettings.globalize_path("res://").path_join("../renders").simplify_path()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pack="):
			_only_pack = a.substr(7)
		if a.begins_with("--out="):
			_out_dir = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_build_world()
	for pack in Assets.installed_packs():
		if _only_pack == "" or pack == _only_pack:
			await _sheet(pack)
	get_tree().quit()


func _build_world() -> void:
	SceneLighting.add_studio_environment(self, {"background": BACKGROUND})
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(600, 600)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GROUND
	ground.material_override = mat
	add_child(ground)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	floor_shape.shape = WorldBoundaryShape3D.new()
	floor_body.add_child(floor_shape)
	add_child(floor_body)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true
	var layer := CanvasLayer.new()
	add_child(layer)
	_caption = Label.new()
	_caption.position = Vector2(16, 12)
	_caption.add_theme_font_size_override("font_size", 36)
	layer.add_child(_caption)


func _sheet(pack: String) -> void:
	var rows := []
	for c in Stage.make_cases(pack):
		rows.append(await _row(c))
	_save_sheet(rows, "death_fx_%s.png" % pack)


func _row(c: Dictionary) -> Array:
	var view: Vector2 = VIEW.get(str(c.kind), Vector2(40, 5))
	_cam.position = SPOT + Vector3(0, view.y + view.x * 0.25, view.x)
	_cam.look_at(SPOT + Vector3.UP * view.y)
	var stage := Node3D.new()
	add_child(stage)
	c.run.call(stage, SPOT)
	var frames := []
	var t := 0.0
	for at in SAMPLES:
		await get_tree().create_timer(at - t).timeout
		t = at
		_caption.text = "%s  %.1fs" % [c.label, at]
		frames.append(await _capture())
	stage.queue_free()
	await get_tree().create_timer(0.3).timeout
	return [str(c.label), frames]


func _capture() -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(CELL.x, CELL.y, Image.INTERPOLATE_BILINEAR)
	return img


func _save_sheet(rows: Array, file: String) -> void:
	if rows.is_empty():
		return
	var sheet := Image.create(CELL.x * SAMPLES.size(), CELL.y * rows.size(), false, Image.FORMAT_RGBA8)
	for r in rows.size():
		var frames: Array = rows[r][1]
		for i in frames.size():
			var img: Image = frames[i]
			img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, CELL), Vector2i(i * CELL.x, r * CELL.y))
	var path := _out_dir.path_join(file)
	sheet.save_png(path)
	print("saved %s (%s)" % [path, ", ".join(rows.map(func(row): return str(row[0])))])

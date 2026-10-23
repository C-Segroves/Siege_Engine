extends Node
## Windowed side-view renders of the additive layers (look, head, recoil), one PNG per body: a soldier looking up, level and
## down, then level at the peak of a shot's recoil, to be checked by eye next to infantry_additive_check.
##   godot --audio-driver Dummy --path game res://tests/infantry_additive_shots.tscn -- --shots=<dir> [--pitch=0.9]
## --plain turns the layers off for a comparison. Writes <dir>/additive_<body>.png for each body the pack has installed.
const CELL := Vector2i(300, 360)
const SPACING := 4.0
const SETTLE_FRAMES := 30
const RECOIL_FRAMES := 8
const CAMERA_OFFSET := Vector3(3.2, 1.35, 0.0)
const TARGET_OFFSET := Vector3(0.0, 1.15, 0.0)
## [armour id, body shape id ("" = the armour's own), weapon name].
const CASES := [
	["tribes:LIGHT", "", "PLASMA_GUN"], ["tribes2:LIGHT", "", "SPINFUSOR"], ["tribes2:LIGHT", "tribes2:bioderm_light", "SPINFUSOR"],
	["tribes:LIGHT", "tribes_aa:light_male", "PLASMA_GUN"], ["tribes:MEDIUM", "tribes_aa:medium_male", "MISSILE_LAUNCHER"],
	["tribes:LIGHT", "tribes_aa:light_bioderm", "PLASMA_GUN"],
]

var _shots := ""
var _pitch := 0.9
var _plain := false
var _stage: Node3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
		elif a == "--plain":
			_plain = true   # the layers off (far_lod), for comparison
		elif a.begins_with("--pitch="):
			_pitch = float(a.substr(8))
	if _shots == "" or DisplayServer.get_name() == "headless":
		print("infantry_additive_shots: needs a window and --shots=<dir>")
		get_tree().quit(1)
		return
	_run.call_deferred()


func _run() -> void:
	Assets.refresh()
	Packs.reload()
	for c in CASES:
		await _shoot(c[0], c[1], c[2])
	get_tree().quit(0)


func _shoot(armor_id: String, body: String, weapon_name: String) -> void:
	var shape_id := body if body != "" else str(InfantryCatalog.armor(armor_id).get("shape", ""))
	if InfantryCatalog.armor(armor_id).is_empty() or not InfantryCatalog.is_shape_installed(shape_id):
		return
	_build_stage()
	var soldiers := []
	for i in 4:
		var s := Infantry.new()
		s.armor_id = armor_id
		s.body_shape = body
		s.net_id = i + 1
		_stage.add_child(s)
		s.global_position = Vector3(i * SPACING, 0.2, 0.0)
		s.equip([_weapon_id(armor_id, shape_id, weapon_name)])
		s.apply_weapon_slot(0)
		s.far_lod = _plain
		s.pitch_target = [_pitch, 0.0, -_pitch, 0.0][i]
		soldiers.append(s)
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	soldiers[3].weapons[0].cooldown = 1.0   # the shot of the fourth soldier
	for i in RECOIL_FRAMES:
		await get_tree().physics_frame
	var views := []
	for s in soldiers:
		views.append(_add_view(s))
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var sheet := Image.create(CELL.x * soldiers.size(), CELL.y, false, Image.FORMAT_RGB8)
	for i in views.size():
		var img: Image = views[i].get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, CELL), Vector2i(i * CELL.x, 0))
	var path := "%s/additive_%s.png" % [_shots, shape_id.replace(":", "_")]
	sheet.save_png(path)
	print("  shot ", path)
	for v in views:
		v.queue_free()
	_stage.queue_free()
	await get_tree().process_frame


func _weapon_id(armor_id: String, shape_id: String, weapon_name: String) -> String:
	var rules := InfantryCatalog.make_pack_rules(shape_id.get_slice(":", 0), armor_id.get_slice(":", 1))
	for id in rules.get("weapons", []):
		if str(id).ends_with(":" + weapon_name):
			return str(id)
	for id in InfantryCatalog.armor(armor_id).get("weapons", []):
		if str(id).ends_with(":" + weapon_name):
			return str(id)
	return ""


func _build_stage() -> void:
	_stage = Node3D.new()
	add_child(_stage)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 150, 0)
	_stage.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.65, 0.75)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.6)
	_stage.add_child(env)
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(SPACING * 6.0, 2.0, 8.0)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(SPACING * 1.5, -1.0, 0.0)
	_stage.add_child(floor_body)


func _add_view(s: Infantry) -> SubViewport:
	var view := SubViewport.new()
	view.size = CELL
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.own_world_3d = false
	add_child(view)
	var cam := Camera3D.new()
	view.add_child(cam)
	cam.global_transform = Transform3D(Basis(), s.global_position + CAMERA_OFFSET).looking_at(s.global_position + TARGET_OFFSET, Vector3.UP)
	return view

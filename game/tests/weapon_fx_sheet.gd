extends Node3D
## Contact sheets of every pack's weapon effects (needs a window):
##   renders/weapon_fx_<pack>_<page>.png   one row per weapon firing at a target block: muzzle / in flight /
##                                          impact / after (a frame strip per weapon);
##   renders/weapon_fx_<pack>_effects.png  every effect of the pack's library at three moments;
##   renders/weapon_fx_<pack>_beams.png    every beam close up, held for BEAM_HOLD_S (colour, texture, frames).
## godot --audio-driver Dummy --path game res://tests/weapon_fx_sheet.tscn
##     [-- --pack=es1 --out=<dir> --prefix=fx2_ --world=WORLD2]
## --prefix replaces "weapon_fx_" in the file names; --world draws Earthsiege effects in that world palette.

const CELL := Vector2i(320, 200)
const WEAPONS_PER_PAGE := 10
const LANE_LENGTH := 28.0
const TARGET_SIZE := Vector3(4, 6, 4)
const EFFECT_COLUMNS := 8
const EFFECT_SPACING := 14.0
const EFFECT_SAMPLES := [0.08, 0.35, 0.9]
const PASSIVE_KINDS := ["ecm", "other"]
const BEAM_KINDS := ["beam", "emp", "flame"]
## Beams last one sim frame in ES1/ES2: the close-up page holds each for this long to sample it.
const BEAM_HOLD_S := 1.0
const BEAM_SAMPLES := [0.05, 0.3, 0.55, 0.85]
const BACKGROUND := Color(0.16, 0.17, 0.2)
const GROUND := Color(0.28, 0.27, 0.24)

var _out_dir := ""
var _only_pack := ""
var _prefix := "weapon_fx_"
var _world := ""
var _cam: Camera3D
var _stage: Node3D
var _target: StaticBody3D
var _caption: Label


func _ready() -> void:
	_out_dir = ProjectSettings.globalize_path("res://").path_join("../renders").simplify_path()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pack="):
			_only_pack = a.substr(7)
		if a.begins_with("--out="):
			_out_dir = a.substr(6)
		if a.begins_with("--prefix="):
			_prefix = a.substr(9)
		if a.begins_with("--world="):
			_world = a.substr(8)
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_build_world()
	for pack in Assets.installed_packs():
		if _only_pack == "" or pack == _only_pack:
			if _world != "":
				FxLibrary.set_world_palette("%s:%s" % [pack, _world])
			await _sheet_weapons(pack)
			await _sheet_effects(pack)
			await _sheet_beams(pack)
	get_tree().quit()


func _build_world() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = BACKGROUND
	env.environment.ambient_light_color = Color(0.5, 0.5, 0.55)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = GROUND
	ground.material_override = ground_mat
	add_child(ground)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true
	_stage = Node3D.new()
	add_child(_stage)
	_target = _build_target()
	add_child(_target)
	var layer := CanvasLayer.new()
	add_child(layer)
	_caption = Label.new()
	_caption.position = Vector2(16, 12)
	_caption.add_theme_font_size_override("font_size", 40)
	layer.add_child(_caption)


## The block every weapon fires at (armour surface: it has no shield).
func _build_target() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_script(preload("res://tests/weapon_fx_target.gd"))
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = TARGET_SIZE
	mi.mesh = box
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = TARGET_SIZE
	col.shape = shape
	body.add_child(col)
	body.position = Vector3(LANE_LENGTH * 0.5, TARGET_SIZE.y * 0.5, 0)
	return body


# ------------------------------------------------------------------ weapon strips

func _sheet_weapons(pack: String) -> void:
	var defs := _firing_weapons(pack)
	_target.visible = true
	_cam.position = Vector3(0, 5, 20)
	_cam.look_at(Vector3(0, 2.5, 0))
	for page in ceili(defs.size() / float(WEAPONS_PER_PAGE)):
		var rows := []
		for def in defs.slice(page * WEAPONS_PER_PAGE, (page + 1) * WEAPONS_PER_PAGE):
			rows.append(await _strip(def))
		_save_sheet(rows, 4, "%s%s_%d.png" % [_prefix, pack, page])


func _firing_weapons(pack: String) -> Array:
	var out := []
	for id in Packs.weapons:
		var def: Dictionary = Packs.weapons[id]
		if FxLibrary.weapon_pack(def) == pack and not (str(def.kind) in PASSIVE_KINDS):
			out.append(def)
	out.sort_custom(func(a, b): return str(a.id) < str(b.id))
	return out


## Four moments of one shot: just fired, in flight, impact, after.
func _strip(def: Dictionary) -> Array:
	var from := Vector3(-LANE_LENGTH * 0.5, 2.5, 0)
	var to := _target.position + Vector3(-TARGET_SIZE.x * 0.5, -0.5, 0)
	var flight := _flight_seconds(def, from.distance_to(to))
	var frames := []
	_caption.text = "%s  (%s)" % [def.id, def.kind]
	_fire(def, from, to)
	var t := 0.0
	for at in [0.03, flight * 0.5, flight + 0.06, flight + 0.45]:
		await _wait(maxf(0.0, at - t))
		t = maxf(t, at)
		frames.append(await _capture())
	_clear_stage()
	await _wait(0.1)
	return [str(def.id), frames]


func _flight_seconds(def: Dictionary, distance: float) -> float:
	if str(def.kind) in BEAM_KINDS and not (def.get("projectile") is Dictionary):
		return 0.0
	var speed := float(def.get("speed", 0.0))
	return clampf(distance / maxf(speed, 1.0), 0.05, 2.5)


func _fire(def: Dictionary, from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	Effects.fx.play_muzzle(_stage, def, from, dir)
	if str(def.kind) in BEAM_KINDS and not (def.get("projectile") is Dictionary):
		Effects.fx.play_beam(_stage, def, from, to)
		Effects.fx.play_impact(_stage, def, FxSurface.ARMOR, to, -dir)
		return
	var p := Weapon.make_projectile(def, null, from, dir, null, true)
	p.gravity = 0.0
	_stage.add_child(p)
	p.global_position = from


# ------------------------------------------------------------------ beam close-ups

func _sheet_beams(pack: String) -> void:
	var rows := []
	_target.visible = false
	_cam.position = Vector3(0, 2.5, 4)
	_cam.look_at(Vector3(0, 2.5, 0))
	for def in _firing_weapons(pack):
		var fx: Dictionary = FxLibrary.weapon_fx(def)
		if not (fx.get("beam") is Dictionary):
			continue
		var held: Dictionary = def.duplicate(true)
		held["fx"] = fx.duplicate(true)
		held.fx.beam["duration"] = BEAM_HOLD_S
		_caption.text = "%s  beam (%s)" % [def.id, FxLibrary.make_palette_name(fx.beam, pack)]
		Effects.fx.play_beam(_stage, held, Vector3(-6, 2.5, 0), Vector3(6, 2.5, 0))
		var frames := []
		var t := 0.0
		for at in BEAM_SAMPLES:
			await _wait(at - t)
			t = at
			frames.append(await _capture())
		_clear_stage()
		await _wait(0.05)
		rows.append([str(def.id), frames])
	_target.visible = true
	_save_sheet(rows, BEAM_SAMPLES.size(), "%s%s_beams.png" % [_prefix, pack])


# ------------------------------------------------------------------ effect gallery

func _sheet_effects(pack: String) -> void:
	var effects: Array = FxLibrary.library(pack).get("effects", {}).keys()
	if effects.is_empty():
		return
	_target.visible = false
	var rows := []
	for start in range(0, effects.size(), EFFECT_COLUMNS):
		var names := effects.slice(start, start + EFFECT_COLUMNS)
		rows.append_array(await _effect_row(pack, names))
	_target.visible = true
	_save_sheet(rows, EFFECT_COLUMNS, "%s%s_effects.png" % [_prefix, pack])


## One row per sample time, the row's effects side by side; the camera frames each effect in turn.
func _effect_row(pack: String, names: Array) -> Array:
	for i in names.size():
		Effects.fx.play_effect(_stage, names[i], pack, Vector3(i * EFFECT_SPACING, 3, 200))
	var t := 0.0
	var rows := []
	for at in EFFECT_SAMPLES:
		await _wait(at - t)
		t = at
		var frames := []
		for i in names.size():
			_caption.text = "%s:%s  %.2fs" % [pack, names[i], at]
			_cam.position = Vector3(i * EFFECT_SPACING, 5, 212)
			_cam.look_at(Vector3(i * EFFECT_SPACING, 3.5, 200))
			frames.append(await _capture())
		rows.append(["%s @%.2fs" % [names[0], at], frames])
	_clear_stage()
	await _wait(0.1)
	return rows


# ------------------------------------------------------------------ capture

func _wait(seconds: float) -> void:
	if seconds > 0.0:
		await get_tree().create_timer(seconds).timeout


func _capture() -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(CELL.x, CELL.y, Image.INTERPOLATE_BILINEAR)
	return img


func _clear_stage() -> void:
	for c in _stage.get_children():
		c.queue_free()


## rows = [[label, [Image]]]: label column then the frames, saved under the output folder.
func _save_sheet(rows: Array, columns: int, file: String) -> void:
	if rows.is_empty():
		return
	var sheet := Image.create(CELL.x * columns, CELL.y * rows.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	for r in rows.size():
		var frames: Array = rows[r][1]
		for c in mini(frames.size(), columns):
			var img: Image = frames[c]
			img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, CELL), Vector2i(c * CELL.x, r * CELL.y))
	var path := _out_dir.path_join(file)
	sheet.save_png(path)
	print("saved %s (%s)" % [path, ", ".join(rows.map(func(row): return str(row[0])))])

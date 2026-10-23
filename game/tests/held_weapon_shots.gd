extends Node
## Windowed render grids of the weapon in the soldier's hands, one pair of PNGs per body game (held_<game>_third.png,
## held_<game>_first.png): a row per body, a column per weapon, to be checked by eye next to held_weapon_check.
##   godot --audio-driver Dummy --path game res://tests/held_weapon_shots.tscn -- --shots=<dir> [--game=tribes2] [--pitch=0.5]
## --game limits the run to one body game (tribes, tribes2, tribes_aa, tribes_v); --pitch looks up (+) or down (-) in radians.
## The Aerial Assault and Vengeance bodies hold their own game's weapons (infantry_rules.json): --group=N shows the Nth three of them.

const CELL := Vector2i(360, 300)
const SPACING := 6.0
const SETTLE_FRAMES := 40
const WEAPON_COLUMNS := 3
const FIRST_PERSON_FOV := 75.0
const THIRD_PERSON_CAMERA := Vector3(1.9, 1.7, -2.1)
const THIRD_PERSON_TARGET := Vector3(0.15, 1.3, -0.45)
const PREFERRED_WEAPONS := ["CHAINGUN", "MORTAR", "SPINFUSOR", "LASER_RIFLE", "PLASMA_GUN", "PLASMA_RIFLE", "BLASTER"]
const BODY_GAMES := ["tribes", "tribes2", "tribes_aa", "tribes_v"]

var _shots := ""
var _game := ""
var _pitch := 0.0
var _group := 0
var _stage: Node3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
		elif a.begins_with("--game="):
			_game = a.substr(7)
		elif a.begins_with("--pitch="):
			_pitch = float(a.substr(8))
		elif a.begins_with("--group="):
			_group = int(a.substr(8))
	if _shots == "" or DisplayServer.get_name() == "headless":
		print("held_weapon_shots: needs a window and --shots=<dir>")
		get_tree().quit(1)
		return
	_run.call_deferred()


func _run() -> void:
	for game in BODY_GAMES:
		if _game == "" or _game == game:
			await _shoot_game(game)
	get_tree().quit(0)


func _shoot_game(game: String) -> void:
	var rows := _make_rows(game)
	if rows.is_empty():
		return
	_build_stage(rows.size() * WEAPON_COLUMNS)
	var soldiers := []
	for r in rows.size():
		for c in WEAPON_COLUMNS:
			soldiers.append(_add_soldier(rows[r], c, r * WEAPON_COLUMNS + c))
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	for mode in ["third", "first"]:
		await _shoot_grid(soldiers, rows.size(), mode == "first", "%s/held_%s_%s.png" % [_shots, game, mode])
	_stage.queue_free()
	await get_tree().process_frame


## [{armor, body}] of the armours (and their bodies) whose body shape belongs to `game`.
func _make_rows(game: String) -> Array:
	var rows := []
	var armor_pack := game if game in InfantryCatalog.INFANTRY_PACKS else ("tribes2" if InfantryCatalog.is_pack_usable("tribes2") else "tribes")
	for armor in InfantryCatalog.armors_of(armor_pack):
		for b in InfantryCatalog.make_bodies(str(armor.id)):
			if str(b.id).get_slice(":", 0) == game:
				rows.append({"armor": armor, "body": b})
	return rows


func _build_stage(cells: int) -> void:
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
	box.size = Vector3(SPACING * (cells + 2), 2.0, SPACING * 2.0)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(SPACING * cells * 0.5, -1.0, 0.0)
	_stage.add_child(floor_body)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(box.size.x, box.size.z)
	ground.mesh = plane
	ground.position = floor_body.position + Vector3(0, 0.01, 0)
	_stage.add_child(ground)


func _add_soldier(row: Dictionary, column: int, index: int) -> Infantry:
	var s := Infantry.new()
	s.armor_id = str(row.armor.id)
	s.body_shape = "" if str(row.body.id) == str(row.armor.get("shape", "")) else str(row.body.id)
	s.net_id = index + 1
	_stage.add_child(s)
	s.global_position = Vector3(index * SPACING, 0.2, 0.0)
	s.equip(_make_loadout(row.armor, str(row.body.id)))
	s.apply_weapon_slot(mini(column, s.weapons.size() - 1))
	s.pitch_target = _pitch
	s.pitch = _pitch
	return s


## Up to WEAPON_COLUMNS weapons the armour may carry, the preferred ones first; an Aerial Assault / Vengeance body holds the
## `_group`th three weapons of its own game.
func _make_loadout(armor: Dictionary, body_id: String) -> Array:
	var rules := InfantryCatalog.make_pack_rules(body_id.get_slice(":", 0), str(armor.get("size", "light")).to_upper())
	if not rules.is_empty():
		return (rules.weapons as Array).slice(_group * WEAPON_COLUMNS, (_group + 1) * WEAPON_COLUMNS)
	var allowed: Array = armor.get("weapons", [])
	var out := []
	for want in PREFERRED_WEAPONS:
		for id in allowed:
			if str(id).ends_with(":" + want) and out.size() < WEAPON_COLUMNS and not out.has(id):
				out.append(id)
	for id in allowed:
		if out.size() < WEAPON_COLUMNS and not out.has(id):
			out.append(id)
	return out


func _shoot_grid(soldiers: Array, rows: int, first_person: bool, path: String) -> void:
	var views := []
	for s in soldiers:
		views.append(_add_view(s, first_person))
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var sheet := Image.create(CELL.x * WEAPON_COLUMNS, CELL.y * rows, false, Image.FORMAT_RGB8)
	for i in views.size():
		var img: Image = views[i].get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, CELL), Vector2i((i % WEAPON_COLUMNS) * CELL.x, (i / WEAPON_COLUMNS) * CELL.y))
	sheet.save_png(path)
	print("  shot ", path)
	for v in views:
		v.queue_free()
	for s in soldiers:
		s.held.apply_view_shown(false)
		s.shape.visible = true
		s.held.apply_world_shown(true)


func _add_view(s: Infantry, first_person: bool) -> SubViewport:
	var view := SubViewport.new()
	view.size = CELL
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.own_world_3d = false
	add_child(view)
	var cam := Camera3D.new()
	view.add_child(cam)
	if first_person:
		cam.fov = FIRST_PERSON_FOV
		cam.near = 0.05
		s.shape.visible = false
		s.held.apply_world_shown(false)
		s.held.apply_view_shown(true)
		cam.global_transform = s.eye.global_transform
	else:
		cam.global_transform = Transform3D(Basis(), s.global_position + THIRD_PERSON_CAMERA).looking_at(s.global_position + THIRD_PERSON_TARGET, Vector3.UP)
	return view

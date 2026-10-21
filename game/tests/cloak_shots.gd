extends Node
## Windowed render of the shared cloak, for the eye: a Tribes 2 light-armour soldier with the cloaking pack and a
## Starsiege Herc with a Chameleon cloak, plain and cloaked, on a Tribes 2 map. Needs a renderer:
##   godot --audio-driver Dummy --path game res://tests/cloak_shots.tscn -- --out=<dir>
## Writes cloak_soldier_plain.png, cloak_soldier_cloaked.png, cloak_herc_plain.png, cloak_herc_cloaked.png and
## cloak_soldier_close.png (inside the 8 m reveal range: plain again).

const MAP := "tribes2:Katabatic"
const SOLDIER_DISTANCE := 11.0
const SOLDIER_CLOSE_DISTANCE := 5.0
const HERC_DISTANCE := 38.0
const HERC_VEHICLE := "starsiege:rb_eman"
const SETTLE_FRAMES := 20
const ZOOM_FOV := 28.0
const BACKGROUND_ANGLES := 8
const CROP_W := 200
const CROP_H := 300
const FADE_STEPS := 6
const FADE_SECONDS := 2.0
const FLASH_FRAMES := 9
const FLASH_STEP_S := 0.12
const SITE_RINGS := [0, 1, 2, 3, 4, 5, 6]
const SITE_DIRECTIONS := 8
const SITE_RING_STEP_M := 25.0
const SITE_CLEAR_M := 60.0
const SITE_LEVEL_M := 1.5
const CAMERA_HEIGHT := 1.7
const LOOK_HEIGHT := 1.1
const HERC_LOOK_HEIGHT := 6.0

var _out := "user://cloak"
var _failures := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	await get_tree().process_frame
	var battle := await _start_battle()
	var cam := Camera3D.new()
	battle.add_child(cam)
	cam.current = true
	battle.set_process(false)
	if battle.overlay != null:
		battle.overlay.visible = false
	var site := _find_site(battle)
	await _film_soldier(battle, cam, site)
	await _film_backgrounds(battle, cam, site)
	await _film_fade(battle, cam, site)
	await _film_herc(battle, cam, site + Vector3(0, 0, -100))
	await _film_station_flash(battle, cam, site + Vector3(30, 0, 0))
	print("cloak_shots: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _start_battle() -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 500, "ai": [], InfantryBots.CONFIG_KEY: 0}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _find_site(battle: Battle) -> Vector3:
	var origin := (battle.player as Infantry).global_position + Vector3(0, 0, 300)
	for ring in SITE_RINGS:
		for k in SITE_DIRECTIONS:
			var a := TAU * float(k) / SITE_DIRECTIONS
			var p: Vector3 = origin + Vector3(cos(a), 0, sin(a)) * ring * SITE_RING_STEP_M
			if not battle.bounds.bounds.is_outside(p) and _is_level(battle, p):
				p.y = MapBuilder.ground_height(battle, p)
				return p
	origin.y = MapBuilder.ground_height(battle, origin)
	return origin


func _is_level(battle: Battle, p: Vector3) -> bool:
	var h0 := MapBuilder.ground_height(battle, p)
	for step in range(-int(SITE_CLEAR_M), int(SITE_CLEAR_M) + 1, 10):
		if absf(MapBuilder.ground_height(battle, p + Vector3(0, 0, step)) - h0) > SITE_LEVEL_M:
			return false
	return true


func _shot(name: String) -> void:
	await _frames(3)
	_hide_layers(get_tree().root)
	await RenderingServer.frame_post_draw
	var path := "%s/%s.png" % [_out, name]
	get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


func _aim(cam: Camera3D, target: Vector3, distance: float, look_height: float) -> void:
	cam.global_position = target + Vector3(0, CAMERA_HEIGHT, distance)
	cam.look_at(target + Vector3(0, look_height, 0))


func _film_soldier(battle: Battle, cam: Camera3D, site: Vector3) -> void:
	var s := battle.spawn_soldier_for(90, 2, "Scout", Transform3D(Basis(), site + Vector3(0, 0.3, 0)))
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "tribes2:CLOAKING_PACK")
	s.end_spawn_protection()
	(battle.player as Node3D).global_position = site + Vector3(0, 0, 40)
	await _frames(30)
	_aim(cam, s.global_position, SOLDIER_DISTANCE, LOOK_HEIGHT)
	await _shot("cloak_soldier_plain")
	s.cloak.apply_wanted(true, s)
	await get_tree().create_timer(FADE_SECONDS, true, true).timeout
	_expect(s.cloak.is_cloaked() and s.cloak.fade >= 1.0, "the soldier is cloaked")
	_aim(cam, s.global_position, SOLDIER_DISTANCE, LOOK_HEIGHT)
	await _shot("cloak_soldier_cloaked")
	_aim(cam, s.global_position, SOLDIER_CLOSE_DISTANCE, LOOK_HEIGHT)
	await _shot("cloak_soldier_close")


func _film_herc(battle: Battle, cam: Camera3D, site: Vector3) -> void:
	site.y = MapBuilder.ground_height(battle, site)
	var h: Herc = battle.spawn_ai(HERC_VEHICLE, 2, Transform3D(Basis(), site), [], "Cloaker", {"skill": 0.5, "group": 1, "order": 6, "path": []})
	await _frames(20)
	for c in h.get_children():
		if c is AIPilot:
			c.set_physics_process(false)
	_aim(cam, h.global_position, HERC_DISTANCE, HERC_LOOK_HEIGHT)
	await _shot("cloak_herc_plain")
	h.cloak_input = true
	await get_tree().create_timer(FADE_SECONDS, true, true).timeout
	_expect(h.cloak.is_cloaked(), "the Herc is cloaked")
	_aim(cam, h.global_position, HERC_DISTANCE, HERC_LOOK_HEIGHT)
	await _shot("cloak_herc_cloaked")
	cam.fov = ZOOM_FOV
	await _shot("cloak_herc_cloaked_zoom")
	h.cloak_input = false
	await get_tree().create_timer(FADE_SECONDS, true, true).timeout
	await _shot("cloak_herc_plain_zoom")
	cam.fov = 75.0


## The inventory station's flash (station.cs: setCloaked(true), plain again 500 ms later), as a sheet of crops
## (cloak_station_flash.png): before the purchase, then every 0.1 s while the flash fades in and out.
func _film_station_flash(battle: Battle, cam: Camera3D, site: Vector3) -> void:
	site.y = MapBuilder.ground_height(battle, site)
	var s := battle.spawn_soldier_for(93, 2, "Buyer", Transform3D(Basis(), site + Vector3(0, 0.3, 0)))
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "")
	s.end_spawn_protection()
	await _frames(30)
	cam.fov = ZOOM_FOV
	_aim(cam, s.global_position, SOLDIER_DISTANCE * 1.6, LOOK_HEIGHT)
	var crops: Array[Image] = []
	crops.append(await _grab_crop(cam, s))
	TribesStations.apply_station_flash(s)
	for i in FLASH_FRAMES:
		await get_tree().create_timer(FLASH_STEP_S, true, true).timeout
		crops.append(await _grab_crop(cam, s))
		_expect(true, "flash frame %d: fade %.2f, cloaked %s" % [i, s.cloak.fade, s.cloak.is_cloaked()])
	_save_sheet(crops, "cloak_station_flash", FLASH_FRAMES + 1)
	cam.fov = 75.0


## The soldier cloaked and seen from every side, so the sheet shows him against the ground, the slope, the sky and the
## buildings (cloak_backgrounds.png: crops, one per angle).
func _film_backgrounds(battle: Battle, cam: Camera3D, site: Vector3) -> void:
	var s := battle.spawn_soldier_for(91, 2, "Scout", Transform3D(Basis(), site + Vector3(3, 0.3, 0)))
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "tribes2:CLOAKING_PACK")
	s.end_spawn_protection()
	await _frames(30)
	s.cloak.apply_wanted(true, s)
	await get_tree().create_timer(FADE_SECONDS, true, true).timeout
	cam.fov = ZOOM_FOV
	var crops: Array[Image] = []
	for k in BACKGROUND_ANGLES:
		var a := TAU * float(k) / BACKGROUND_ANGLES
		cam.global_position = s.global_position + Vector3(sin(a), 0, cos(a)) * (SOLDIER_DISTANCE * 1.6) + Vector3(0, CAMERA_HEIGHT, 0)
		cam.look_at(s.global_position + Vector3(0, LOOK_HEIGHT, 0))
		crops.append(await _grab_crop(cam, s))
	_save_sheet(crops, "cloak_backgrounds", 4)
	s.cloak.apply_wanted(false, s)
	cam.fov = 75.0


## The cloak fading in then out, FADE_STEPS frames each, as crops (cloak_fade.png): the shader's `amount` stepped by hand.
func _film_fade(battle: Battle, cam: Camera3D, site: Vector3) -> void:
	var s := battle.spawn_soldier_for(92, 2, "Scout", Transform3D(Basis(), site + Vector3(-3, 0.3, 0)))
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "tribes2:CLOAKING_PACK")
	s.end_spawn_protection()
	await _frames(30)
	cam.fov = ZOOM_FOV
	_aim(cam, s.global_position, SOLDIER_DISTANCE * 1.6, LOOK_HEIGHT)
	var crops: Array[Image] = []
	s.cloak.apply_wanted(true, s)
	var step_s: float = s.cloak.profile.fade_in_s / FADE_STEPS
	for i in FADE_STEPS + 1:
		crops.append(await _grab_crop(cam, s))
		await get_tree().create_timer(step_s, true, true).timeout
	await _frames(5)
	s.cloak.apply_wanted(false, s)
	for i in FADE_STEPS + 1:
		crops.append(await _grab_crop(cam, s))
		await get_tree().create_timer(step_s, true, true).timeout
	_save_sheet(crops, "cloak_fade", FADE_STEPS + 1)
	cam.fov = 75.0


func _grab_crop(cam: Camera3D, unit: Node3D) -> Image:
	await _frames(2)
	_hide_layers(get_tree().root)
	await RenderingServer.frame_post_draw
	var full := get_viewport().get_texture().get_image()
	var at := cam.unproject_position(unit.global_position + Vector3(0, LOOK_HEIGHT, 0))
	var rect := Rect2i(Vector2i(at) - Vector2i(CROP_W / 2, CROP_H / 2), Vector2i(CROP_W, CROP_H)).intersection(Rect2i(Vector2i.ZERO, full.get_size()))
	var crop := full.get_region(rect)
	crop.convert(Image.FORMAT_RGBA8)
	return crop


func _save_sheet(crops: Array[Image], name: String, columns: int) -> void:
	var rows := ceili(float(crops.size()) / columns)
	var sheet := Image.create(columns * CROP_W, rows * CROP_H, false, Image.FORMAT_RGBA8)
	for i in crops.size():
		sheet.blit_rect(crops[i], Rect2i(Vector2i.ZERO, crops[i].get_size()), Vector2i((i % columns) * CROP_W, (i / columns) * CROP_H))
	sheet.save_png("%s/%s.png" % [_out, name])
	print("  sheet ", name)


func _hide_layers(node: Node) -> void:
	if node is CanvasLayer:
		node.visible = false
	for c in node.get_children():
		_hide_layers(c)

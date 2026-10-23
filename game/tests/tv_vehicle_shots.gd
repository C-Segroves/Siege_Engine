extends "res://tests/tv_vehicles_check.gd"
## Windowed renders of the drivable Tribes: Vengeance vehicles on a Vengeance map, for checking by eye (needs a window and the packs):
##   TV_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/tv_vehicle_shots.tscn
## Per vehicle: tv_<key>_parked.png (front-left quarter, standing on the ground), _top.png, _side.png, then the player boards, drives and fires: a camera
## follows from behind and to the side and writes tv_<key>_drive_<n>.png every SHOT_GAP seconds while both fire groups are held.

const SHOT_GAP := 1.0
const SHOTS := 3
## Parked views (x right, y up, z back; the nose is -Z): front-left, from above, from the right side.
const PARKED_VIEWS := {"parked": Vector3(-0.9, 0.45, -1.0), "top": Vector3(0.0, 1.0, 0.18), "side": Vector3(1.0, 0.25, 0.0)}
const FOLLOW := Vector3(0.45, 0.28, 1.0)             # behind and to the right
const VIEW_SCALE := 2.6                              # camera distance in vehicle lengths
const MIN_VIEW_M := 9.0
var _cam: Camera3D


func _run() -> void:
	_shot_dir = OS.get_environment("TV_SHOT_DIR")
	if not Assets.has_pack(PACK) or _shot_dir == "":
		print("tv_vehicle_shots: needs the packs and TV_SHOT_DIR")
		get_tree().quit(1)
		return
	await _start_mission(STAGE_MAP)
	_battle.set_process(false)
	_battle.overlay.visible = false
	for c in _battle.chat.find_children("*", "CanvasItem", true, false):
		(c as CanvasItem).visible = false
	_cam = _battle.cameras.chase_cam           # the battle's own camera: it carries the map's render layers
	_cam.fov = 50.0
	_cam.current = true
	var site := _find_site()
	for key in IDS:
		await _film(key, site)
	_battle.queue_free()
	get_tree().quit(0)


func _film(key: String, at: Vector3) -> void:
	var v := _spawn(key, at, true)
	for _f in 40:
		await get_tree().physics_frame
	for view in PARKED_VIEWS:
		_aim_camera(v, PARKED_VIEWS[view])
		await _save("tv_%s_%s.png" % [key.to_lower(), view])
	var soldier := _soldier()
	soldier.global_position = v.global_position + Vector3(BoardingRules.make_hull_radius(v) + 0.2, 0.3, 0.0)
	soldier.velocity = Vector3.ZERO
	for _f in 30:
		await get_tree().physics_frame
	var enemy := _spawn(DUMMY, v.global_position + Vector3(0, 0, -TARGET_DISTANCE), false)
	await get_tree().physics_frame
	enemy.set_physics_process(false)
	SiegeInput.last_device = SiegeInput.Device.GAMEPAD
	Input.action_press("throttle_up")
	if v is Flyer:
		Input.action_press("ascend")
	for a in ["fire_group_1", "fire_group_2"]:
		Input.action_press(a)
	for n in SHOTS:
		for _f in int(SHOT_GAP * 60.0):
			await get_tree().physics_frame
			_aim_camera(v, FOLLOW)
		await _save("tv_%s_drive_%d.png" % [key.to_lower(), n])
	_release_controls()
	_battle.remove_vehicle(enemy.net_id)
	v.apply_environment_damage(1.0)
	await get_tree().physics_frame
	_battle.remove_vehicle(v.net_id)


func _aim_camera(v: Herc, side: Vector3) -> void:
	var size := maxf(v.def.length_m, MIN_VIEW_M / VIEW_SCALE) * VIEW_SCALE
	_cam.global_position = v.global_position + v.global_basis * (side.normalized() * size) + Vector3.UP * 1.0
	_cam.look_at(v.global_position + Vector3.UP * float(v.def.height_m) * 0.4, Vector3.UP)
	_cam.make_current()                                  # boarding makes the cockpit camera current


func _save(file: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir.path_join(file))
	print("saved ", file)

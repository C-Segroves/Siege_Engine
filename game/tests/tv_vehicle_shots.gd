extends "res://tests/tv_vehicles_check.gd"
## Windowed renders of the drivable Tribes: Vengeance vehicles on a Vengeance map, for checking by eye (needs a window and the packs):
##   TV_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/tv_vehicle_shots.tscn
## Per vehicle: tv_<key>_parked.png (front-left quarter, standing on the ground), _top.png, _side.png, tv_<key>_riders_<view>.png (every seat taken,
## close up and from the side), then the player boards, drives and fires: a camera follows from behind and to the side and writes
## tv_<key>_drive_<n>.png every SHOT_GAP seconds while both fire groups are held (the wheels turn, the ship's gear is in, its wings out).

const SHOT_GAP := 1.0
const SHOTS := 3
## Parked views (x right, y up, z back; the nose is -Z): front-left, from above, from the right side.
const PARKED_VIEWS := {"parked": Vector3(-0.9, 0.45, -1.0), "top": Vector3(0.0, 1.0, 0.18), "side": Vector3(1.0, 0.25, 0.0)}
const FOLLOW := Vector3(0.45, 0.28, 1.0)             # behind and to the right
const RIDER_VIEWS := {"close": Vector3(-0.7, 0.5, -0.6), "side": Vector3(1.0, 0.35, -0.2)}
const RIDER_CLOSE_SCALE := 0.55                      # the close view comes this much nearer
const FIRST_SHOT_PEER := 3001
const PAD_SHAPES := {"POD": "tv_prop_vehiclespawnpod", "TANK": "tv_prop_vehiclespawntank", "ASSAULT_SHIP": "tv_prop_vehiclespawnassaultship",
	"BUGGY": "tv_prop_vehiclespawnbuggy"}
const PAD_VIEW_SCALE := 1.4
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
	for key in IDS:
		await _film_pad(key, site)
	_battle.queue_free()
	get_tree().quit(0)


func _film(key: String, at: Vector3) -> void:
	var v := _spawn(key, at, true)
	for _f in 40:
		await get_tree().physics_frame
	for view in PARKED_VIEWS:
		_aim_camera(v, PARKED_VIEWS[view])
		await _save("tv_%s_%s.png" % [key.to_lower(), view])
	await _film_riders(key, v)
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


## A vehicle pad (its shape and the vehicle it holds), from the front-left quarter.
func _film_pad(key: String, at: Vector3) -> void:
	var id := "%s:%s" % [PACK, key]
	var pad_shape := ShapeInstance.new()
	_battle.add_child(pad_shape)
	pad_shape.build(Assets.shape("%s:%s" % [PACK, PAD_SHAPES[key]]), 0, Packs.default_palette(PACK))
	pad_shape.global_position = at
	var pad := {"vehicle": id, "actor": "", "label": "ShotPad", "pos": [at.x, at.y, at.z], "basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
		"yaw": 0.0, "team_name": "", "spawn_s": 90.0, "offset_m": PAD_LIFT_M}
	var fleet := TVVehicleFleet.new(_battle.mission)
	fleet.build([], [pad])
	fleet.sync(at)
	var v: Herc = (fleet.entries[0] as Dictionary).vehicle
	for _f in 40:
		await get_tree().physics_frame
	_aim_camera(v, PARKED_VIEWS.parked, PAD_VIEW_SCALE)
	await _save("tv_%s_pad.png" % key.to_lower())
	_battle.remove_vehicle(v.net_id)
	pad_shape.queue_free()


## Every seat taken by a soldier in a Vengeance body, photographed close and from the side.
func _film_riders(key: String, v: Herc) -> void:
	var riders: Array[Infantry] = []
	for seat in BoardingRules.make_seat_count(v.def):
		riders.append(_board(v, seat, FIRST_SHOT_PEER + seat))
	for _f in 20:
		await get_tree().process_frame
		await get_tree().physics_frame
	for view in RIDER_VIEWS:
		_aim_camera(v, RIDER_VIEWS[view], RIDER_CLOSE_SCALE if view == "close" else 1.0)
		await _save("tv_%s_riders_%s.png" % [key.to_lower(), view])
	for r in riders:
		_battle.remove_vehicle(r.net_id)


func _aim_camera(v: Herc, side: Vector3, closeness := 1.0) -> void:
	var size := maxf(v.def.length_m, MIN_VIEW_M / VIEW_SCALE) * VIEW_SCALE * closeness
	_cam.global_position = v.global_position + v.global_basis * (side.normalized() * size) + Vector3.UP * 1.0
	_cam.look_at(v.global_position + Vector3.UP * float(v.def.height_m) * 0.4, Vector3.UP)
	_cam.make_current()                                  # boarding makes the cockpit camera current


func _save(file: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_dir.path_join(file))
	print("saved ", file)

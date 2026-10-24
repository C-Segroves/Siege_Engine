extends "res://tests/tv_vehicle_shots.gd"
## Windowed renders of the Vengeance mission AI and moving parts, for checking by eye (needs a window and the packs):
##   TV_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/tv_ai_shots.tscn
## tv_tank_turret_<n>.png   the tank's turret mesh as the gun aims straight, left, right and nearly behind (seen from above and the side);
## tv_rover_suspension_<view>.png   the Rover on flat ground, with a wheel over a block, and in the air (the wheels and shocks follow);
## tv_board_<n>.png   three soldiers walk to a parked Assault Ship on their EnterVehicle goals and climb in (pilot, two gunners), the ship
##                    then flies to a node on the VehicleMoveTo goal the script gives it, its gunners drawn on their seats.

const TURRET_AIMS := [0.0, 1.2, -1.2, 2.8]
const TURRET_VIEWS := {"above": Vector3(0.35, 1.0, 0.7), "side": Vector3(1.0, 0.3, 0.2)}
const SUSPENSION_VIEWS := {"front": Vector3(-0.9, 0.2, -1.0), "side": Vector3(1.0, 0.1, 0.0)}
const SUSPENSION_VIEW_SCALE := 0.8
const BOARD_SHOT_GAP_S := 0.5              # the soldiers walk up in the first seconds: closely spaced shots, then wider ones
const BOARD_LATE_GAP_S := 1.5
const BOARD_FAST_SHOTS := 12
const BOARD_SHOTS := 18
const BOARD_CAMERA_M := 40.0
const BOARD_SOLDIERS := [["shot_pilot", "tv_phoenixlight", 0], ["shot_gunner_a", "tv_phoenixmedium", 1], ["shot_gunner_b", "tv_phoenixmedium", 2]]
const BOARD_RING_M := 30.0


func _run() -> void:
	_shot_dir = OS.get_environment("TV_SHOT_DIR")
	if not Assets.has_pack(PACK) or _shot_dir == "":
		print("tv_ai_shots: needs the packs and TV_SHOT_DIR")
		get_tree().quit(1)
		return
	await _start_mission(STAGE_MAP)
	_battle.set_process(false)
	_battle.overlay.visible = false
	for c in _battle.chat.find_children("*", "CanvasItem", true, false):
		(c as CanvasItem).visible = false
	_cam = _battle.cameras.chase_cam
	_cam.fov = 50.0
	_cam.current = true
	var site := _find_site()
	var rt := _battle.mission as TVMissionRuntime
	_soldier().spawn_protection = 600.0
	_soldier().apply_spawn_protection()
	await _film_turret(site)
	await _film_suspension(site)
	await _film_boarding(rt, site)
	_battle.queue_free()
	get_tree().quit(0)


func _film_turret(at: Vector3) -> void:
	var v := _spawn("TANK", at, true)
	for _f in 40:
		await get_tree().physics_frame
	for i in TURRET_AIMS.size():
		v.torso_target = TURRET_AIMS[i]
		await _wait(2.0)
		for view in TURRET_VIEWS:
			_aim_camera(v, TURRET_VIEWS[view], 0.8)
			await _save("tv_tank_turret_%d_%s.png" % [i, view])
	_battle.remove_vehicle(v.net_id)


func _film_suspension(at: Vector3) -> void:
	var v := _spawn("BUGGY", at, true)
	for _f in 40:
		await get_tree().physics_frame
	v.set_physics_process(false)
	var wheel: int = (v.parts.suspension_wheels[0] as Dictionary).wheel
	await _shoot_rover(v, "flat")
	var bump := _make_bump(v.shape.nodes[wheel].global_position)
	await _shoot_rover(v, "bump")
	bump.queue_free()
	v.global_position.y += AIRBORNE_LIFT_M
	await _shoot_rover(v, "air")
	_battle.remove_vehicle(v.net_id)


func _shoot_rover(v: Herc, tag: String) -> void:
	for _f in SUSPENSION_FRAMES:
		await get_tree().physics_frame
		v.parts.update(get_physics_process_delta_time())
	for view in SUSPENSION_VIEWS:
		_aim_camera(v, SUSPENSION_VIEWS[view], SUSPENSION_VIEW_SCALE)
		await _save("tv_rover_suspension_%s_%s.png" % [tag, view])


## Three soldiers on their EnterVehicle goals walk to the parked Assault Ship, take the pilot's and the two gunner seats, and the ship flies off.
func _film_boarding(rt: TVMissionRuntime, at: Vector3) -> void:
	rt.script_data["actors"] = rt.script_data.get("actors", {})
	var rec := _goal_rec("ASSAULT_SHIP", "shot_ship", at)
	rec["team_name"] = rt.player_team
	var e := rt.fleet.add_entry(rec)
	rt.fleet.sync(at)
	var ship := e.vehicle as Herc
	for _f in 40:
		await get_tree().physics_frame
	for i in BOARD_SOLDIERS.size():
		var a := TAU * float(i) / BOARD_SOLDIERS.size() + 0.6
		var p := at + Vector3(cos(a), 0.0, sin(a)) * BOARD_RING_M
		rt.apply_spawn_npc({"class": "AIGrunt1Phoenix", "label": BOARD_SOLDIERS[i][0], "team": rt.player_team, "body": BOARD_SOLDIERS[i][1], "health": 1.0},
			[p.x, p.y, p.z])
		rt.apply_goal(BOARD_SOLDIERS[i][0], "add", "Enter", {"kind": "enter_vehicle", "name": "Enter", "priority": 75, "vehicle": "shot_ship",
			"seat": BOARD_SOLDIERS[i][2]})
	var far := at + Vector3(120.0, 0.0, -160.0)
	rt.script_data.actors["shotFar"] = [far.x, far.y, far.z]
	var sent := false
	for n in BOARD_SHOTS:
		for _f in int((BOARD_SHOT_GAP_S if n < BOARD_FAST_SHOTS else BOARD_LATE_GAP_S) * 60.0):
			await get_tree().physics_frame
			rt._steer_npcs()
			rt.fleet.sync(at)
			_aim_board_camera(ship)
		if not sent and VehicleOccupancy.of(ship).seats.all(func(s: int) -> bool: return s != VehicleOccupancy.EMPTY):
			sent = true
			rt.fleet.apply_goal("shot_ship", "add", "go", {"kind": "vehicle_move", "name": "go", "priority": 60, "dest": "shotFar"})
		await _save("tv_board_%02d.png" % n)
	rt.fleet.entries.clear()


func _aim_board_camera(ship: Herc) -> void:
	_cam.global_position = ship.global_position + Vector3(BOARD_CAMERA_M, 7.0, BOARD_CAMERA_M * 0.5)
	_cam.look_at(ship.global_position + Vector3.UP * 2.0, Vector3.UP)
	_cam.make_current()

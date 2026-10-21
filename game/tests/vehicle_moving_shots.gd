extends "res://tests/flight_pilot_shots.gd"
## Windowed side views of vehicles in motion, from a camera that stays put, so a nose-first vehicle crosses the picture from left
## to right (the noses point to the right, -Z): a strip of frames MOVE_FRAMES apart per vehicle (needs a window and the packs).
##   MOVE_SHOT_DIR=<folder> MOVE_IDS=tribes_aa:AA_SCOUT,tribes_aa:AA_GRAV_SCOUT godot --audio-driver Dummy --path game res://tests/vehicle_moving_shots.tscn
## Flyers fly their own autopilot straight ahead (FlyerAI); ground and hover vehicles are driven with full throttle. Writes
## move_<name>_<n>.png and prints the way each vehicle went against the way its nose points.
const STRIP_SHOTS := 4
const FLYER_GAP_FRAMES := 5
const GROUND_GAP_FRAMES := 40
const START_HEIGHT_M := 110.0
const CAMERA_SIDE_M := Vector3(55.0, 0.0, 0.0)
const GROUND_CAMERA_SIDE_M := Vector3(22.0, 3.0, 0.0)
const LOOK_AHEAD_M := 18.0
const RUN_LENGTH_M := 3000.0

var _vehicle: Herc
var _view_xf := Transform3D.IDENTITY


func _run() -> void:
	var dir := OS.get_environment("MOVE_SHOT_DIR")
	var ids := OS.get_environment("MOVE_IDS").split(",", false)
	var battle := await _start_raid(VarunaMap.MAP_ID)
	_cam = Camera3D.new()
	_cam.far = 6000.0
	_cam.fov = 40.0
	battle.add_child(_cam)
	battle.set_process(false)
	if battle.overlay:
		battle.overlay.visible = false
	for id in ids:
		await _film(battle, id, dir)
	_finish()


func _film(battle: Battle, id: String, dir: String) -> void:
	_vehicle = _spawn_moving(battle, id)
	if _vehicle == null:
		print("%s did not spawn" % id)
		return
	var start := _vehicle.global_position
	var forward := -_vehicle.global_basis.z
	_view_xf = Transform3D.IDENTITY
	_cam.global_position = start + forward * LOOK_AHEAD_M + (CAMERA_SIDE_M if _vehicle is Flyer else GROUND_CAMERA_SIDE_M)
	_cam.look_at(start + forward * LOOK_AHEAD_M, Vector3.UP)
	_cam.make_current()
	for n in STRIP_SHOTS:
		for _f in (FLYER_GAP_FRAMES if _vehicle is Flyer else GROUND_GAP_FRAMES):
			await get_tree().physics_frame
			_drive()
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/move_%s_%d.png" % [dir, id.split(":")[1], n])
	var way := (_vehicle.global_position - start)
	way.y = 0.0
	print("%s moved %.0f m, %.0f deg off its nose (nose = %s)" % [id, way.length(), rad_to_deg(way.angle_to(Vector3(forward.x, 0.0, forward.z))), forward.snapped(Vector3.ONE * 0.01)])
	battle.remove_vehicle(_vehicle.net_id)


func _drive() -> void:
	if is_instance_valid(_vehicle) and not _vehicle is Flyer:
		_vehicle.throttle = 1.0


func _spawn_moving(battle: Battle, id: String) -> Herc:
	var def := Packs.vehicle(id)
	var centre: Vector3 = battle.extraction.zones[0]
	var ground := MapBuilder.ground_height(battle, centre)
	var flying := String(def.get("kind", "")) == "flyer"
	var start := Vector3(centre.x, ground + (START_HEIGHT_M if flying else 1.0), centre.z)
	var path := PackedVector3Array([start + Vector3(0, 0, -RUN_LENGTH_M)])
	var spec := {"net_id": battle.spawner.allocate_id(), "vehicle": id, "team": battle.occupancy.soldier_of(1).team,
		"owner": 1 if flying else VehicleOccupancy.EMPTY, "xf": Transform3D(Basis(Vector3.UP, 0.0), start), "loadout": [],
		"name": "Mover", "ai": {"skill": 0.5, "flyer": true, "path": path} if flying else {}}
	battle.send_spawn(spec)
	var herc := battle.vehicles.get(int(spec.net_id)) as Herc
	if herc is Flyer:
		herc.set_meta("dormant", true)
		(herc as Flyer).ai = PatrolOnly.new(herc as Flyer)
	return herc

extends Node
## Windowed renders of a map's cubemap sky from several angles (needs a window and the map's pack), for checking seams by eye:
##   SKY_SHOT_DIR=<folder> SKY_MAP=<map id> godot --audio-driver Dummy --path game res://tests/sky_shots.tscn
## sky_<n>.png per heading/pitch in VIEWS.
const SETTLE_FRAMES := 20
const DEFAULT_MAP := "tribes2:varuna"
## [yaw degrees, pitch degrees]: round the horizon, then up, down and the corners where two faces meet.
const VIEWS := [[0, 20], [60, 20], [120, 20], [180, 20], [240, 20], [300, 20], [45, 45], [135, 45], [0, 80], [0, -20], [90, 0], [270, 0]]


func _ready() -> void:
	get_tree().create_timer(300.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("SKY_SHOT_DIR")
	var map_id := OS.get_environment("SKY_MAP") if OS.get_environment("SKY_MAP") != "" else DEFAULT_MAP
	var world := Node3D.new()
	add_child(world)
	MapBuilder.build(world, map_id)
	var cam := Camera3D.new()
	cam.far = 12000.0
	cam.fov = 75.0
	world.add_child(cam)
	cam.current = true
	cam.global_position = Vector3(0, 3000, 0)
	for n in world.find_children("*", "WorldEnvironment", true, false):
		var e: Environment = (n as WorldEnvironment).environment
		if e != null:
			e.fog_enabled = false
	var i := 0
	for v in VIEWS:
		cam.rotation_degrees = Vector3(v[1], v[0], 0)
		await _shot(dir.path_join("sky_%02d.png" % i))
		i += 1
	get_tree().quit()


func _shot(path: String) -> void:
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)

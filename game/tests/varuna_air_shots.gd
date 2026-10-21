extends Node
## Windowed aerial renders of Varuna's Fall for checking by eye (needs a window and the Tribes 2 pack):
##   VARUNA_SHOT_DIR=<folder> VARUNA_TAG=before godot --audio-driver Dummy --path game res://tests/varuna_air_shots.tscn
## air_<tag>_high.png (1.6 km up, oblique), air_<tag>_low.png (700 m up, looking down the plains).
## With VARUNA_PHASES=0.4,0.7,0.9,0.1 (day phases) it renders cycle_<phase>.png from the airfield's ground instead.
const SETTLE_FRAMES := 40


func _ready() -> void:
	get_tree().create_timer(400.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("VARUNA_SHOT_DIR")
	var tag := OS.get_environment("VARUNA_TAG")
	var world := Node3D.new()
	add_child(world)
	var built := MapBuilder.build(world, VarunaMap.MAP_ID)
	var cam := Camera3D.new()
	cam.far = 12000.0
	cam.fov = 70.0
	world.add_child(cam)
	cam.current = true
	var phases := OS.get_environment("VARUNA_PHASES")
	if phases == "":
		cam.global_position = Vector3(0, 1600, 2200)
		cam.look_at(Vector3(0, 0, 0), Vector3.UP)
		await _shot(dir.path_join("air_%s_high.png" % tag))
		cam.global_position = Vector3(200, 700, 1200)
		cam.look_at(Vector3(300, 0, -600), Vector3.UP)
		await _shot(dir.path_join("air_%s_low.png" % tag))
	else:
		var site: Dictionary = built.map.sites[0]
		for s in built.map.sites:
			if str(s.id) == "airfield":
				site = s
		var p := Vector3(site.pos[0], site.pos[1], site.pos[2])
		cam.global_position = p + Vector3(0, 60, float(site.pad_radius) * 1.8)
		cam.look_at(p + Vector3(0, 70, 0), Vector3.UP)
		var cycle := world.find_children("*", "DayCycleLight", true, false)
		for ph in phases.split(","):
			if not cycle.is_empty():
				cycle[0].apply_phase(float(ph))
			await _shot(dir.path_join("cycle_%s.png" % ph))
	get_tree().quit()


func _shot(path: String) -> void:
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)

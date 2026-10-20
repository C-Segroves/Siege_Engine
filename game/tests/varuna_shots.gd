extends Node
## Windowed renders of Varuna's Fall for checking by eye (needs a window and the Tribes 2 pack):
##   VARUNA_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/varuna_shots.tscn
## overview.png (from high up), site_<id>.png (ground level) for the sites named in VARUNA_SITES (comma separated).
const SETTLE_FRAMES := 30
const DEFAULT_SITES := "airfield,prow_fortress"


func _ready() -> void:
	get_tree().create_timer(300.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("VARUNA_SHOT_DIR")
	var world := Node3D.new()
	add_child(world)
	var built := MapBuilder.build(world, VarunaMap.MAP_ID)
	var cam := Camera3D.new()
	cam.far = 12000.0
	cam.fov = 60.0
	world.add_child(cam)
	cam.current = true
	cam.global_position = Vector3(0, 5200, 4300)
	cam.look_at(Vector3(0, 0, 150), Vector3.UP)
	var fogged: Array = []
	for n in world.find_children("*", "WorldEnvironment", true, false):
		var e: Environment = (n as WorldEnvironment).environment
		if e != null:
			fogged.append([e, e.fog_enabled])
			e.fog_enabled = false
	await _shot(dir.path_join("overview.png"))
	for f in fogged:
		f[0].fog_enabled = f[1]
	var wanted := (OS.get_environment("VARUNA_SITES") if OS.get_environment("VARUNA_SITES") != "" else DEFAULT_SITES).split(",")
	for s in built.map.sites:
		if wanted.has(str(s.id)):
			var p := Vector3(s.pos[0], s.pos[1], s.pos[2])
			cam.global_position = p + Vector3(0, float(s.pad_radius) * 0.45 + 8.0, float(s.pad_radius) * 1.5)
			cam.look_at(p + Vector3(0, 14, 0), Vector3.UP)
			await _shot(dir.path_join("site_%s.png" % str(s.id)))
	get_tree().quit()


func _shot(path: String) -> void:
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)

extends Node3D
## Windowed side views of a Starsiege dropship with a Herc slung under it, to check their relative size by eye: the dropship (67 m)
## against an Apocalypse (11 m) and a Raptor (7.4 m), with the old fixed sling (the Herc sinks into the hull) and the sling the
## delivery uses now (CallinVehicleRun.make_sling_m: the Herc hangs clear under the belly).
##   SCALE_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/dropship_scale_shots.tscn
const WATCHDOG_SECONDS := 120.0
const SHIP := "starsiege:tr_drop"
const CARGO := ["starsiege:tr_apoc", "es1:RAPTOR"]
const OLD_SLING_M := 8.0
const GROUND_Y := -20.0
const SIDE_DISTANCE_M := 120.0

var _cam: Camera3D


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("SCALE_SHOT_DIR")
	_build_stage()
	var ship := _build_model(SHIP)
	var belly := CallinVehicleRun.make_model_belly_m(ship, ship.global_position.y)
	print("dropship %s: length %.0f m, belly %.1f m under its origin" % [SHIP, LootContainer._make_world_box(ship).size.z, belly])
	for id in CARGO:
		var cargo := _build_model(Packs.vehicle(id).shape)
		var height := LootContainer._make_world_box(cargo).size.y
		for label in ["old", "new"]:
			var sling := OLD_SLING_M if label == "old" else CallinVehicleRun.make_sling_m(belly, height)
			cargo.position = ship.position + Vector3.DOWN * sling
			var top := cargo.position.y + height
			print("%s with the %s sling %.1f m: top %.1f m, belly %.1f m -> %s" % [id, label, sling, top, ship.position.y + belly,
				"clear" if top < ship.position.y + belly else "INSIDE THE HULL by %.1f m" % (top - ship.position.y - belly)])
			await _shoot(ship, cargo, sling, dir.path_join("scale_%s_%s.png" % [id.split(":")[1], label]))
	get_tree().quit(0)


func _build_stage() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.62, 0.7)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.75, 0.75, 0.75)
	add_child(env)
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-45, -30, 0)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(600, 600)
	ground.mesh = plane
	ground.position.y = GROUND_Y
	add_child(ground)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.far = 2000.0
	_cam.fov = 35.0
	_cam.current = true


func _build_model(shape_id: String) -> ShapeInstance:
	var inst := ShapeInstance.new()
	add_child(inst)
	inst.build(Assets.shape(shape_id), 0, Packs.default_palette(Assets.split_id(shape_id)[0]))
	return inst


func _shoot(ship: Node3D, _cargo: Node3D, sling: float, path: String) -> void:
	var focus := ship.position + Vector3(0, 14.0 - sling * 0.8, -5.0)
	_cam.global_position = focus + Vector3(SIDE_DISTANCE_M, 0, 0)
	_cam.look_at(focus, Vector3.UP)
	for _f in 6:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)

extends Node3D
## Windowed side views of a call-in drop pod (CallinFx) at several heights above the ground, for checking its attitude by eye:
## high up it falls nose down with its fiery streak above it, in the last CallinPodPose.make_flip_height() metres it swings onto
## its tail, and landed it stands upright. "before" is the pod as it was drawn (the shape as modelled, lying along -Z).
##   POD_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/callin_pod_shots.tscn
const WATCHDOG_SECONDS := 120.0
const SHAPES := ["starsiege:hdroppod", "starsiege:cy_pod"]
const HEIGHTS_M := [120.0, 30.0, 14.0, 0.0]
const DROP_SECONDS := 4.4
const VIEW_DISTANCE_M := 22.0

var _cam: Camera3D


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("POD_SHOT_DIR")
	_build_stage()
	for shape in SHAPES:
		CallinRules.pod()["pod_shapes"] = [shape]
		var fx := CallinFx.new()
		add_child(fx)
		fx.set_process(false)
		fx.apply_view({"id": 1, "kind": CallinRules.KIND_ARMOR, "state": int(CallinOrder.State.INBOUND), "lz": Vector3.ZERO,
			"radius": 3.0, "fall_s": DROP_SECONDS, "fall_left": DROP_SECONDS, "peer": 1})
		var m: Dictionary = fx.markers[1]
		for h in HEIGHTS_M:
			m.fall_left = h / float(m.speed)
			fx._process(0.0)
			await _shoot(m, dir.path_join("pod_%s_h%03d.png" % [shape.split(":")[1], int(h)]))
		m.fall_left = 14.0 / float(m.speed)
		fx._process(0.0)
		(m.pod_body as Node3D).basis = Basis.IDENTITY
		await _shoot(m, dir.path_join("pod_%s_before.png" % shape.split(":")[1]))
		fx.queue_free()
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
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	add_child(ground)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.fov = 40.0
	_cam.far = 2000.0
	_cam.current = true


func _shoot(m: Dictionary, path: String) -> void:
	var focus: Vector3 = (m.pod as Node3D).global_position
	_cam.global_position = focus + Vector3(VIEW_DISTANCE_M, 2.0, 0.0)
	_cam.look_at(focus, Vector3.UP)
	for _f in 5:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)

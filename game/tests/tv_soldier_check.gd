extends Node
## Tribes: Vengeance skeletal bodies (tools/tv_skeletal.py): every body in gameplay/bodies.json builds, its sequences play and keep
## the body upright and in one piece; with TV_SHOT_DIR (needs a window) frames of idle / run / jump of TV_SHAPE are written.
##   TV_TEST_ROOT=<data folder with tribes_v/> [TV_SHOT_DIR=<folder> TV_SHAPE=<shape id>] godot --audio-driver Dummy --path game res://tests/tv_soldier_check.tscn
const PACK := "tribes_v"
const WATCHDOG_SECONDS := 180.0
const REQUIRED := ["root", "run"]

var _failures := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _run() -> void:
	var root := OS.get_environment("TV_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	var list = Assets.load_json("gameplay/bodies.json", PACK)
	if not (list is Dictionary):
		print("tv_soldier_check: no bodies imported, skipped")
		get_tree().quit(0)
		return
	var bodies: Array = [] if OS.get_environment("TV_SHOT_ONLY") != "" else list.bodies
	for b in bodies:
		var id := "%s:%s" % [PACK, b.id]
		var js := Assets.shape(id)
		_check(not js.is_empty(), "%s imported" % id)
		if js.is_empty():
			continue
		var inst := ShapeInstance.new()
		add_child(inst)
		inst.build(js, 0, "WORLD0")
		var height := 0.0
		for role in REQUIRED:
			if str(b.package) in ["glorax"] and role != "root":
				continue
			var i := _seq(js, role)
			_check(i >= 0, "%s has %s" % [id, role])
			if i < 0:
				continue
			for k in 5:
				ShapeCycles.pose(inst, i, k / 5.0, false)
				var p := _top(inst)
				_check(p.is_finite() and p.y < 4.0 and p.y > 0.3, "%s %s pose %d one piece (%.2f m)" % [id, role, k, p.y])
		if _seq(js, "root") >= 0:
			ShapeCycles.pose(inst, _seq(js, "root"), 0.0, false)
			height = _top(inst).y
		_check(height > 0.8, "%s stands %.2f m" % [id, height])
		var anim := InfantryAnimation.new(inst)
		if _seq(js, "run") >= 0:
			var travel := ShapeCycles.ground_travel(inst, _seq(js, "run"))
			_check(travel > 0.3 and travel < 8.0, "%s run travels %.2f m per cycle" % [id, travel])
			_check(anim.has_foot_triggers(), "%s run has foot triggers" % id)
		inst.queue_free()
	if OS.get_environment("TV_SHOT_DIR") != "":
		var shape := OS.get_environment("TV_SHAPE") if OS.has_environment("TV_SHAPE") else "tv_phoenixlight"
		await _shots(Assets.shape("%s:%s" % [PACK, shape]), OS.get_environment("TV_SHOT_DIR"))
	print("tv_soldier_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _seq(js: Dictionary, role: String) -> int:
	var seqs: Array = js.ds_sequences
	for i in seqs.size():
		if str(seqs[i].name) == role:
			return i
	return -1


## Height of the highest node origin above the lowest, in metres (the head over the feet).
func _top(inst: ShapeInstance) -> Vector3:
	var hi := -1e9
	var lo := 1e9
	for n in inst.nodes:
		var y: float = (n as Node3D).global_position.y
		hi = maxf(hi, y)
		lo = minf(lo, y)
	return Vector3(0.0, hi - lo, 0.0)


func _shots(js: Dictionary, dir: String) -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.4, 0.5, 0.6)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.7)
	add_child(env)
	var cam := Camera3D.new()
	add_child(cam)
	var dist := float(OS.get_environment("TV_DIST")) if OS.get_environment("TV_DIST") != "" else 1.0
	cam.position = Vector3(3.5, 1.4, -3.5) * dist
	cam.look_at(Vector3(0, 1.0, 0) * dist)
	cam.current = true
	var inst := ShapeInstance.new()
	add_child(inst)
	inst.build(js, 0, "WORLD0")
	DirAccess.make_dir_recursive_absolute(dir)
	inst.position.y = -inst.lowest_point() * inst.scale.y
	for _f in 3:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(dir.path_join("rest.png"))
	for spec in [["root", [0.0, 0.5]], ["run", [0.0, 0.25, 0.5, 0.75]], ["fall", [0.0]]]:
		for ph in spec[1]:
			if _seq(js, spec[0]) < 0:
				continue
			ShapeCycles.pose(inst, _seq(js, spec[0]), ph, false)
			inst.position.y = -inst.lowest_point() * inst.scale.y
			for _f in 3:
				await get_tree().process_frame
			var path := dir.path_join("%s_%02d.png" % [spec[0], int(ph * 100)])
			get_viewport().get_texture().get_image().save_png(path)
	print("shots in ", dir)

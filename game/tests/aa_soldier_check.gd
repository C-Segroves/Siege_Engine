extends Node
## Aerial Assault animated soldiers (tools/aa_soldier.py): the rigged shape builds, its sequences play and keep the body upright
## and in one piece; with AA_SHOT_DIR (needs a window) frames of idle / run / death are written for checking by eye.
##   AA_TEST_ROOT=<data folder with tribes_aa/> [AA_SHOT_DIR=<folder> AA_SHAPE=<shape stem>] godot --audio-driver Dummy --path game res://tests/aa_soldier_check.tscn
const SHAPES := ["tribes_aa:light_male", "tribes_aa:medium_male", "tribes_aa:heavy_male", "tribes_aa:light_female", "tribes_aa:medium_female",
		"tribes_aa:light_bioderm", "tribes_aa:medium_bioderm", "tribes_aa:heavy_bioderm"]
const ROLES := ["root", "run", "back", "side", "jet", "fall", "land", "death1"]
## Additive sequences (aim pitch, head turns, recoil): played over the standing pose.
const ADDITIVE_ROLES := ["recoil", "head", "headside"]
const WATCHDOG_SECONDS := 120.0

var _failures := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		print("FAIL ", what)


func _run() -> void:
	var root := OS.get_environment("AA_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	for id in SHAPES:
		var js := Assets.shape(id)
		_check(not js.is_empty(), "%s imported" % id)
		if js.is_empty():
			continue
		var inst := ShapeInstance.new()
		add_child(inst)
		inst.build(js, 0, "WORLD0")
		var anim := InfantryAnimation.new(inst)
		_check(anim.has_sequences(), "%s has a root sequence" % id)
		_check(anim.has_foot_triggers(), "%s run has foot triggers" % id)
		_check(anim.death_count() >= 8, "%s deaths" % id)
		var height := inst.lowest_point()
		for role in ROLES:
			var i := _seq(js, role)
			_check(i >= 0, "%s has %s" % [id, role])
			if i < 0:
				continue
			for k in 5:
				ShapeCycles.pose(inst, i, k / 5.0, false)
				var p := _top(inst)
				_check(p.is_finite() and p.y < 3.5, "%s %s pose %d finite (%s)" % [id, role, k, p])
		for role in ADDITIVE_ROLES:
			var a := _seq(js, role)
			_check(a >= 0 and bool(js.ds_sequences[a].get("additive", false)), "%s has additive %s" % [id, role])
			if a < 0:
				continue
			for k in 5:
				ShapeCycles.pose(inst, _seq(js, "root"), 0.0, false)
				ShapeCycles.pose(inst, a, k / 4.0, false)
				var q := _top(inst)
				_check(q.is_finite() and q.y > 1.0 and q.y < 3.5, "%s %s pose %d keeps the body together (%s)" % [id, role, k, q])
		ShapeCycles.pose(inst, _seq(js, "root"), 0.0, false)
		var top := _top(inst)
		_check(top.y > (1.3 if "bioderm" in id else 1.5), "%s stands (head %.2f m above the feet)" % [id, top.y])    # bioderms are hunched
		var travel := ShapeCycles.ground_travel(inst, _seq(js, "run"))
		_check(travel > 1.0 and travel < 8.0, "%s run travels %.2f m per cycle" % [id, travel])
		inst.queue_free()
	_check(InfantryCatalog.make_aa_bodies("tribes:MEDIUM").size() == 3, "medium armour offers both AA bodies and the bioderm")
	_check(InfantryCatalog.make_aa_bodies("tribes:HEAVY").size() == 2, "heavy armour offers the male and the bioderm")
	_check(InfantryCatalog.make_aa_bodies("tribes:HEAVY").any(func(b: Dictionary) -> bool: return bool(b.bioderm)), "the bioderm body is flagged")
	if OS.get_environment("AA_SHOT_DIR") != "":
		await _shots(Assets.shape("tribes_aa:" + (OS.get_environment("AA_SHAPE") if OS.has_environment("AA_SHAPE") else "medium_male")), OS.get_environment("AA_SHOT_DIR"))
	print("aa_soldier_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
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
	cam.position = Vector3(3.5, 1.4, -3.5)
	cam.look_at(Vector3(0, 1.0, 0))
	cam.current = true
	var inst := ShapeInstance.new()
	add_child(inst)
	inst.build(js, 0, "WORLD0")
	for spec in [["root", [0.0, 0.5]], ["run", [0.0, 0.25, 0.5, 0.75]], ["death1", [0.0, 0.3, 0.6, 1.0]]]:
		for ph in spec[1]:
			ShapeCycles.pose(inst, _seq(js, spec[0]), ph, false)
			inst.position.y = -inst.lowest_point() * inst.scale.y
			for _f in 3:
				await get_tree().process_frame
			var path := dir.path_join("%s_%02d.png" % [spec[0], int(ph * 100)])
			get_viewport().get_texture().get_image().save_png(path)
	print("shots in ", dir)

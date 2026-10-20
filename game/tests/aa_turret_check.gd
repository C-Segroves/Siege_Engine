extends Node3D
## Aerial Assault turrets (tools/aa_turret.py): the base and barrel shapes carry the node tree and the Turn / Elevate / Activate
## sequences the Tribes turret rig drives; the barrel mounted on the base's Mount0 follows a commanded heading and
## elevation, and folds and deploys. With AA_SHOT_DIR (needs a window) pictures of the turret at rest, deployed and aimed
## are written for checking by eye.
##   AA_TEST_ROOT=<data folder with tribes_aa/> [AA_SHOT_DIR=<folder>] godot --audio-driver Dummy --path game res://tests/aa_turret_check.tscn
const PACK := "tribes_aa"
const BASE := "tribes_aa:turret_base_large"
const BARRELS := ["turret_aa_large", "turret_fusion_large", "turret_missile_large", "turret_mortar_large", "turret_elf_large"]
const MOUNT := "Mount0"
const WATCHDOG_SECONDS := 90.0
const ANGLE_TOLERANCE := 0.12

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
	if not Assets.has_pack(PACK):
		print("aa_turret_check: Aerial Assault is not imported, skipped")
		get_tree().quit(0)
		return
	var shot := OS.get_environment("AA_SHOT_DIR")
	var x := 0.0
	for barrel_name in BARRELS:
		var barrel_id := "%s:%s" % [PACK, barrel_name]
		var base := ShapeInstance.new()
		add_child(base)
		base.build(Assets.shape(BASE), 0, "WORLD0")
		var rig := TribesTurretRig.make(base, barrel_id, MOUNT, "WORLD0")
		_check(rig.can_aim(), "%s: the base turns" % barrel_name)
		_check(rig.barrel != null, "%s: the barrel is mounted on %s" % [barrel_name, MOUNT])
		if rig.barrel == null or not rig.can_aim():
			continue
		for yaw in [0.0, PI / 2.0, -PI / 2.0, PI * 0.9]:
			for pitch in [0.0, 0.5]:
				rig.apply(yaw, pitch, 1.0, 0.05)
				var f: Vector3 = (base.global_transform.affine_inverse() * rig.barrel.global_transform).basis * Vector3(0, 0, -1)
				var got_yaw := atan2(-f.x, -f.z)
				var got_pitch := asin(clampf(f.normalized().y, -1.0, 1.0))
				_check(absf(wrapf(got_yaw - yaw, -PI, PI)) < ANGLE_TOLERANCE,
					"%s: heading %.2f commanded, barrel points %.2f" % [barrel_name, yaw, got_yaw])
				_check(absf(got_pitch - pitch) < ANGLE_TOLERANCE,
					"%s: elevation %.2f commanded, barrel points %.2f" % [barrel_name, pitch, got_pitch])
		base.position = Vector3(x, 0, 0)
		rig.apply(0.0, 0.0, 0.0, 0.05)
		x += 6.0
	if shot != "" and _failures == 0:
		await _shots(shot)
	print("aa_turret_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures else 0)


func _shots(dir: String) -> void:
	for c in get_children():
		c.queue_free()
	await get_tree().process_frame
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.62, 0.7)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.7)
	add_child(env)
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-45, -30, 0)
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var rigs := []
	for i in 3:
		var base := ShapeInstance.new()
		add_child(base)
		base.build(Assets.shape(BASE), 0, "WORLD0")
		base.position = Vector3(i * 6.0, 0, 0)
		rigs.append(TribesTurretRig.make(base, "%s:turret_aa_large" % PACK, MOUNT, "WORLD0"))
	rigs[0].apply(0.0, 0.0, 0.0, 0.05)                 # folded
	rigs[1].apply(0.0, 0.0, 1.0, 0.05)                 # deployed, looking ahead
	rigs[2].apply(PI * 0.6, 0.45, 1.0, 0.05)           # deployed, aimed
	cam.global_position = Vector3(6.0, 5.0, 11.0)
	cam.look_at(Vector3(6.0, 1.5, 0.0), Vector3.UP)
	for _f in 12:
		await get_tree().process_frame
	var path := dir.path_join("aa_turrets.png")
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)

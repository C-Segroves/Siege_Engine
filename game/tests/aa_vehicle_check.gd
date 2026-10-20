extends Node3D
## Aerial Assault vehicles (tools/aa_vehicles.py): the catalog lists the scout, bomb scout and grav scout with their shapes,
## each shape builds with geometry whose nose is at the engine's forward (-Z), and with AA_SHOT_DIR (needs a window) a picture
## of the three from the side, noses to the right is written for checking by eye.
##   AA_TEST_ROOT=<data folder with tribes_aa/> [AA_SHOT_DIR=<folder>] godot --audio-driver Dummy --path game res://tests/aa_vehicle_check.tscn
const PACK := "tribes_aa"
const IDS := ["AA_SCOUT", "AA_BOMBSCOUT", "AA_GRAV_SCOUT", "AA_TRANSPORT"]
const WATCHDOG_SECONDS := 60.0

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
		print("aa_vehicle_check: Aerial Assault is not imported, skipped")
		get_tree().quit(0)
		return
	var x := 0.0
	for key in IDS:
		var id := "%s:%s" % [PACK, key]
		var v: Dictionary = Packs.vehicles.get(id, {})
		_check(not v.is_empty(), "%s is in the catalog" % id)
		if v.is_empty():
			continue
		var js := Assets.shape(String(v.shape))
		_check(not js.is_empty(), "%s shape %s imported" % [id, v.shape])
		if js.is_empty():
			continue
		var inst := ShapeInstance.new()
		add_child(inst)
		inst.build(js, 0, "WORLD0")
		var box := _bounds(inst)
		_check(box.size.length() > 1.0, "%s has geometry (%s)" % [id, box.size])
		_check(box.size.z >= box.size.x * 0.99, "%s is longer than wide, so it faces -Z (%s)" % [id, box.size])
		print("%s: %s m, %s" % [id, box.size, "armed" if bool(v.pilotable) else "unarmed (AI only)"])
		inst.position = Vector3(0, -box.position.y, x)
		x -= box.size.z + 3.0
	if OS.get_environment("AA_SHOT_DIR") != "" and _failures == 0:
		await _shot(x)
	print("aa_vehicle_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures else 0)


func _bounds(n: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for m in n.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = m
		if mi.mesh == null:
			continue
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out


func _shot(width: float) -> void:
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
	cam.fov = 30.0                     # from the side (+X): the noses (-Z) point to the right of the picture
	cam.global_position = Vector3(80.0, 6.0, width * 0.5)
	cam.look_at(Vector3(0.0, 1.0, width * 0.5), Vector3.UP)
	for _f in 12:
		await get_tree().process_frame
	var path := OS.get_environment("AA_SHOT_DIR").path_join("aa_vehicles.png")
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)

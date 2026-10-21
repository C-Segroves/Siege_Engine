extends Node3D
## Windowed side and top renders of vehicle shapes with a red arrow along the engine's forward (-Z), for checking by eye
## which end is the nose. Writes one PNG per shape and a contact sheet source list.
##   FACING_DIR=<folder> [FACING_IDS=a,b,c] godot --audio-driver Dummy --path game res://tests/vehicle_facing_shots.tscn
const WATCHDOG_SECONDS := 240.0
const DEFAULT_IDS := ["tribes_aa:scout", "tribes_aa:bombscout", "tribes_aa:grav_scout", "tribes_aa:turrettrans_vehicle",
	"tribes_v:tv_prop_pod", "tribes_v:tv_prop_tank", "tribes_v:tv_prop_assaultship", "tribes_v:tv_prop_buggy",
	"starsiege:tr_drop", "starsiege:kn_drop", "starsiege:cy_drop", "starsiege:tr_carg",
	"starsiege:hdroppod", "starsiege:cdroppod", "starsiege:cy_pod", "starsiege:tr_apoc"]


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("FACING_DIR")
	var ids: Array = DEFAULT_IDS
	if OS.get_environment("FACING_IDS") != "":
		ids = Array(OS.get_environment("FACING_IDS").split(","))
	_build_stage()
	for id in ids:
		await _shoot(String(id), dir)
	get_tree().quit(0)


var _cam: Camera3D
var _model: Node3D


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
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true
	_cam.fov = 30.0


func _shoot(id: String, dir: String) -> void:
	var js := Assets.shape(id)
	if js.is_empty():
		print("missing ", id)
		return
	if _model:
		_model.queue_free()
	_model = Node3D.new()
	add_child(_model)
	var inst := ShapeInstance.new()
	_model.add_child(inst)
	inst.build(js, 0, Packs.default_palette(Assets.split_id(id)[0]))
	var box := _bounds(inst)
	var size := maxf(box.size.length(), 1.0)
	var arrow := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = size * 0.03
	cone.height = size * 0.6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0, 0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cone.material = mat
	arrow.mesh = cone
	arrow.rotation_degrees = Vector3(-90, 0, 0)      # the cone tip (+Y) turns to -Z
	arrow.position = Vector3(box.get_center().x, box.end.y + size * 0.05, box.position.z - size * 0.3)
	_model.add_child(arrow)
	var centre := box.get_center()
	for view in ["side", "top", "iso", "iso_back"]:
		if view == "side":
			_cam.global_position = centre + Vector3(size * 2.4, size * 0.15, 0)
			_cam.look_at(centre, Vector3.UP)
		elif view == "iso":
			_cam.global_position = centre + Vector3(size * 1.2, size * 0.8, -size * 1.2)
			_cam.look_at(centre, Vector3.UP)
		elif view == "iso_back":
			_cam.global_position = centre + Vector3(-size * 1.2, size * 0.8, size * 1.2)
			_cam.look_at(centre, Vector3.UP)
		else:
			_cam.global_position = centre + Vector3(0, size * 2.4, 0.01)
			_cam.look_at(centre, Vector3(0, 0, -1))
		for _f in 6:
			await get_tree().process_frame
		var path := dir.path_join("%s_%s.png" % [id.replace(":", "_"), view])
		get_viewport().get_texture().get_image().save_png(path)
	print("%s size %s" % [id, box.size])


func _bounds(n: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for m in n.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = m
		if mi.mesh == null or not mi.visible:
			continue
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out

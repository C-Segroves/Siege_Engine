extends Node3D
## Frame strips of the walk cycle (side view) for checking leg animation by eye: per vehicle one row of
## FRAMES frames over one walk cycle; the ground ticks scroll with the walked distance, so a planted
## foot must stay on its tick. Needs a renderer (not --headless):
##   godot --audio-driver Dummy --path game res://tests/anim_strip.tscn -- --out=<dir> [--ids=a,b,c] [--speed=walk|run]

const FRAMES := 6
const CELL := Vector2i(256, 256)
const TICK_SPACING := 1.0
const TICK_COUNT := 60
const DEFAULT_IDS := ["es1:RAPTOR", "bd:THOR", "bd:STRYDER", "es2:OUTLAW", "es2:PITBULL", "starsiege:tr_talo",
	"starsiege:cy_adju", "starsiege:kn_mino"]

var _out := "user://anim"
var _ids: Array = DEFAULT_IDS
var _gait := "walk"
var _viewport: SubViewport
var _camera: Camera3D
var _ticks: Array[MeshInstance3D] = []


func _ready() -> void:
	_parse_args()
	_build_stage()
	DirAccess.make_dir_recursive_absolute(_out)
	for id in _ids:
		await _strip(String(id))
	get_tree().quit()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--ids="):
			_ids = Array(a.substr(6).split(","))
		elif a.begins_with("--speed="):
			_gait = a.substr(8)


func _build_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.size = CELL
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.own_world_3d = true
	add_child(_viewport)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.62, 0.7)
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.7)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_viewport.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 40, 0)
	_viewport.add_child(sun)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_viewport.add_child(_camera)
	for i in TICK_COUNT:
		var tick := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(4.0, 0.08, 0.12)
		tick.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.1, 0.1, 0.1) if i % 5 else Color(0.8, 0.1, 0.1)
		tick.material_override = mat
		_viewport.add_child(tick)
		_ticks.append(tick)


func _strip(id: String) -> void:
	var v := Packs.vehicle(id)
	if v.is_empty():
		print("anim_strip: %s not installed" % id)
		return
	var inst := ShapeInstance.new()
	_viewport.add_child(inst)
	inst.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
	var anim := HercAnimator.new(v, inst, float(v.max_speed))
	anim.apply_stand()
	inst.position.y = -inst.lowest_point() * inst.scale.y
	var height := maxf(float(v.get("height_m", 8.0)), 3.0)
	_camera.size = height * 1.6
	_camera.position = Vector3(30.0, height * 0.45, 0.0)
	_camera.rotation_degrees = Vector3(0, 90, 0)
	var speed := _gait_speed(v, anim)
	var seq := anim.gait_for(speed)
	var cycle := float(anim.strides.get(seq, 1.0))
	var strip := Image.create(CELL.x * FRAMES, CELL.y, false, Image.FORMAT_RGBA8)
	var travelled := 0.0
	for f in FRAMES:
		var step := cycle / FRAMES if f > 0 else 0.0
		anim.update(speed, 0.0, step / maxf(speed, 0.001))
		travelled += step
		_place_ticks(travelled)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var frame := _viewport.get_texture().get_image()
		frame.convert(Image.FORMAT_RGBA8)
		strip.blit_rect(frame, Rect2i(Vector2i.ZERO, CELL), Vector2i(CELL.x * f, 0))
	var path := _out.path_join("anim_%s_%s.png" % [id.replace(":", "_"), _gait])
	strip.save_png(path)
	print("anim_strip: %s seq %d stride %.2f m speed %.1f m/s -> %s" % [id, seq, cycle, speed, path])
	inst.queue_free()


func _gait_speed(v: Dictionary, anim: HercAnimator) -> float:
	if _gait == "run":
		return float(v.max_speed)
	return minf(anim.run_switch_speed * 0.8, float(v.max_speed) * 0.5)


## Ground ticks across the walking direction, scrolled back by the distance walked.
func _place_ticks(travelled: float) -> void:
	for i in _ticks.size():
		var z := (i - TICK_COUNT / 2) * TICK_SPACING + travelled
		_ticks[i].position = Vector3(0, 0, fposmod(z + TICK_COUNT * TICK_SPACING / 2, TICK_COUNT * TICK_SPACING) - TICK_COUNT * TICK_SPACING / 2)

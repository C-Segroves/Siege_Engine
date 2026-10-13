extends Node3D
## Frame strips of the remake's pose cross-fades and the procedural collapse, for checking by eye
## (engine/herc_animator.gd, docs/formats/animation.md). Per vehicle one image, side view:
##   rows 1-2: stand -> accelerate through walk / run / fast run -> brake -> stop (ROW_FRAMES each, evenly
##             over the profile; the ground ticks scroll with the distance walked);
##   row 3:    the death (pack sequence cross-faded in, or the procedural collapse) over DEATH_SECONDS.
## Needs a renderer (not --headless):
##   godot --audio-driver Dummy --path game res://tests/blend_strip.tscn -- [--out=<dir>] [--ids=a,b,c]

const ROW_FRAMES := 10
const CELL := Vector2i(192, 192)
const FPS := 60.0
const ACCEL_SECONDS := 2.5
const HOLD_SECONDS := 0.4
const BRAKE_SECONDS := 1.5
const REST_SECONDS := 0.4
const DEATH_SECONDS := 1.8
## Walk this long before the kill so the death starts mid-stride.
const PRE_DEATH_SECONDS := 0.5
const TICK_SPACING := 1.0
const TICK_COUNT := 80
const DEFAULT_IDS := ["starsiege:kn_talo", "starsiege:cy_adju", "starsiege:kn_mino", "bd:THOR", "es1:RAPTOR"]
const BACKGROUND := Color(0.55, 0.62, 0.7)

var _out := ProjectSettings.globalize_path("res://").path_join("../renders").simplify_path()
var _ids: Array = DEFAULT_IDS
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


func _build_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.size = CELL
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.own_world_3d = true
	add_child(_viewport)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = BACKGROUND
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
		print("blend_strip: %s not installed" % id)
		return
	var inst := ShapeInstance.new()
	_viewport.add_child(inst)
	inst.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
	var anim := HercAnimator.new(v, inst, float(v.max_speed))
	anim.apply_stand()
	inst.position.y = -inst.lowest_point() * inst.scale.y
	var height := maxf(float(v.get("height_m", 8.0)), 3.0)
	_camera.size = height * 1.5
	_camera.position = Vector3(30.0, height * 0.45, 0.0)
	_camera.rotation_degrees = Vector3(0, 90, 0)
	var image := Image.create(CELL.x * ROW_FRAMES, CELL.y * 3, false, Image.FORMAT_RGBA8)
	await _transition_rows(v, anim, image)
	await _death_row(v, anim, image)
	var path := _out.path_join("blend_%s.png" % id.replace(":", "_"))
	image.save_png(path)
	print("blend_strip: %s death %s -> %s" % [id, "sequence %d" % anim.death_seq if anim.death_seq >= 0 else "collapse", path])
	inst.queue_free()


## Speed per frame: rest, accelerate to top speed, hold, brake to a stop, rest.
static func _profile(top: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for f in int(REST_SECONDS * FPS):
		out.append(0.0)
	for f in int(ACCEL_SECONDS * FPS):
		out.append(top * f / (ACCEL_SECONDS * FPS))
	for f in int(HOLD_SECONDS * FPS):
		out.append(top)
	for f in int(BRAKE_SECONDS * FPS):
		out.append(top * (1.0 - f / (BRAKE_SECONDS * FPS)))
	for f in int(REST_SECONDS * FPS):
		out.append(0.0)
	return out


func _transition_rows(v: Dictionary, anim: HercAnimator, image: Image) -> void:
	var profile := _profile(float(v.max_speed))
	var shots := ROW_FRAMES * 2
	var every := profile.size() / shots
	var travelled := 0.0
	for f in profile.size():
		anim.update(profile[f], 0.0, 1.0 / FPS)
		travelled += profile[f] / FPS
		if f % every == 0 and f / every < shots:
			var shot := f / every
			await _capture(image, travelled, Vector2i(shot % ROW_FRAMES, shot / ROW_FRAMES))


func _death_row(v: Dictionary, anim: HercAnimator, image: Image) -> void:
	var speed := minf(anim.run_switch_speed * 0.8, float(v.max_speed) * 0.5)
	for f in int(PRE_DEATH_SECONDS * FPS):
		anim.update(speed, 0.0, 1.0 / FPS)
	for shot in ROW_FRAMES:
		anim.apply_death(DEATH_SECONDS * shot / (ROW_FRAMES - 1))
		await _capture(image, 0.0, Vector2i(shot, 2))
	anim.apply_stand()


func _capture(image: Image, travelled: float, cell: Vector2i) -> void:
	_place_ticks(travelled)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var frame := _viewport.get_texture().get_image()
	frame.convert(Image.FORMAT_RGBA8)
	image.blit_rect(frame, Rect2i(Vector2i.ZERO, CELL), Vector2i(CELL.x * cell.x, CELL.y * cell.y))


## Ground ticks across the walking direction, scrolled back by the distance walked.
func _place_ticks(travelled: float) -> void:
	var span := TICK_COUNT * TICK_SPACING
	for i in _ticks.size():
		var z := (i - TICK_COUNT / 2) * TICK_SPACING + travelled
		_ticks[i].position = Vector3(0, 0, fposmod(z + span / 2, span) - span / 2)

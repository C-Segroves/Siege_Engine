extends Node3D
## Frame strips of the torso twist / turret yaw for checking by eye (engine/torso_rig.gd): per vehicle one
## row seen from above-front: twist left, centre, twist right, twist + pitch up, mid-stride + twist. The
## legs must stay put, the upper body, pods and muzzles (red dots) turn. Needs a renderer (not --headless):
##   godot --audio-driver Dummy --path game res://tests/twist_strip.tscn -- --out=<dir> [--ids=a,b,c]

const TorsoRig := preload("res://engine/torso_rig.gd")
const CELL := Vector2i(256, 256)
const TWIST := 0.6
const PITCH := 0.3
## Frames: [yaw, pitch, walking].
const POSES := [[-TWIST, 0.0, false], [0.0, 0.0, false], [TWIST, 0.0, false], [TWIST, PITCH, false], [TWIST, 0.0, true]]
const MUZZLE_DOT := 0.35
const DEFAULT_IDS := ["starsiege:tr_basl", "starsiege:tr_mino", "starsiege:cy_goad", "starsiege:cy_exec",
	"starsiege:rb_eman", "starsiege:rb_oly", "starsiege:tr_talo", "starsiege:tr_pala", "starsiege:cy_bolo",
	"starsiege:ha_pred", "bd:TALON", "bd:STRYDER"]

var _out := "user://twist"
var _ids: Array = DEFAULT_IDS
var _viewport: SubViewport
var _camera: Camera3D


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


func _strip(id: String) -> void:
	var v := Packs.vehicle(id)
	if v.is_empty():
		print("twist_strip: %s not installed" % id)
		return
	var inst := ShapeInstance.new()
	_viewport.add_child(inst)
	inst.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
	var muzzles := HercModel.build_mounts(v, inst)
	_attach_pods(v, inst, muzzles)
	var animator := HercAnimator.new(v, inst, float(v.max_speed))
	var torso := TorsoRig.new(v, inst, muzzles.values())
	animator.apply_stand()
	inst.position.y = -inst.lowest_point() * inst.scale.y
	_aim_camera(maxf(float(v.get("height_m", 8.0)), 3.0))
	var strip := Image.create(CELL.x * POSES.size(), CELL.y, false, Image.FORMAT_RGBA8)
	for f in POSES.size():
		animator.gait_phase = 0.25
		if POSES[f][2]:
			animator.update(float(v.max_speed) * 0.5, 0.0, 1.0 / 30.0)
		else:
			animator.apply_stand()
		torso.apply(POSES[f][0], POSES[f][1], animator.animates)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var frame := _viewport.get_texture().get_image()
		frame.convert(Image.FORMAT_RGBA8)
		strip.blit_rect(frame, Rect2i(Vector2i.ZERO, CELL), Vector2i(CELL.x * f, 0))
	var path := _out.path_join("twist_%s.png" % id.replace(":", "_"))
	strip.save_png(path)
	print("twist_strip: %s torso %d pitch %d lower %s -> %s" % [id, torso.torso_node, torso.pitch_node, torso.lower_body_nodes, path])
	inst.queue_free()


## Default loadout pods on their mounts, plus a red dot on every muzzle.
func _attach_pods(v: Dictionary, inst: ShapeInstance, muzzles: Dictionary) -> void:
	var mounts := HercModel.mount_nodes(v, inst, muzzles)
	var loadout: Array = v.get("loadout", [])
	for i in loadout.size():
		var wdef := Packs.weapon(str(loadout[i])) if str(loadout[i]) != "" else {}
		var model := HercModel.weapon_model(v, i, wdef, Packs.default_palette(str(v.pack))) if not wdef.is_empty() else null
		if model != null:
			HercModel.attach_weapon_model(mounts[i % mounts.size()], model, v)
	for m in muzzles.values():
		var dot := MeshInstance3D.new()
		var ball := SphereMesh.new()
		ball.radius = MUZZLE_DOT
		ball.height = MUZZLE_DOT * 2.0
		dot.mesh = ball
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1, 0, 0)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dot.material_override = mat
		m.add_child(dot)
		dot.scale = Vector3.ONE / maxf(m.global_basis.get_scale().x, 0.000001)


## Above and in front, a little to the side, so twist and pitch both show.
func _aim_camera(height: float) -> void:
	_camera.size = height * 1.9
	_camera.position = Vector3(height * 1.2, height * 2.2, -height * 2.0)
	_camera.look_at(Vector3(0, height * 0.45, 0))

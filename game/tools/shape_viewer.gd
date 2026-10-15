extends Node3D
## Debug viewer: browse converted shapes, LODs, cell states and animation sequences.
## Actions: ui_left / ui_right shape, ui_up next sequence, ui_down stop, viewer_next_lod (L),
## viewer_cell_state (C), viewer_interpolation (I), orbit + drag / right stick, zoom_in / zoom_out
## (wheel / triggers), screenshot (F12, SiegeInput); menu_back (Esc / pad B) or the Back button returns to the
## library.
## Flags: --shape=<pack:name> --screenshot=<png> --yaw=<rad> --seq=<n> --herc=<vehicle id>

const ORBIT_PER_PIXEL := 0.01       # radians per mouse pixel
const PITCH_LIMIT := 1.4
const ZOOM_IN_STEP := 0.9
const ZOOM_OUT_STEP := 1.1
const MAX_CELL_STATE := 3
const LIBRARY_SCENE := "res://library.tscn"
const BACK_MARGIN := 12.0

var names: Array = []
var current := 0
var inst: ShapeInstance
var lod := 0
var cell_state := 0
var cam_yaw := 0.6
var cam_pitch := 0.25
var cam_dist := 25.0
var label: Label
var cam: Camera3D

@export var start_shape := ""
@export var auto_screenshot := ""


func _ready() -> void:
	for pk in Assets.installed_packs():
		names.append_array(make_shape_names(pk))
	_build_stage()
	var args := OS.get_cmdline_user_args()
	for a in args:
		_apply_flag(a)
	_select_start_shape()
	_load()
	for a in args:
		if a.begins_with("--herc="):
			_show_herc(a.substr(7))
	if has_meta("seq"):
		inst.play(int(get_meta("seq")))
		_update_label()
	if auto_screenshot != "":
		_shoot_later()


## "pack:NAME" of every shape of `pack`: its shapes/_index.json, else the shape files themselves (the Tribes packs
## write no index).
static func make_shape_names(pack: String) -> Array:
	var out := []
	for e in Assets.shape_index(pack):
		out.append("%s:%s" % [pack, e.name])
	if not out.is_empty():
		return out
	for f in DirAccess.get_files_at(Assets.path("shapes", pack)):
		if f.ends_with(".json") and not f.begins_with("_"):
			out.append("%s:%s" % [pack, f.get_basename()])
	return out


## Background, light, camera, floor and the info label.
func _build_stage() -> void:
	SceneLighting.add_studio_environment(self, {"background": Color(0.32, 0.36, 0.42), "ambient": Color(0.55, 0.55, 0.55)})
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 0.9
	add_child(sun)
	cam = Camera3D.new()
	cam.far = 4000
	add_child(cam)
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	floor_mesh.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.45, 0.42, 0.36)
	floor_mesh.material_override = fm
	add_child(floor_mesh)
	var ui := CanvasLayer.new()
	add_child(ui)
	label = Label.new()
	label.position = Vector2(12, 8)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	ui.add_child(label)
	ui.add_child(_build_back_button())


## Back to the library, top right (also menu_back).
func _build_back_button() -> Button:
	var b := Widgets.small_button("Back to library", leave)
	b.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	b.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, int(BACK_MARGIN))
	b.focus_mode = Control.FOCUS_NONE   # ui_left / ui_right browse shapes
	return b


## Leaves the viewer for the library.
func leave() -> void:
	Session.front_end = LIBRARY_SCENE
	get_tree().change_scene_to_file(LIBRARY_SCENE)


func _apply_flag(a: String) -> void:
	if a.begins_with("--shape="):
		start_shape = a.substr(8)
	elif a.begins_with("--screenshot="):
		auto_screenshot = a.substr(13)
	elif a.begins_with("--yaw="):
		cam_yaw = float(a.substr(6))
	elif a.begins_with("--seq="):
		set_meta("seq", int(a.substr(6)))


func _select_start_shape() -> void:
	start_shape = Assets.qualify(start_shape) if start_shape != "" else ""
	if start_shape != "" and not names.has(start_shape) and not Assets.shape(start_shape).is_empty():
		names.append(start_shape)
	if start_shape != "" and names.has(start_shape):
		current = names.find(start_shape)


## --herc=<vehicle id>: the armed Herc instead of the bare shape.
func _show_herc(vehicle_id: String) -> void:
	inst.visible = false
	var h := Herc.new()
	h.vehicle_id = vehicle_id
	h.set_physics_process(false)
	add_child(h)
	h.equip(Packs.vehicle(h.vehicle_id).get("loadout", []))
	cam_dist = 18.0


func _shoot_later() -> void:
	await get_tree().create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(auto_screenshot)
	get_tree().quit()


func _load() -> void:
	if inst:
		inst.queue_free()
	inst = ShapeInstance.new()
	add_child(inst)
	if names.is_empty():
		_update_label()
		return
	var s := Assets.shape(names[current])
	inst.build(s, lod)
	inst.position.y = -inst.lowest_point()
	cell_state = 0
	var r := float(s.lods[0].radius) * Packs.metres_per_unit(String(s.get("pack", "es1")))
	cam_dist = max(r * 1.6, 3.0)
	_update_label()


func _update_label() -> void:
	if names.is_empty():
		label.text = "No shapes imported."
		return
	var s := inst.shape
	label.text = "%s  [%d/%d]  LOD %d/%d  seq %d/%d  cells %d state %d  interp %s\n←/→ shape  ↑/↓ sequence  L lod  C cells  I interp  drag orbit, wheel zoom, F12 screenshot" % [
		names[current], current + 1, names.size(), inst.lod, s.lods.size() - 1,
		inst.seq_index, inst.sequence_count(), inst.cell_count(), cell_state, inst.interpolate]


func _process(delta: float) -> void:
	var stick := SiegeInput.make_stick_orbit(delta)
	_apply_orbit(stick.x, stick.y)
	var target := Vector3(0, cam_dist * 0.25, 0)
	var dir := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch), cos(cam_yaw) * cos(cam_pitch))
	cam.position = target + dir * cam_dist
	cam.look_at(target)


func _apply_orbit(yaw: float, pitch: float) -> void:
	cam_yaw -= yaw
	cam_pitch = clampf(cam_pitch + pitch, -PITCH_LIMIT, PITCH_LIMIT)


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event):
		get_viewport().set_input_as_handled()
		leave()
	elif event is InputEventMouseMotion:
		if Input.is_action_pressed("orbit"):
			_apply_orbit(event.relative.x * ORBIT_PER_PIXEL, event.relative.y * ORBIT_PER_PIXEL)
	elif event.is_action_pressed("zoom_in"):
		cam_dist *= ZOOM_IN_STEP
	elif event.is_action_pressed("zoom_out"):
		cam_dist *= ZOOM_OUT_STEP
	elif _apply_command(event):
		_update_label()


## Viewer key commands; true when `event` was one.
func _apply_command(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_right", true):
		_select_shape(1)
	elif event.is_action_pressed("ui_left", true):
		_select_shape(-1)
	elif event.is_action_pressed("ui_up"):
		inst.play((inst.seq_index + 1) % max(inst.sequence_count(), 1))
	elif event.is_action_pressed("ui_down"):
		inst.stop()
		inst.reset_pose()
		inst.seq_index = -1
	elif event.is_action_pressed("viewer_next_lod"):
		lod = (lod + 1) % inst.shape.lods.size()
		_load()
	elif event.is_action_pressed("viewer_cell_state"):
		_step_cell_state()
	elif event.is_action_pressed("viewer_interpolation"):
		inst.interpolate = not inst.interpolate
	else:
		return false
	return true


func _select_shape(d: int) -> void:
	if names.is_empty():
		return
	current = posmod(current + d, names.size())
	lod = 0
	_load()


## Cycles every cell through its states 0..MAX_CELL_STATE.
func _step_cell_state() -> void:
	cell_state = cell_state + 1 if cell_state < MAX_CELL_STATE else 0
	for ci in inst.cell_count():
		inst.set_cell_state(ci, cell_state)

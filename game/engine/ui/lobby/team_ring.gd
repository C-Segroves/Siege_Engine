class_name TeamRing
extends Control
## The 3D stage of the lobby carousel (docs/design/lobby_loadout_economy.md section 5): the squad stands on circular
## platforms set along a ring; one mode at a time shows either everybody's infantry armour or everybody's vehicle, one model
## per platform (a member without one in that mode gets a labelled stand-in, LobbyCards). The focused member stands front
## and centre; the neighbours stand to the left and right, set back behind him, and members further along the ring are
## hidden. It is a ring: the first member's left neighbour is the last one (with two members the other stands on one side
## only, with one there are no neighbours). Models are built only for the visible arc. The ring turns smoothly, the short
## way round, to bring the focused member to the front.
## One SpotLight3D belongs to that front position: it hangs about 0.25 m above the focused head, slightly toward the
## camera, and shines down in a cone about as wide as the platform, so the focused member stands in a bright pool; the
## neighbours get only a dim fill against a low ambient light, so their silhouettes stay readable.
## Two large arrow buttons sit on the stage at mid-height and the mode toggle in its top-left corner (add_arrows, add_corner); the camera is framed to the stage's aspect so the
## focused model fills about two thirds of its height while both neighbours stay in view.
## Every model faces the screen (the camera's home position). Right-drag on the stage (or the right stick, `orbit_*`,
## while the stage has focus) orbits the view round the focused member: a full turn sideways, a small clamped pitch;
## the spotlight follows the view so he stays lit from the viewer's side. The orbit glides back home when the ring turns
## to another member, the mode switches, or on a right double-click.
##   set_members(members)   members: [{key, models: {infantry: {shape, skin, label}, vehicle: {vehicle | shape, skin, label}}}]
##   set_mode(mode) / set_focus(index)

const MODE_INFANTRY := "infantry"
const MODE_VEHICLE := "vehicle"
const RING_RADIUS := 3.0
const STEP_ANGLE := deg_to_rad(60.0)    # between neighbouring platforms along the ring
const VISIBLE_STEPS := 2                # members this many places from the focus still stand on the stage
const PLATFORM_RADIUS := 1.2
const PLATFORM_HEIGHT := 0.14
const HEAD_CLEARANCE := 0.25            # the light hangs this far above the focused head
const LIGHT_FORWARD := 0.3              # ... and this far toward the camera
const LIGHT_RANGE := 7.0
const LIGHT_ANGLE := 30.0
const LIGHT_ANGLE_ATTENUATION := 0.8
const LIGHT_ENERGY := 22.0
const FILL_ENERGY := 0.22
const AMBIENT_ENERGY := 0.06
const VEHICLE_MAX_HEIGHT := 2.4
const VEHICLE_MAX_RADIUS := 1.05
const INFANTRY_HEIGHT := 2.0
const TURN_SECONDS := 0.35
const TALL_HEIGHT := 320.0
const COMPACT_HEIGHT := 250.0
const CAMERA_FOV := 34.0
const FOCUS_FILL := 0.66                # share of the stage height the focused model fills
const SIDE_MARGIN := 1.15               # metres beside a neighbour's centre that must stay in view
const BACKGROUND := Color(0.012, 0.035, 0.042)
const PLATFORM_COLOR := Color(0.2, 0.3, 0.31)
const RIM_COLOR := Color(0.1, 0.55, 0.5)
const LABEL_COLOR := Color(1.0, 0.87, 0.0)
const ORBIT_MOUSE_RATE := 0.008      # radians per pixel dragged
const ORBIT_STICK_RATE := Vector2(2.2, 1.0)   # radians per second at full deflection
const ORBIT_PITCH_MIN := -0.12
const ORBIT_PITCH_MAX := 0.4
const ORBIT_RESET_SECONDS := 0.3
const STICK_ACTIONS := ["orbit_left", "orbit_right", "orbit_up", "orbit_down"]
const ORBIT_HINT := "Right-drag: look around"
const ARROW_SIZE := Vector2(64, 96)
const ARROW_FONT_SIZE := 30
const SHOWN_STEPS := 1.5            # platforms further than this from the turning focus are hidden

var mode := MODE_INFANTRY
var focus := 0
var orbit_yaw := 0.0                # the view's orbit round the focused member (0, 0 = home, facing the screen)
var orbit_pitch := 0.0
var hint: Label
var turn := 0.0                     # where the ring is turned, in member places (animates toward `focus`)
var light: SpotLight3D
var viewport: SubViewport
var camera: Camera3D
var ring_root: Node3D
var platforms: Array[Node3D] = []
var models: Array[Node3D] = []      # per member: the model on the platform in the current mode (null when not built)
var _members: Array = []
var _members_key := ""
var _model_key := ""
var _heights: Array[float] = []
var _tween: Tween
var _orbit_tween: Tween
var _home_eye := Vector3(0, 1.6, 9.0)
var _home_target := Vector3(0, 1.0, 0)


func _init() -> void:
	custom_minimum_size = Vector2(0, TALL_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	var container := SubViewportContainer.new()
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(container)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.world_3d = World3D.new()
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.audio_listener_enable_3d = false
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	container.add_child(viewport)
	_build_world()
	hint = Widgets.label(ORBIT_HINT, "DimLabel")
	add_child(hint)
	hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 10)   # clear of the platforms
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_place_camera)


func set_compact(on: bool) -> void:
	custom_minimum_size.y = COMPACT_HEIGHT if on else TALL_HEIGHT


## Puts `prev` and `next` on the stage: large buttons at mid-height on the left and right edges.
func add_arrows(prev: Button, next: Button) -> void:
	for pair in [[prev, Control.PRESET_CENTER_LEFT, 1.0], [next, Control.PRESET_CENTER_RIGHT, -1.0]]:
		var b: Button = pair[0]
		b.custom_minimum_size = ARROW_SIZE
		b.size = ARROW_SIZE
		b.add_theme_font_size_override("font_size", ARROW_FONT_SIZE)
		add_child(b)
		b.set_anchors_and_offsets_preset(pair[1], Control.PRESET_MODE_KEEP_SIZE, 8)


## Puts `control` in the stage's top-left corner.
func add_corner(control: Control) -> void:
	add_child(control)
	control.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 8)


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.75, 0.75)
	env.ambient_light_energy = AMBIENT_ENERGY
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	viewport.add_child(world_env)
	camera = Camera3D.new()
	camera.fov = CAMERA_FOV
	viewport.add_child(camera)
	ring_root = Node3D.new()
	viewport.add_child(ring_root)
	var fill := DirectionalLight3D.new()   # the dim spill that keeps the neighbours readable
	fill.light_energy = FILL_ENERGY
	fill.light_color = Color(0.55, 0.8, 0.85)
	fill.rotation_degrees = Vector3(-35, 20, 0)
	viewport.add_child(fill)
	light = SpotLight3D.new()
	light.spot_range = LIGHT_RANGE
	light.spot_angle = LIGHT_ANGLE
	light.spot_angle_attenuation = LIGHT_ANGLE_ATTENUATION
	light.light_energy = LIGHT_ENERGY
	light.light_color = Color(1.0, 0.95, 0.85)
	light.shadow_enabled = true
	light.rotation_degrees = Vector3(-90, 0, 0)
	viewport.add_child(light)   # a child of the viewport, not of the turning ring: it belongs to the focus position
	_place_camera()


# ------------------------------------------------------------------ the members

## Sets the platforms and what stands on them; nothing is rebuilt when the members and mode are the same.
func set_members(members: Array) -> void:
	var key := JSON.stringify(members.map(func(m: Dictionary) -> String: return str(m.key)))
	var model_key := JSON.stringify([mode, members.map(func(m: Dictionary) -> Variant: return m.get("models", {}).get(mode, {}))])
	_members = members
	if key != _members_key:
		_members_key = key
		_rebuild_platforms()
		_model_key = ""
	if model_key != _model_key:
		_model_key = model_key
		_clear_models()
	set_focus(focus, false)


func set_mode(new_mode: String) -> void:
	if new_mode == mode:
		return
	mode = new_mode
	reset_orbit()
	set_members(_members)
	_place_camera()


func set_focus(index: int, animate := true) -> void:
	var n := _members.size()
	index = posmod(index, n) if n > 0 else 0
	var delta := make_offset(index, focus, n)   # the short way round
	if index != focus:
		reset_orbit()
	focus = index
	_ensure_models()
	_turn_by(delta, animate)
	_place_platforms()
	_place_light()


func member_count() -> int:
	return _members.size()


## How many models stand on the stage now (only the visible arc is built).
func built_model_count() -> int:
	return models.filter(func(m: Node3D) -> bool: return m != null).size()


## The measured height of the model of member `index` in the current mode (0 = no model).
func make_model_height(index: int) -> float:
	return _heights[index] if index >= 0 and index < _heights.size() else 0.0


## Member `i`'s place relative to `at` along a ring of `n`, in (-n/2, n/2]: 0 = front, -1 = left neighbour, 1 = right.
static func make_offset(i: float, at: float, n: int) -> float:
	if n <= 0:
		return 0.0
	var half := n * 0.5
	return half - fposmod(half - (i - at), float(n))


func _process(delta: float) -> void:
	if has_focus():
		var stick := Input.get_vector(STICK_ACTIONS[0], STICK_ACTIONS[1], STICK_ACTIONS[2], STICK_ACTIONS[3])
		if not stick.is_zero_approx():
			orbit(-stick.x * ORBIT_STICK_RATE.x * delta, -stick.y * ORBIT_STICK_RATE.y * delta)
	_place_platforms()
	_apply_view()


## Turns the view round the focused member by `d_yaw` (any amount, it wraps) and `d_pitch` (clamped).
func orbit(d_yaw: float, d_pitch: float) -> void:
	if is_instance_valid(_orbit_tween):
		_orbit_tween.kill()
	orbit_yaw = wrapf(orbit_yaw + d_yaw, -PI, PI)
	orbit_pitch = clampf(orbit_pitch + d_pitch, ORBIT_PITCH_MIN, ORBIT_PITCH_MAX)
	_apply_view()


## Glides the view back home (facing the screen); at once when `animate` is false or the stage is not shown.
func reset_orbit(animate := true) -> void:
	if is_instance_valid(_orbit_tween):
		_orbit_tween.kill()
	if not animate or not is_inside_tree() or (is_zero_approx(orbit_yaw) and is_zero_approx(orbit_pitch)):
		orbit_yaw = 0.0
		orbit_pitch = 0.0
		_apply_view()
		return
	_orbit_tween = create_tween().set_parallel()
	_orbit_tween.tween_property(self, "orbit_yaw", 0.0, ORBIT_RESET_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_orbit_tween.tween_property(self, "orbit_pitch", 0.0, ORBIT_RESET_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Right-drag orbits, a right double-click resets.
func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_RIGHT:
		if button.pressed and button.double_click:
			reset_orbit()
		elif button.pressed:
			grab_focus()
		accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and (motion.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
		orbit(-motion.relative.x * ORBIT_MOUSE_RATE, motion.relative.y * ORBIT_MOUSE_RATE)
		accept_event()


func _rebuild_platforms() -> void:
	for p in platforms:
		p.queue_free()
	platforms.clear()
	for i in _members.size():
		var platform := _make_platform()
		ring_root.add_child(platform)
		platforms.append(platform)
	_place_platforms()


## A place `offset` steps from the front of the ring: 0 in front (toward the camera, +z), positive to the right.
static func make_slot_position(offset: float) -> Vector3:
	var a := STEP_ANGLE * offset
	return Vector3(sin(a) * RING_RADIUS, 0, cos(a) * RING_RADIUS)


func _make_platform() -> Node3D:
	var root := Node3D.new()
	var disc := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = PLATFORM_RADIUS
	mesh.bottom_radius = PLATFORM_RADIUS * 1.04
	mesh.height = PLATFORM_HEIGHT
	disc.mesh = mesh
	disc.position.y = -PLATFORM_HEIGHT * 0.5
	var metal := StandardMaterial3D.new()
	metal.albedo_color = PLATFORM_COLOR
	metal.metallic = 0.3
	metal.roughness = 0.6
	disc.material_override = metal
	root.add_child(disc)
	var rim := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = PLATFORM_RADIUS * 0.96
	torus.outer_radius = PLATFORM_RADIUS * 1.02
	rim.mesh = torus
	rim.scale = Vector3(1, 0.18, 1)
	var glow := StandardMaterial3D.new()
	glow.albedo_color = RIM_COLOR
	glow.emission_enabled = true
	glow.emission = RIM_COLOR
	glow.emission_energy_multiplier = 0.6
	rim.material_override = glow
	root.add_child(rim)
	return root


func _clear_models() -> void:
	for m in models:
		if m != null:
			m.queue_free()
	models.clear()
	_heights.clear()
	models.resize(_members.size())
	_heights.resize(_members.size())


## Builds the models of the visible arc around the focus that are not built yet (the others stay null).
func _ensure_models() -> void:
	if models.size() != _members.size():
		_clear_models()
	for i in _members.size():
		if models[i] != null or absf(make_offset(i, focus, _members.size())) > VISIBLE_STEPS:
			continue
		var spec: Dictionary = _members[i].get("models", {}).get(mode, {})
		var holder := Node3D.new()
		# the holder turns the model to face the camera (_face_camera) about the platform's centre; the model is centred in it
		platforms[i].add_child(holder)
		models[i] = holder
		var model := _make_model(spec, holder)
		_heights[i] = _fit_model(model) if model != null else 0.0
		if str(spec.get("label", "")) != "":
			holder.add_child(_make_label(str(spec.label)))


## The model of one platform: an armour by its shape id, or a vehicle (any pack) in the given skin; null when there is none.
func _make_model(spec: Dictionary, holder: Node3D) -> Node3D:
	var shape_id := str(spec.get("shape", ""))
	var vehicle_id := str(spec.get("vehicle", ""))
	if vehicle_id != "":
		var vdef := Packs.vehicle(vehicle_id)
		shape_id = str(vdef.get("shape", vdef.get("id", vehicle_id)))
	if shape_id == "":
		return null
	var sdef := Assets.shape(shape_id)
	if ((sdef.get("lods", [{}])[0] as Dictionary).get("pieces", []) as Array).is_empty():
		return null
	var model := ShapeInstance.new()
	model.texture_overrides = SkinCatalog.make_texture_overrides(str(sdef.get("id", "")), str(spec.get("skin", "")))
	holder.add_child(model)   # in the tree first, as the hangar does
	model.build(sdef, 0, Packs.default_palette(str(sdef.get("pack", "es1"))))
	return model


## The stand-in's caption at the foot of its platform ("ON FOOT", "AI PICKS IN BATTLE").
func _make_label(text: String) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = LABEL_COLOR
	label.outline_size = 10
	label.font_size = 40
	label.pixel_size = 0.006
	label.position = Vector3(0, 0.25, 0)   # at the model's feet: over its head it would run into the stage's corner button
	return label


## Stands the model on its platform, scaled to fit it, facing the camera; returns its height in metres.
func _fit_model(model: Node3D) -> float:
	var box := _measure(model)
	var base := model.scale   # the shape's own unit scale (ShapeInstance.build)
	var real := box.size * base
	var limit_height := INFANTRY_HEIGHT if mode == MODE_INFANTRY else VEHICLE_MAX_HEIGHT
	var radius := maxf(Vector2(real.x, real.z).length() * 0.5, 0.2)
	var factor := minf(limit_height / maxf(real.y, 0.05), VEHICLE_MAX_RADIUS / radius)
	model.scale = base * factor
	model.position = Vector3(-box.get_center().x * model.scale.x, -box.position.y * model.scale.y, -box.get_center().z * model.scale.z)
	return real.y * factor


## The model's bounding box in its own space (before scaling).
func _measure(model: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var bb: AABB = _to_model_space(model, m) * m.mesh.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	return box if not first else AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 2, 1))


static func _to_model_space(model: Node3D, mesh: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var node: Node = mesh
	while node != null and node != model:
		xf = (node as Node3D).transform * xf
		node = node.get_parent()
	return xf


# ------------------------------------------------------------------ the turn, the camera, the light

func _turn_by(delta: float, animate: bool) -> void:
	if is_instance_valid(_tween):
		_tween.kill()
	var n := maxi(_members.size(), 1)
	turn = focus - delta + make_offset(turn, focus - delta, n)   # where the turn is now, on the same lap as the old focus
	var target := turn + delta
	if not animate or not is_inside_tree() or is_zero_approx(delta):
		turn = focus
		_place_platforms()
		return
	_tween = create_tween()
	_tween.tween_property(self, "turn", target, TURN_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.finished.connect(func() -> void: turn = focus)


## Puts every platform at its place relative to `turn`: within SHOWN_STEPS of the front (the focus and one neighbour each
## side) it is shown, the rest hidden; models are built ahead (VISIBLE_STEPS) so a turn never waits for one.
func _place_platforms() -> void:
	var n := platforms.size()
	for i in n:
		var offset := make_offset(i, turn, n)
		platforms[i].position = make_slot_position(offset)
		platforms[i].visible = absf(offset) <= SHOWN_STEPS and (n > 1 or i == 0)
		if i < models.size() and models[i] != null:
			_face_camera(models[i], platforms[i].position)


## Turns a model's holder so the model looks straight at the camera's home position (the screen) from where its platform
## stands now; an orbit of the view leaves the models as they are. Every pack's
## shapes look down -z (as the hangar shows them: its pivot turns them by PI to face its camera on +z), so the holder's
## -z is pointed at the camera, flattened to the ground.
## (The ring and its platforms never rotate, so the platform's position is its place in the camera's space.)
func _face_camera(holder: Node3D, at: Vector3) -> void:
	var to_camera := _home_eye - at
	holder.rotation.y = atan2(-to_camera.x, -to_camera.z)


## Degrees between where member `index`'s model looks (its -z, flattened) and the camera as it is now; -1 without a model.
func make_facing_error(index: int) -> float:
	if index < 0 or index >= models.size() or models[index] == null:
		return -1.0
	var holder := models[index]
	var forward := -holder.global_basis.z
	var to_camera := camera.position - holder.global_position
	return rad_to_deg(absf(Vector2(forward.x, forward.z).angle_to(Vector2(to_camera.x, to_camera.z))))


## The light over the focus position: just above the focused head (or a standing person's height over an empty platform),
## a little toward the camera, shining down. It is in world space, so it never turns with the ring.
func _place_light() -> void:
	var head := make_model_height(focus)
	head = head if head > 0.0 else 1.8
	var toward_viewer := Vector3(sin(orbit_yaw), 0, cos(orbit_yaw))
	light.position = Vector3(0, head + HEAD_CLEARANCE, RING_RADIUS) + toward_viewer * LIGHT_FORWARD
	light.rotation_degrees = Vector3(-90, 0, 0)


## The camera in front of the focus position, low and close enough that the focused model fills FOCUS_FILL of the height,
## and far enough that both neighbours (at one STEP_ANGLE each side) fit across the stage's width.
func _place_camera() -> void:
	var frame_height := INFANTRY_HEIGHT if mode == MODE_INFANTRY else VEHICLE_MAX_HEIGHT
	var tan_v := tan(deg_to_rad(CAMERA_FOV * 0.5))
	var aspect := size.x / size.y if size.y > 1.0 else 1.6
	var fill_distance := frame_height / (FOCUS_FILL * 2.0 * tan_v)
	var side_x := sin(STEP_ANGLE) * RING_RADIUS + SIDE_MARGIN
	var side_back := RING_RADIUS - cos(STEP_ANGLE) * RING_RADIUS
	var side_distance := side_x / (tan_v * aspect) - side_back
	var distance := maxf(fill_distance, side_distance)
	var front := Vector3(0, 0, RING_RADIUS)
	_home_eye = front + Vector3(0, frame_height * 0.78, distance)
	_home_target = front + Vector3(0, frame_height * 0.5, 0)
	_apply_view()


## The camera at its home position turned by the orbit round the focused member, and the light following it.
func _apply_view() -> void:
	var offset := _home_eye - _home_target
	offset = offset.rotated(Vector3.RIGHT, -orbit_pitch).rotated(Vector3.UP, orbit_yaw)
	camera.look_at_from_position(_home_target + offset, _home_target, Vector3.UP)
	_place_light()

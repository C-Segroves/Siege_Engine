class_name HangarView
extends Control
## Embeddable hangar: SubViewportContainer + SubViewport (own 3D world) + HangarBay, at any size.
## Input (when `interactive`) goes through named actions only: `orbit` held + mouse motion and the
## right stick (`orbit_left/right/up/down`) turn the view, `zoom_in` / `zoom_out` (wheel, triggers)
## zoom, a double-click on `orbit` resets the view. `pixelated` renders at about `pixel_height`
## lines with nearest filtering (the original shell's 320x200 look).

const BAY_SCENE := preload("res://engine/hangar/hangar_bay.tscn")
const ORBIT := "orbit"
const ZOOM_IN := "zoom_in"
const ZOOM_OUT := "zoom_out"
const STICK_ACTIONS := ["orbit_left", "orbit_right", "orbit_up", "orbit_down"]
const MOUSE_YAW_PER_PIXEL := 0.008      # radians
const MOUSE_PITCH_PER_PIXEL := 0.006
const STICK_ORBIT_RATE := Vector2(2.2, 1.4)   # radians per second at full deflection
const WHEEL_ZOOM_STEP := 1.1
const TRIGGER_ZOOM_RATE := 1.6          # zoom factor per second at full trigger

var bay: HangarBay
var viewport: SubViewport
var container: SubViewportContainer
var interactive := true
var pixelated := false: set = set_pixelated
var pixel_height := 200
var _caption: Label
var _drag := false
var _trigger_zoom := {ZOOM_IN: 0.0, ZOOM_OUT: 0.0}   # analog trigger strength per zoom action


func _init() -> void:
	clip_contents = true
	container = SubViewportContainer.new()
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(container)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.world_3d = World3D.new()
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	viewport.audio_listener_enable_3d = false
	container.add_child(viewport)
	bay = BAY_SCENE.instantiate() as HangarBay
	viewport.add_child(bay)
	_caption = Label.new()
	_caption.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_caption.position = Vector2(14, 10)
	_caption.theme_type_variation = "HangarCaption"
	_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_caption)
	bay.caption_changed.connect(func(t: String) -> void: _caption.text = t)
	resized.connect(_apply_pixels)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP if interactive else Control.MOUSE_FILTER_IGNORE
	_apply_pixels()


# ------------------------------------------------------------------ pass-through API

func show_herc(vehicle_id: String, loadout: Array = []) -> void:
	bay.show_herc(vehicle_id, loadout)


## Draws the shown model in skin `skin_id` (SkinCatalog; "" = default).
func apply_skin(skin_id: String) -> void:
	bay.apply_skin(skin_id)


func highlight_hardpoint(i: int) -> void:
	bay.highlight_hardpoint(i)


func set_caption(text: String) -> void:
	bay.set_caption(text)


## Where the Herc's centre sits in the view (0..1) - e.g. leave room for a side panel.
func set_frame_center(c: Vector2) -> void:
	bay.frame_center = c


func set_interactive(on: bool) -> void:
	interactive = on
	mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE


func set_pixelated(on: bool) -> void:
	pixelated = on
	_apply_pixels()


func _apply_pixels() -> void:
	if container == null:
		return
	if pixelated:
		container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		viewport.msaa_3d = Viewport.MSAA_DISABLED
		container.stretch_shrink = maxi(1, int(round(size.y / float(maxi(pixel_height, 1)))))
	else:
		container.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		viewport.msaa_3d = Viewport.MSAA_2X
		container.stretch_shrink = 1
	_caption.visible = not pixelated


## The rendered frame (for screenshots).
func get_image() -> Image:
	return viewport.get_texture().get_image()


func _gui_input(event: InputEvent) -> void:
	if not interactive:
		return
	if event is InputEventMouseMotion:
		_apply_mouse_orbit(event as InputEventMouseMotion)
	elif UiActions.is_pressed(event, ORBIT):
		_drag = true
		if event is InputEventMouseButton and (event as InputEventMouseButton).double_click:
			bay.reset_view()
		accept_event()
	elif UiActions.is_released(event, ORBIT):
		_drag = false
		accept_event()
	elif UiActions.is_pressed(event, ZOOM_IN):
		bay.zoom_by(WHEEL_ZOOM_STEP)
		accept_event()
	elif UiActions.is_pressed(event, ZOOM_OUT):
		bay.zoom_by(1.0 / WHEEL_ZOOM_STEP)
		accept_event()


func _apply_mouse_orbit(motion: InputEventMouseMotion) -> void:
	if not _drag:
		return
	bay.orbit(-motion.relative.x * MOUSE_YAW_PER_PIXEL, motion.relative.y * MOUSE_PITCH_PER_PIXEL)
	accept_event()


## Gamepad triggers zoom while held: remember their analog strength (the mouse wheel is handled
## per click in _gui_input).
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadMotion:
		for action in _trigger_zoom:
			if InputMap.has_action(action) and event.is_action(action, true):
				_trigger_zoom[action] = UiActions.strength(event, action)


func _process(delta: float) -> void:
	if not interactive or not is_visible_in_tree():
		return
	var stick := _make_stick_orbit()
	if stick != Vector2.ZERO:
		bay.orbit(-stick.x * STICK_ORBIT_RATE.x * delta, stick.y * STICK_ORBIT_RATE.y * delta)
	var zoom_axis: float = _trigger_zoom[ZOOM_IN] - _trigger_zoom[ZOOM_OUT]
	if absf(zoom_axis) > 0.0:
		bay.zoom_by(pow(TRIGGER_ZOOM_RATE, zoom_axis * delta))


func _make_stick_orbit() -> Vector2:
	for action in STICK_ACTIONS:
		if not InputMap.has_action(action):
			return Vector2.ZERO
	return Input.get_vector(STICK_ACTIONS[0], STICK_ACTIONS[1], STICK_ACTIONS[2], STICK_ACTIONS[3])

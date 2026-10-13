class_name MissileCamWindow
extends PanelContainer
## The remake's picture-in-picture of the missile camera (MissileCam) in the in-battle HUD panel style (theme
## HudPanel): shown while the pilot's Earthsiege missile flies and during its hit flash, unless the cockpit's own
## MFD already shows the MISSILE CAM page. missile_cam_toggle (M) or the Options setting (DisplaySettings)
## switches it on / off.
## Placement: the first spot clear of the HUD's windows, cockpit panels, chat and side panels (`occupied_provider`,
## screen rects; ChatPlacement.is_clear), searched from the bottom-right corner upwards, then leftwards (the chat
## searches from the bottom left); a smaller picture when the full one fits nowhere.

const TOGGLE_ACTION := "missile_cam_toggle"
const TITLE := "MISSILE CAM"
const IMPACT_TEXT := "IMPACT"
const RANGE_FORMAT := "RNG %d M"
const EDGE := 16.0
const SEARCH_STEP := 16.0
## Picture sizes tried, largest first (shares of MissileCam.RESOLUTION).
const PICTURE_SCALES := [1.0, 0.75, 0.5]
const PLACE_SECONDS := 0.5

var cam: MissileCam
var cockpit: CockpitDisplay
var enabled := true
## Returns the screen rects the window must keep clear of (Array of Rect2); none when unset.
var occupied_provider := Callable()
var _place_t := 0.0
## Where apply_placement put the window (screen rect).
var placed_rect := Rect2()
## The frame, title and status around the full-size picture, measured once ([width, height] extra, title width).
var _chrome := Vector2.ZERO
var _title_width := 0.0
var _title: Label
var _picture: TextureRect
var _status: Label


func _init(p_cam: MissileCam) -> void:
	cam = p_cam
	name = "MissileCamWindow"
	theme_type_variation = "HudPanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)
	_title = Widgets.label(TITLE + _make_toggle_hint(), "HudTitle")
	column.add_child(_title)
	_picture = TextureRect.new()
	_picture.texture = cam.get_texture()
	_picture.custom_minimum_size = Vector2(MissileCam.RESOLUTION)
	_picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_picture)
	_status = Widgets.label("", "HudLine")
	column.add_child(_status)
	enabled = DisplaySettings.missile_cam_window_on()
	visible = false


func _process(delta: float) -> void:
	var was_visible := visible
	visible = should_show()
	if not visible:
		return
	_place_t -= delta
	if not was_visible or _place_t <= 0.0:
		_place_t = PLACE_SECONDS
		apply_placement(get_viewport_rect().size)
	var flash := cam.is_flash_on()
	_status.text = IMPACT_TEXT if cam.is_showing_hit() else RANGE_FORMAT % int(cam.make_range())
	_picture.modulate = Color(1.6, 1.6, 1.6) if flash else Color.WHITE


## Moves the window to its free spot on a screen of size `screen`, shrinking the picture when needed.
func apply_placement(screen: Vector2) -> void:
	var occupied: Array = occupied_provider.call() if occupied_provider.is_valid() else []
	if _chrome == Vector2.ZERO:
		# measured with the full picture (a container's minimum size only updates on the next frame)
		_chrome = get_combined_minimum_size() - _picture.custom_minimum_size
		_title_width = _title.get_combined_minimum_size().x
	var sz := Vector2.ZERO
	for k in PICTURE_SCALES:
		var picture := Vector2(MissileCam.RESOLUTION) * float(k)
		sz = Vector2(maxf(picture.x, _title_width), picture.y) + _chrome
		var spot = make_free_position(occupied, sz, screen)
		if spot != null:
			_apply_rect(Rect2(spot, sz), picture)
			return
	_apply_rect(Rect2(screen - sz - Vector2(EDGE, EDGE), sz), Vector2(MissileCam.RESOLUTION) * float(PICTURE_SCALES.back()))


func _apply_rect(r: Rect2, picture: Vector2) -> void:
	_picture.custom_minimum_size = picture
	placed_rect = r
	position = r.position
	size = r.size


## The first spot for a window of `window_size` clear of `occupied`, from the bottom-right corner upwards,
## column by column to the left; null when none.
static func make_free_position(occupied: Array, window_size: Vector2, screen: Vector2) -> Variant:
	var x := screen.x - window_size.x - EDGE
	while x >= EDGE:
		var y := screen.y - window_size.y - EDGE
		while y >= EDGE:
			if ChatPlacement.is_clear(Rect2(Vector2(x, y), window_size), occupied):
				return Vector2(x, y)
			y -= SEARCH_STEP
		x -= SEARCH_STEP
	return null


## True when the window has a missile to show and is wanted here.
func should_show() -> bool:
	return enabled and cam.is_active() and not _is_on_mfd()


## The cockpit is up with its MFD on the MISSILE CAM page: the original page shows it already.
func _is_on_mfd() -> bool:
	return is_instance_valid(cockpit) and cockpit.visible and cockpit.mfd_mode == CockpitMfd.MODE_MISSILE \
		and not cockpit.look_down and not cockpit.is_hud_only()


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(TOGGLE_ACTION) and event.is_action_pressed(TOGGLE_ACTION) and not ChatFocus.open:
		toggle()


## Switches the window on / off and remembers it (DisplaySettings).
func toggle() -> void:
	enabled = not enabled
	DisplaySettings.apply_missile_cam_window(enabled)


static func _make_toggle_hint() -> String:
	if not InputMap.has_action(TOGGLE_ACTION):
		return ""
	return "   (%s)" % BindingText.make_action_bindings(TOGGLE_ACTION).get_slice(BindingText.SEPARATOR, 0)

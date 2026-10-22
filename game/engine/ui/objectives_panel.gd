class_name ObjectivesPanel
extends PanelContainer
## The in-battle mission objectives: a translucent side panel (theme HudPanel) at the right edge listing the
## battle's objectives (MissionObjectives: every game's campaigns, training, extraction raids, the match rule);
## a completed objective turns green and is ticked. Updated a few times a second; objectives_toggle (J) or the
## Options setting (DisplaySettings) shows / hides it.
## Placement (apply_placement): with the plain HUD up it is the `objectives` element of HudLayout (top-right zone,
## under the radar; trailing lines are hidden when the zone's height is short). Over a cockpit it is the first spot
## clear of the cockpit's instruments and panel, the chat and the missile cam window (`occupied_provider`, screen
## rects; ChatPlacement.is_clear), searched from the top-right corner downwards, then leftwards; narrower (wrapping)
## when the full width fits nowhere. It draws over the cockpit art (BattleOverlay keeps it the overlay's last child).

const TOGGLE_ACTION := "objectives_toggle"
const REFRESH_SECONDS := 0.5
const RESEND_SECONDS := 5.0
const WIDTH := 320.0
const EDGE := 16.0
## Widths tried, widest first.
const WIDTHS := [320.0, 260.0, 210.0]
const SEARCH_STEP := 16.0
const PLACE_SECONDS := 0.5
const DONE_MARK := "[x] "
const OPEN_MARK := "[ ] "
const TITLE := "OBJECTIVES"

var battle: Battle
## func(screen: Vector2) -> Array of screen Rect2 the panel keeps clear of; none when unset.
var occupied_provider := Callable()
## Where apply_placement put the panel (screen rect).
var placed_rect := Rect2()
var _place_t := 0.0
var _width := WIDTH
var _zone_size := Vector2.ZERO   # the declared size while the panel sits in its HudLayout zone
var _lines: VBoxContainer
var _shown := []
var _refresh_t := 0.0
var _host_lines = null        # a client in a mission: the host's lines (the mission's state lives on the host)
var _sent := []
var _resend_t := 0.0


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "ObjectivesPanel"
	theme_type_variation = "HudPanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(WIDTH, 0)
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)
	column.add_child(Widgets.label(TITLE + _make_toggle_hint(), "HudTitle"))
	_lines = VBoxContainer.new()
	column.add_child(_lines)
	visible = DisplaySettings.objectives_panel_on()


func _process(delta: float) -> void:
	_keep_zone_place()
	_refresh_t -= delta
	if _refresh_t > 0.0:
		return
	_refresh_t = REFRESH_SECONDS
	var lines: Array = _host_lines if _host_lines != null else MissionObjectives.make_lines(battle)
	apply_lines(lines)
	_send_to_clients(lines, REFRESH_SECONDS)
	_place_t -= REFRESH_SECONDS
	if _place_t <= 0.0:
		_place_t = PLACE_SECONDS
		apply_placement(get_viewport_rect().size)


## Moves the panel to its place on a screen of size `screen`: its HudLayout zone under the plain HUD's radar, else
## the free spot among a cockpit's windows (narrower when the full width fits nowhere).
func apply_placement(screen: Vector2) -> void:
	var layout := HudLayout.of(self)
	if layout.is_shown(&"radar"):
		_apply_zone_placement(layout, screen)
		return
	layout.withdraw(&"objectives")
	_zone_size = Vector2.ZERO
	_apply_free_placement(screen)


## Keeps the zone declaration alive every frame and follows the stack (the radar above may come and go).
func _keep_zone_place() -> void:
	if _zone_size == Vector2.ZERO:
		return
	var layout := HudLayout.of(self)
	layout.declare(&"objectives", _zone_size if visible and modulate.a > 0.0 else Vector2.ZERO)
	var r := layout.rect_of(&"objectives")
	if r.has_area():
		placed_rect = r
		position = r.position


## The `objectives` element of the layout: full width, as many lines as the zone's height holds.
func _apply_zone_placement(layout: HudLayout, screen: Vector2) -> void:
	var most: Vector2 = HudLayout.ELEMENTS[&"objectives"].max
	layout.screen = screen
	_apply_width(most.x)
	_show_lines_fitting(most.y)
	_zone_size = Vector2(most.x, get_combined_minimum_size().y)
	layout.declare(&"objectives", _zone_size)
	_apply_rect(layout.rect_of(&"objectives"), most.x)


## Shows as many of the lines, from the first, as fit in `height`.
func _show_lines_fitting(height: float) -> void:
	for label in _lines.get_children():
		(label as Control).visible = true
	var labels := _lines.get_children()
	while get_combined_minimum_size().y > height and not labels.is_empty():
		(labels.pop_back() as Control).visible = false


func _apply_free_placement(screen: Vector2) -> void:
	for label in _lines.get_children():
		(label as Control).visible = true
	var occupied: Array = occupied_provider.call(screen) if occupied_provider.is_valid() else []
	for w in WIDTHS:
		var sz := make_panel_size(float(w))
		var spot = make_free_position(occupied, sz, screen)
		if spot != null:
			_apply_rect(Rect2(spot, sz), float(w))
			return
	var narrow := make_panel_size(float(WIDTHS.back()))
	_apply_rect(Rect2(Vector2(screen.x - narrow.x - EDGE, EDGE), narrow), float(WIDTHS.back()))


## The panel's size at width `w`: its lines wrapped to that width.
func make_panel_size(w: float) -> Vector2:
	_apply_width(w)
	return Vector2(w, get_combined_minimum_size().y)


func _apply_rect(r: Rect2, w: float) -> void:
	_apply_width(w)
	placed_rect = r
	position = r.position
	size = r.size


func _apply_width(w: float) -> void:
	_width = w
	custom_minimum_size = Vector2(w, 0)
	for label in _lines.get_children():
		(label as Control).custom_minimum_size = Vector2(w - EDGE * 2.0, 0)


## The first spot for a panel of `panel_size` clear of `occupied`, from the top-right corner downwards, column by
## column to the left; null when none.
static func make_free_position(occupied: Array, panel_size: Vector2, screen: Vector2) -> Variant:
	var x := screen.x - panel_size.x - EDGE
	while x >= EDGE:
		var y := EDGE
		while y + panel_size.y <= screen.y - EDGE:
			if ChatPlacement.is_clear(Rect2(Vector2(x, y), panel_size), occupied):
				return Vector2(x, y)
			y += SEARCH_STEP
		x -= SEARCH_STEP
	return null


## Host of a LAN mission: the lines go to every client when they change, and again every RESEND_SECONDS for
## pilots who joined late (battle effect "objectives").
func _send_to_clients(lines: Array, elapsed: float) -> void:
	if battle.mission == null or not Net.is_online() or not multiplayer.is_server():
		return
	_resend_t -= elapsed
	if lines == _sent and _resend_t > 0.0:
		return
	_sent = lines.duplicate(true)
	_resend_t = RESEND_SECONDS
	battle.fx("objectives", [_sent], true)


## Client: the host's objective lines (battle effect "objectives").
func apply_host_lines(lines: Array) -> void:
	_host_lines = lines.duplicate(true)
	_refresh_t = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(TOGGLE_ACTION) and event.is_action_pressed(TOGGLE_ACTION) and not ChatFocus.open:
		toggle()


## Shows / hides the panel and remembers it (DisplaySettings).
func toggle() -> void:
	visible = not visible
	DisplaySettings.apply_objectives_panel(visible)


## Shows `lines` ([{text, done}]); nothing is rebuilt while they stay the same. No lines: the panel hides itself
## until there are some.
func apply_lines(lines: Array) -> void:
	modulate.a = 1.0 if not lines.is_empty() else 0.0
	if lines == _shown:
		return
	_shown = lines.duplicate(true)
	_place_t = 0.0
	for c in _lines.get_children():
		c.queue_free()
	for line in lines:
		var done := bool(line.get("done", false))
		var mark := "" if bool(line.get("info", false)) else (DONE_MARK if done else OPEN_MARK)   # info: a state line, no box
		var label := Widgets.label(mark + str(line.get("text", "")), "HudDoneLine" if done else "HudLine")
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(_width - EDGE * 2.0, 0)
		_lines.add_child(label)


## Number of lines shown (tests).
func line_count() -> int:
	return _shown.size()


## The lines shown (tests).
func shown_lines() -> Array:
	return _shown.duplicate(true)


## True when the lines came from the host (tests).
func uses_host_lines() -> bool:
	return _host_lines != null


static func _make_toggle_hint() -> String:
	if not InputMap.has_action(TOGGLE_ACTION):
		return ""
	return "   (%s: hide)" % BindingText.make_action_bindings(TOGGLE_ACTION).get_slice(BindingText.SEPARATOR, 0)

class_name ItemTooltip
extends PanelContainer
## The detail plate of a store entry or loadout row (Operator Setup, docs/design/lobby_loadout_economy.md §6).
## One instance per screen, added once; every item control is registered with watch():
##   mouse hover        shows it at once, leaving hides it
##   keyboard / pad     focus shows it after FOCUS_DELAY_S; losing focus hides it
##   menu_info (F1, Y)  on the focused item pins it: the plate stays, following focus, until menu_info again
## It takes plain data from a Callable, never economy classes. The data Dictionary:
##   {title, subtitle, lines: [String], price: String, warning: String}   (every key optional)

signal pin_changed(pinned: bool)

const FOCUS_DELAY_S := 0.4
const MARGIN := 8

var target: Control = null
var pinned := false
var _providers := {}   # target instance id -> Callable returning the data Dictionary
var _box: VBoxContainer
var _timer: Timer


func _init() -> void:
	theme_type_variation = "Tooltip"
	top_level = true
	z_index = 100
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_box = VBoxContainer.new()
	_box.theme_type_variation = "TightColumn"
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = FOCUS_DELAY_S
	add_child(_timer)


## Shows `provide.call() -> Dictionary` for `control` on hover, focus (delayed) and pin.
func watch(control: Control, provide: Callable) -> void:
	_providers[control.get_instance_id()] = provide
	control.mouse_entered.connect(_show_for.bind(control))
	control.mouse_exited.connect(_on_left.bind(control))
	control.focus_entered.connect(_on_focused.bind(control))
	control.focus_exited.connect(_on_left.bind(control))
	control.gui_input.connect(_on_item_input.bind(control))
	control.tree_exiting.connect(_forget.bind(control))


func is_shown_for(control: Control) -> bool:
	return visible and target == control


## Shows the plate for `control` now (hover path; also used by a screen that wants it open).
func show_item(control: Control, data: Dictionary) -> void:
	target = control
	_fill(data)
	visible = true
	reset_size()
	_place_near(control)


func apply_hide() -> void:
	_timer.stop()
	pinned = false
	visible = false
	target = null


## Pins or unpins the plate of the shown item.
func apply_pin(on: bool) -> void:
	if on == pinned or (on and not visible):
		return
	pinned = on
	pin_changed.emit(pinned)


## The lines of the plate for `data`, for tests and text-only readers.
static func make_lines(data: Dictionary) -> Array:
	var out := []
	for key in ["title", "subtitle"]:
		if str(data.get(key, "")) != "":
			out.append(str(data[key]))
	out.append_array(data.get("lines", []))
	for key in ["price", "warning"]:
		if str(data.get(key, "")) != "":
			out.append(str(data[key]))
	return out


func _fill(data: Dictionary) -> void:
	for child in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	if str(data.get("title", "")) != "":
		_add_line(str(data.title), "SectionLabel")
	if str(data.get("subtitle", "")) != "":
		_add_line(str(data.subtitle), "DimLabel")
	for line in data.get("lines", []):
		_add_line(str(line), "")
	if str(data.get("price", "")) != "":
		_add_line(str(data.price), "StatusLabel")
	if str(data.get("warning", "")) != "":
		_add_line(str(data.warning), "BadgeNotAllowed")


func _add_line(text: String, variation: String) -> void:
	var l := Widgets.label(text, variation)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_child(l)


## Below the item, flipped above or shifted left when it would leave the viewport.
func _place_near(control: Control) -> void:
	var view := get_viewport_rect().size
	var anchor := control.get_global_rect()
	var spot := Vector2(anchor.position.x, anchor.end.y + MARGIN)
	if spot.y + size.y > view.y:
		spot.y = anchor.position.y - size.y - MARGIN
	spot.x = clampf(spot.x, 0.0, maxf(0.0, view.x - size.x))
	spot.y = maxf(0.0, spot.y)
	global_position = spot


func _show_for(control: Control) -> void:
	var provide: Callable = _providers.get(control.get_instance_id(), Callable())
	if provide.is_valid():
		show_item(control, provide.call())


func _on_focused(control: Control) -> void:
	_timer.stop()
	if pinned:
		_show_for(control)
		apply_pin(true)
		return
	for c in _timer.timeout.get_connections():
		_timer.timeout.disconnect(c.callable)
	_timer.timeout.connect(_show_for.bind(control), CONNECT_ONE_SHOT)
	_timer.start()


func _on_left(control: Control) -> void:
	if target == control or _timer.time_left > 0.0:
		_timer.stop()
		if not pinned:
			apply_hide()


func _on_item_input(event: InputEvent, control: Control) -> void:
	if not UiActions.is_pressed(event, "menu_info"):
		return
	control.accept_event()
	if pinned and target == control:
		apply_pin(false)
		return
	_show_for(control)
	apply_pin(true)


func _forget(control: Control) -> void:
	_providers.erase(control.get_instance_id())
	if target == control:
		apply_hide()

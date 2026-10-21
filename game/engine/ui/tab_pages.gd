class_name TabPages
extends VBoxContainer
## A row of tab buttons over one page at a time: the shared tab widget for screens (docs/CODING_STANDARDS.md section 3).
## Mouse clicks a tab; keyboard and pad flip pages with `menu_tab_prev` / `menu_tab_next` (pad LB / RB) from anywhere
## on the screen. Pages are plain VBoxContainers the screen fills; `page(id)` returns one.

signal tab_changed(id: String)

var current := ""
var _bar: HBoxContainer
var _buttons := {}
var _pages := {}
var _order: Array[String] = []


func _init() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bar = HBoxContainer.new()
	add_child(_bar)


## Adds a tab and returns its (empty) page.
func add_page(id: String, label: String) -> VBoxContainer:
	var button := Button.new()
	button.theme_type_variation = "TabButton"
	button.text = label
	button.toggle_mode = true
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(apply_tab.bind(id))
	_bar.add_child(button)
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.visible = false
	add_child(box)
	_buttons[id] = button
	_pages[id] = box
	_order.append(id)
	return box


func page(id: String) -> VBoxContainer:
	return _pages.get(id)


func make_tab_button(id: String) -> Button:
	return _buttons.get(id)


func apply_tab(id: String) -> void:
	if not _pages.has(id):
		return
	current = id
	for t in _order:
		(_pages[t] as Control).visible = t == id
		(_buttons[t] as Button).set_pressed_no_signal(t == id)
	tab_changed.emit(id)


func apply_step(direction: int) -> void:
	if _order.is_empty():
		return
	var at := maxi(_order.find(current), 0)
	apply_tab(_order[posmod(at + direction, _order.size())])
	(_buttons[current] as Button).grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if UiActions.is_pressed(event, "menu_tab_next"):
		apply_step(1)
	elif UiActions.is_pressed(event, "menu_tab_prev"):
		apply_step(-1)
	else:
		return
	get_viewport().set_input_as_handled()

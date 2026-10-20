class_name SlotTabs
extends HBoxContainer
## The character slots as tabs across the top of Operator Setup. Click / accept selects a slot; right click or pad X
## (menu_secondary) renames it in place (Enter keeps, Esc cancels); LB / RB (menu_tab_prev / next) step through them,
## which the screen routes here with apply_step.

var _state: OperatorState
var _tabs: Array[Button] = []
var _editor: LineEdit = null
var _editing := -1


func _init(state: OperatorState) -> void:
	_state = state


## Rebuilds the tabs from the profile's slots (names, the active one pressed).
func refresh() -> void:
	var focus_index := _make_focused_index()
	_stop_editing()
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_tabs.clear()
	var group := ButtonGroup.new()
	for s in _state.profile.slots:
		var slot := s as CharacterSlot
		var tab := Button.new()
		tab.theme_type_variation = "TabButton"
		tab.toggle_mode = true
		tab.button_group = group
		tab.text = slot.label
		tab.custom_minimum_size = Vector2(Widgets.metric("button_width") * 0.5, Widgets.metric("row_height"))
		tab.set_pressed_no_signal(slot.index == _state.profile.active_slot)
		tab.pressed.connect(_state.apply_select_slot.bind(slot.index))
		tab.gui_input.connect(_on_tab_input.bind(slot.index))
		add_child(tab)
		_tabs.append(tab)
	if focus_index >= 0 and focus_index < _tabs.size():
		_tabs[focus_index].grab_focus.call_deferred()


func make_tabs() -> Array[Control]:
	var out: Array[Control] = []
	for t in _tabs:
		out.append(t)
	return out


func find_active_tab() -> Button:
	return _tabs[clampi(_state.profile.active_slot, 0, _tabs.size() - 1)] if not _tabs.is_empty() else null


## LB / RB: the next (+1) or previous (-1) slot, wrapping.
func apply_step(direction: int) -> void:
	var n := _state.profile.slots.size()
	_state.apply_select_slot((_state.profile.active_slot + direction + n) % n)


func is_editing() -> bool:
	return _editing >= 0


## Starts renaming slot `i`: a text field replaces the tab until Enter or Esc.
func apply_edit(i: int) -> void:
	if i < 0 or i >= _tabs.size() or is_editing():
		return
	_editing = i
	_editor = LineEdit.new()
	_editor.text = _state.profile.slots[i].label
	_editor.max_length = CharacterSlot.MAX_LABEL
	_editor.custom_minimum_size = _tabs[i].custom_minimum_size
	_editor.text_submitted.connect(_finish_edit)
	_editor.gui_input.connect(_on_editor_input)
	_tabs[i].visible = false
	add_child(_editor)
	move_child(_editor, _tabs[i].get_index())
	_editor.grab_focus.call_deferred()
	_editor.select_all.call_deferred()


func _on_tab_input(event: InputEvent, i: int) -> void:
	if RowButton.is_secondary(event):
		accept_event()
		apply_edit(i)


func _on_editor_input(event: InputEvent) -> void:
	if UiActions.is_back(event):
		_editor.accept_event()
		get_viewport().set_input_as_handled()
		_cancel_edit()


func _finish_edit(text: String) -> void:
	var i := _editing
	_stop_editing()
	_state.apply_rename_slot(i, text)


func _cancel_edit() -> void:
	var i := _editing
	_stop_editing()
	if i >= 0 and i < _tabs.size():
		_tabs[i].grab_focus()


func _stop_editing() -> void:
	if _editor != null and is_instance_valid(_editor):
		remove_child(_editor)
		_editor.queue_free()
	if _editing >= 0 and _editing < _tabs.size():
		_tabs[_editing].visible = true
	_editor = null
	_editing = -1


## The index of the tab (or the rename field) that has the focus, else -1: it gets the focus back after a rebuild.
func _make_focused_index() -> int:
	if not is_inside_tree():
		return -1
	var focus := get_viewport().gui_get_focus_owner()
	if focus == _editor and _editor != null:
		return _editing
	return _tabs.find(focus)

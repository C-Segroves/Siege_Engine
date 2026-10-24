class_name StashRow
extends RowButton
## One stack of the stash overview. A sellable stack opens its Sell menu (Sell 1 / Sell stack / Sell all / all of the kind,
## each with its price, then a confirm) on right click, pad X (menu_secondary), the Menu key or Shift+F10.

var _state: OperatorState
var _id := ""


static func make(state: OperatorState, id: String, title: String, detail: String) -> StashRow:
	var r := StashRow.new()
	r._state = state
	r._id = id
	r.add_text(title, "", true)
	r.add_text(detail, "DimLabel")
	r.tooltip_text = "Right click / X: sell" if state.can_sell(id) else ""
	return r


func stack_id() -> String:
	return _id


func _gui_input(event: InputEvent) -> void:
	if is_secondary(event) or _is_menu_key(event):
		accept_event()
		open_menu()


static func _is_menu_key(event: InputEvent) -> bool:
	var k := event as InputEventKey
	return k != null and k.pressed and not k.echo and (k.keycode == KEY_MENU or (k.keycode == KEY_F10 and k.shift_pressed))


## Opens the sell menu at the row (nothing when the stack is not for sale).
func open_menu() -> PopupMenu:
	var options := _state.make_sell_options(_id)
	if options.is_empty():
		_state.apply_status("Not for sale")
		return null
	var menu := PopupMenu.new()
	for i in options.size():
		menu.add_item(str(options[i].label), i)
	menu.id_pressed.connect(func(i: int) -> void: _state.request_sell_option(_id, options[i]))
	menu.popup_hide.connect(func() -> void:
		menu.queue_free()
		if is_inside_tree():
			grab_focus())
	add_child(menu)
	menu.popup(Rect2i(Vector2i(global_position + Vector2(size.x * 0.5, size.y)), Vector2i.ZERO))
	return menu

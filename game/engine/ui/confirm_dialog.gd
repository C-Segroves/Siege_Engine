class_name ConfirmDialog
extends PanelContainer
## Modal yes/no question drawn over the current screen (dark shade, centred panel). Keyboard and
## gamepad focus stays inside the dialog; `menu_back` or Cancel closes it.
##   ConfirmDialog.ask(host, "Remove ...?", on_confirm, "Remove", Widgets.DANGER)
## A destructive question (DANGER) focuses Cancel first. add_choice() adds a third answer
## (e.g. "Clear" next to "Swap").

signal closed

var confirm_button: Button
var cancel_button: Button
var _buttons: HBoxContainer
var _return_focus: Control


static func ask(host: Control, message: String, on_confirm: Callable, confirm_text := "Confirm",
		confirm_variation := Widgets.PRIMARY) -> ConfirmDialog:
	var d := ConfirmDialog.new()
	d._build(message, confirm_text, confirm_variation)
	d.confirm_button.pressed.connect(func() -> void:
		d.close()
		on_confirm.call())
	d._return_focus = host.get_viewport().gui_get_focus_owner()
	host.add_child(d)
	var first := d.cancel_button if confirm_variation == Widgets.DANGER else d.confirm_button
	first.grab_focus.call_deferred()
	return d


## Adds another answer left of the confirm button: closes the dialog, then calls `on_choice`.
func add_choice(text: String, on_choice: Callable, variation := "") -> Button:
	var b := Widgets.button(text, func() -> void:
		close()
		on_choice.call(), variation)
	_buttons.add_child(b)
	_buttons.move_child(b, confirm_button.get_index())
	_trap_focus()
	return b


func close() -> void:
	if is_instance_valid(_return_focus) and _return_focus.is_visible_in_tree():
		_return_focus.grab_focus()
	closed.emit()
	queue_free()


func _build(message: String, confirm_text: String, confirm_variation: String) -> void:
	theme_type_variation = "ModalShade"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var center := CenterContainer.new()
	add_child(center)
	var panel := PanelContainer.new()
	panel.theme_type_variation = "ModalPanel"
	center.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	var text := Widgets.label(message)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size = Vector2(Widgets.metric("button_width") * 2, 0)
	box.add_child(text)
	cancel_button = Widgets.button("Cancel", close)
	confirm_button = Widgets.button(confirm_text, func() -> void: pass, confirm_variation)
	_buttons = Widgets.row([cancel_button, confirm_button])
	_buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(_buttons)
	_trap_focus()


func _trap_focus() -> void:
	var chain: Array[Control] = []
	for b in _buttons.get_children():
		chain.append(b as Control)
	UiActions.link_horizontal(chain)
	UiActions.link_vertical(chain)


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event):
		get_viewport().set_input_as_handled()
		close()

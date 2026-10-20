class_name ModalSheet
extends PanelContainer
## A full-screen modal sheet drawn over the current screen: Operator Setup and the lobby's dialogs.
## A dark shade, a panel filling the screen with a title row (title, optional trailing widget such as a
## CreditsBadge), a body to fill and a footer (Back left, primary action bottom-right).
##   var sheet := ModalSheet.open(host, "OPERATOR SETUP")
##   sheet.body.add_child(...); sheet.set_primary("Done", on_done)
## Input: `menu_back` (Esc, pad B) presses Back / closes; `menu_primary` (Ctrl+Enter, pad Start) presses the
## primary action. Focus is trapped inside the sheet (a control outside it that takes focus is pulled back to
## the first control in the sheet) and returns to the previous owner on close.

signal closed

var title_bar: HBoxContainer
var body: VBoxContainer
var back_button: Button
var primary_button: Button
var is_open := true
var _title: Label
var _status: Label
var _return_focus: Control


## Adds a sheet to `host` (a screen Control) and focuses its first control.
static func open(host: Control, title: String) -> ModalSheet:
	var sheet := ModalSheet.new()
	sheet._return_focus = host.get_viewport().gui_get_focus_owner()
	sheet.set_title(title)
	host.add_child(sheet)
	return sheet


func _init() -> void:
	theme_type_variation = "ModalShade"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var panel := PanelContainer.new()
	panel.theme_type_variation = "ModalPanel"
	add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	title_bar = HBoxContainer.new()
	_title = Widgets.label("", "HeaderLabel")
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(_title)
	column.add_child(title_bar)
	body = VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)
	column.add_child(_build_footer())


func _ready() -> void:
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	_link_footer()
	focus_first.call_deferred()


func set_title(text: String) -> void:
	_title.text = text


func set_status(text: String) -> void:
	_status.text = text


## Adds a widget at the right end of the title row (a CreditsBadge).
func add_title_widget(widget: Control) -> void:
	title_bar.add_child(widget)


## Back button text and action; with no `on_back` it just closes the sheet.
func set_back(text: String, on_back := Callable()) -> Button:
	back_button.text = text
	_reconnect(back_button, on_back if on_back.is_valid() else close)
	return back_button


func set_primary(text: String, on_primary: Callable) -> Button:
	primary_button.text = text
	primary_button.visible = true
	_reconnect(primary_button, on_primary)
	_link_footer()
	return primary_button


## Moves focus to the first focusable control of the body, else the footer.
func focus_first() -> void:
	var chain := UiActions.focusables(self)
	if not chain.is_empty():
		chain[0].grab_focus()


func close() -> void:
	if not is_open:
		return
	is_open = false
	if get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
		get_viewport().gui_focus_changed.disconnect(_on_focus_changed)
	if is_instance_valid(_return_focus) and _return_focus.is_visible_in_tree():
		_return_focus.grab_focus()
	closed.emit()
	queue_free()


func _build_footer() -> Control:
	var row := HBoxContainer.new()
	_status = Widgets.paragraph("", "StatusLabel")
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_status)
	back_button = Widgets.button("Back", close)
	row.add_child(back_button)
	primary_button = Widgets.button("", func() -> void: pass, Widgets.PRIMARY)
	primary_button.visible = false
	row.add_child(primary_button)
	return row


func _reconnect(b: Button, on_pressed: Callable) -> void:
	for c in b.pressed.get_connections():
		b.pressed.disconnect(c.callable)
	b.pressed.connect(on_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event):
		get_viewport().set_input_as_handled()
		back_button.pressed.emit()
	elif UiActions.is_pressed(event, "menu_primary") and primary_button.visible and not primary_button.disabled:
		get_viewport().set_input_as_handled()
		primary_button.pressed.emit()


## A control outside the sheet that takes focus (a screen behind it, or a dialog above it is fine) is pulled back.
func _on_focus_changed(control: Control) -> void:
	if is_open and control != null and not is_ancestor_of(control) and not _is_above(control):
		focus_first()


## True for a control in a node added after this sheet under the same parent (a ConfirmDialog opened over it).
func _is_above(control: Control) -> bool:
	var parent := get_parent()
	if parent == null:
		return false
	for sibling in parent.get_children().slice(get_index() + 1):
		if sibling == control or sibling.is_ancestor_of(control):
			return true
	return false


## Back and the primary action side by side: left / right walk between them.
func _link_footer() -> void:
	var footer: Array[Control] = [back_button]
	if primary_button.visible:
		footer.append(primary_button)
	UiActions.link_horizontal(footer)

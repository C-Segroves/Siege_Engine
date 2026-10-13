class_name ScreenFrame
extends Control
## The frame every app screen is built in: title bar, scrolling content column, optional side
## panel (the 3D hangar takes the right half wherever a Herc is chosen) and a footer with the
## status line, Back and the primary action bottom-right.
##
##   set_title(title, subtitle)          title bar text
##   content                             VBoxContainer to add the screen's widgets to
##   show_hangar() -> HangarView         right-half 3D hangar (created on first call); hide_hangar()
##   set_back(text, on_back)             footer Back button; `menu_back` presses it
##   set_primary(text, on_primary)       footer primary action (bottom-right)
##   set_status(text)                    footer status line
##   use_shaded_background()             dim the scene behind instead of hiding it (in-battle menus)
##   focus_primary_first                 open with the primary action focused (results screens)
## Focus: the content's controls and the footer buttons are linked top-to-bottom for keyboard and
## gamepad; the first content control takes focus when the screen opens. The chain is rebuilt
## whenever controls are added or removed under the frame.

const HANGAR_HINT := "orbit: drag / right stick    zoom: wheel / triggers    reset: double-click"

var content: VBoxContainer
var hangar: HangarView
var back_button: Button
var primary_button: Button
## Focus the primary action (not the first content control) when the screen opens.
var focus_primary_first := false

var _background: PanelContainer
var _title: Label
var _subtitle: Label
var _status: Label
var _scroll: ScrollContainer
var _side: Control
var _footer_row: HBoxContainer
var _focus_dirty := false
var _opened := false


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_background = PanelContainer.new()
	_background.theme_type_variation = "ScreenBackground"
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_background)
	var column := VBoxContainer.new()
	column.theme_type_variation = "TightColumn"
	_background.add_child(column)
	column.add_child(_build_title_bar())
	column.add_child(_build_body())
	column.add_child(_build_footer())


func _ready() -> void:
	get_tree().node_added.connect(_on_tree_changed)
	get_tree().node_removed.connect(_on_tree_changed)
	_refresh_focus.call_deferred()


# ------------------------------------------------------------------ public API

func set_title(title: String, subtitle := "") -> void:
	_title.text = title
	_subtitle.text = subtitle


func set_status(text: String) -> void:
	_status.text = text


func status_text() -> String:
	return _status.text


func set_back(text: String, on_back: Callable) -> Button:
	back_button.text = text
	back_button.visible = true
	_reconnect(back_button, on_back)
	return back_button


func set_primary(text: String, on_primary: Callable) -> Button:
	primary_button.text = text
	primary_button.visible = true
	_reconnect(primary_button, on_primary)
	return primary_button


## The scene behind shows through a shade (the in-battle menu over the running battle).
func use_shaded_background() -> void:
	_background.theme_type_variation = "ModalShade"


## The right-half 3D hangar (shared by every Herc selection screen).
func show_hangar() -> HangarView:
	if hangar == null:
		hangar = HangarView.new()
		hangar.set_anchors_preset(Control.PRESET_FULL_RECT)
		_side.add_child(hangar)
		var hint := Widgets.label(HANGAR_HINT, "DimLabel")
		hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
		hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hangar.add_child(hint)
	_side.visible = true
	return hangar


## Takes the right-half hangar away again (a screen whose choice no longer shows a Herc).
func hide_hangar() -> void:
	_side.visible = false


## Moves focus to the first content control (or the primary action).
func focus_first() -> void:
	if focus_primary_first and primary_button.visible and not primary_button.disabled:
		primary_button.grab_focus()
		return
	var chain := _focus_chain()
	if not chain.is_empty():
		chain[0].grab_focus()


# ------------------------------------------------------------------ layout

func _build_title_bar() -> Control:
	var bar := PanelContainer.new()
	bar.theme_type_variation = "TitleBar"
	var row := HBoxContainer.new()
	bar.add_child(row)
	_title = Widgets.label("", "HeaderLabel")
	row.add_child(_title)
	_subtitle = Widgets.label("", "SubtitleLabel")
	_subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_subtitle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_subtitle.clip_text = true
	row.add_child(_subtitle)
	return bar


func _build_body() -> Control:
	var body := PanelContainer.new()
	body.theme_type_variation = "ScreenBody"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var split := HBoxContainer.new()
	body.add_child(split)
	_scroll = ScrollContainer.new()
	_scroll.theme_type_variation = "ContentPanel"
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	split.add_child(_scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(content)
	_side = Control.new()
	_side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side.visible = false
	split.add_child(_side)
	return body


func _build_footer() -> Control:
	var bar := PanelContainer.new()
	bar.theme_type_variation = "FooterBar"
	_footer_row = HBoxContainer.new()
	bar.add_child(_footer_row)
	_status = Widgets.paragraph("", "StatusLabel")
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_footer_row.add_child(_status)
	back_button = Widgets.button("Back", func() -> void: pass)
	back_button.visible = false
	_footer_row.add_child(back_button)
	primary_button = Widgets.button("", func() -> void: pass, Widgets.PRIMARY)
	primary_button.visible = false
	_footer_row.add_child(primary_button)
	return bar


func _reconnect(b: Button, on_pressed: Callable) -> void:
	for c in b.pressed.get_connections():
		b.pressed.disconnect(c.callable)
	b.pressed.connect(on_pressed)


# ------------------------------------------------------------------ input and focus

func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event) and back_button.visible and not back_button.disabled:
		get_viewport().set_input_as_handled()
		back_button.pressed.emit()


func _on_tree_changed(node: Node) -> void:
	if node != self and is_ancestor_of(node) and not _focus_dirty:
		_focus_dirty = true
		_refresh_focus.call_deferred()


func _refresh_focus() -> void:
	_focus_dirty = false
	if not is_inside_tree():
		return
	var chain := _focus_chain()
	UiActions.link_vertical(chain)
	_link_footer_up(UiActions.focusables(content))
	var owner_control := get_viewport().gui_get_focus_owner()
	if not _opened or owner_control == null or not is_ancestor_of(owner_control):
		_opened = true
		focus_first()


## Footer buttons sit side by side: left/right between them, up returns to the last content control.
func _link_footer_up(content_chain: Array[Control]) -> void:
	var footer := _footer_buttons()
	UiActions.link_horizontal(footer)
	for b in footer:
		var above: Control = content_chain.back() if not content_chain.is_empty() else b
		b.focus_neighbor_top = b.get_path_to(above)
		b.focus_neighbor_bottom = b.get_path_to(b)


func _focus_chain() -> Array[Control]:
	var chain := UiActions.focusables(content)
	var footer := _footer_buttons()
	footer.reverse()   # primary first: Enter at the end of a form goes to the main action
	chain.append_array(footer)
	return chain


func _footer_buttons() -> Array[Control]:
	var out: Array[Control] = []
	for b in [back_button, primary_button]:
		if b.visible and not b.disabled:
			out.append(b)
	return out

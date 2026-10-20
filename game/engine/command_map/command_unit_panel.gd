class_name CommandUnitPanel
extends VBoxContainer
## The command map's unit panel: a scrollable list of the units the player can command, one row each with the unit's
## name, its vehicle and two health bars (armour, shields). A plain click (or ui_accept, pad A) selects only that
## unit, so the order goes to that individual; shift- or ctrl-click (pad: ui_select) adds it to / removes it from the
## selection; "All" selects every unit. Pad: the shoulder buttons step through the units (step()), Y selects all.
## Rows are the shared theme's buttons and progress bars. selection_changed(ids) tells the map.

signal selection_changed(ids: Array)

const LIST_HEIGHT := 230
const BAR_HEIGHT := 8
const DOWN_TEXT := "DOWN"
const ALL_TEXT := "All units"
const REFRESH_SECONDS := 0.25

var selected: Array = []              # net ids
var _units: Array = []                # the units, list order
var _rows := {}                       # net id -> {button, armour, shield, unit}
var _all_button: Button
var _list: VBoxContainer
var _clock := 0.0


func _init() -> void:
	_all_button = Widgets.button(ALL_TEXT, apply_all)
	add_child(_all_button)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, LIST_HEIGHT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)


## Lists `units` (nodes with net_id and display_name); the first is selected.
func setup(units: Array) -> void:
	_units = units
	for c in _list.get_children():
		c.queue_free()
	_rows.clear()
	selected.clear()
	if units.is_empty():
		_list.add_child(Widgets.label("Nobody to command.", "DimLabel"))
		return
	for u in units:
		_list.add_child(_build_row(u))
	selected = [int(units[0].net_id)]
	_apply_state()


func _build_row(u: Node) -> Control:
	var id := int(u.net_id)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var b := Widgets.small_button("", func() -> void: apply_click(id, Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_CTRL)))
	b.toggle_mode = true
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_focus_color", Color.WHITE)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.gui_input.connect(func(e: InputEvent) -> void:
		if e.is_action_pressed("ui_select"):
			apply_click(id, true)
			b.accept_event())
	box.add_child(b)
	var bars := HBoxContainer.new()
	var armour := _build_bar()
	var shield := _build_bar()
	bars.add_child(armour)
	bars.add_child(shield)
	box.add_child(bars)
	_rows[id] = {"button": b, "armour": armour, "shield": shield, "unit": u}
	_refresh_row(id)
	return box


func _build_bar() -> ProgressBar:
	var p := ProgressBar.new()
	p.min_value = 0.0
	p.max_value = 1.0
	p.step = 0.01
	p.show_percentage = false
	p.custom_minimum_size = Vector2(0, BAR_HEIGHT)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## A click: `additive` toggles the unit in the selection, else it becomes the only one selected.
func apply_click(id: int, additive: bool) -> void:
	if not _rows.has(id):
		return
	if additive:
		if selected.has(id):
			selected.erase(id)
		else:
			selected.append(id)
	else:
		selected = [id]
	_apply_state()


func apply_all() -> void:
	selected = _rows.keys()
	_apply_state()


## Selects only the unit `delta` rows after the current (first) selected one, wrapping (pad shoulder buttons).
func step(delta: int) -> void:
	if _units.is_empty():
		return
	var at := 0
	if not selected.is_empty():
		for k in _units.size():
			if int(_units[k].net_id) == int(selected[0]):
				at = k
	apply_click(int(_units[posmod(at + delta, _units.size())].net_id), false)


func is_all_selected() -> bool:
	return not _rows.is_empty() and selected.size() == _rows.size()


func count() -> int:
	return _rows.size()


func _apply_state() -> void:
	for id in _rows:
		(_rows[id].button as Button).set_pressed_no_signal(selected.has(id))
	selection_changed.emit(selected.duplicate())


func _process(delta: float) -> void:
	_clock += delta
	if _clock >= REFRESH_SECONDS:
		_clock = 0.0
		for id in _rows:
			_refresh_row(id)


func _refresh_row(id: int) -> void:
	var r: Dictionary = _rows[id]
	var u: Node = r.unit
	if not is_instance_valid(u):
		return
	var alive := bool(u.get("alive"))
	(r.button as Button).text = "%s  -  %s%s" % [str(u.get("display_name")), TargetInfo.make_type_name(u),
		"" if alive else "  [%s]" % DOWN_TEXT]
	(r.armour as ProgressBar).value = TargetInfo.make_integrity(u) if alive else 0.0
	(r.shield as ProgressBar).value = TargetInfo.make_shield_share(u) if alive else 0.0
	(r.shield as ProgressBar).visible = TargetInfo.make_shield_share(u) > 0.0 or (u is Herc and (u as Herc).shield_max > 0.0)

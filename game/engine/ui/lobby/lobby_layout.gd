class_name LobbyLayout
extends VBoxContainer
## Arranges the lobby's panes (docs/design/lobby_loadout_economy.md sections 5.1 and 5.2). Wide: Game Options and the
## Operator Setup block on the left, the carousel / others list / chat in the middle, the task list on the right. Narrow
## (content under Siege/narrow_width, 900 px): one pane at a time behind a tab bar - Options, Squad, Tasks, Chat - which
## `menu_tab_prev` / `menu_tab_next` (pad LB / RB) flip when focus is on the bar. The panes are the same nodes in both:
## switching only moves them.

signal tab_changed(tab: String)

const OPTIONS := "options"
const SQUAD := "squad"
const TASKS := "tasks"
const CHAT := "chat"
const TAB_ORDER := [OPTIONS, SQUAD, TASKS, CHAT]
const TAB_LABELS := {OPTIONS: "Options", SQUAD: "Squad", TASKS: "Tasks", CHAT: "Chat"}
const LEFT_RATIO := 1.0
const CENTRE_RATIO := 1.5
const RIGHT_RATIO := 1.0

var narrow := false
var tab := SQUAD
var tab_buttons := {}
var panes := {}     # name -> Control: options, setup, carousel, list, tasks, chat
var _tab_bar: HBoxContainer
var _columns: HBoxContainer
var _left: VBoxContainer
var _centre: VBoxContainer
var _right: VBoxContainer
var _tab_boxes := {}
var _arranged := false


func _init() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_bar = HBoxContainer.new()
	for t in TAB_ORDER:
		var b := Button.new()
		b.theme_type_variation = "TabButton"
		b.text = TAB_LABELS[t]
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(apply_tab.bind(t))
		tab_buttons[t] = b
		_tab_bar.add_child(b)
	add_child(_tab_bar)
	_columns = HBoxContainer.new()
	_columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left = _make_column(LEFT_RATIO)
	_centre = _make_column(CENTRE_RATIO)
	_right = _make_column(RIGHT_RATIO)
	add_child(_columns)
	for t in TAB_ORDER:
		var box := VBoxContainer.new()
		box.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_tab_boxes[t] = box
		add_child(box)


func _make_column(ratio: float) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_stretch_ratio = ratio
	_columns.add_child(column)
	return column


## Registers the panes (options, setup, carousel, list, tasks, chat) and lays them out.
func add_panes(p: Dictionary) -> void:
	panes = p
	_arrange()


func apply_narrow(on: bool) -> void:
	if on == narrow and _arranged:
		return
	narrow = on
	_arrange()


## Shows or hides the right column and the Tasks tab after the task pane's own visibility changed.
func refresh_tasks_visibility() -> void:
	_show_tab()


func apply_tab(t: String) -> void:
	tab = t
	_show_tab()
	tab_changed.emit(t)


## Steps the narrow tab bar by `delta`.
func step_tab(delta: int) -> void:
	apply_tab(TAB_ORDER[posmod(TAB_ORDER.find(tab) + delta, TAB_ORDER.size())])


func _arrange() -> void:
	if panes.is_empty():
		return
	_arranged = true
	_tab_bar.visible = narrow
	_columns.visible = not narrow
	if narrow:
		_place([panes.options], _tab_boxes[OPTIONS])
		_place([panes.carousel, panes.setup, panes.list], _tab_boxes[SQUAD])
		_place([panes.tasks], _tab_boxes[TASKS])
		_place([panes.chat], _tab_boxes[CHAT])
	else:
		_place([panes.options, panes.setup], _left)
		_place([panes.carousel, panes.list, panes.chat], _centre)
		_place([panes.tasks], _right)
	_fit_left_column()
	_show_tab()


## Wide: Game Options take the height of their rows and the Operator Setup block below them gets the rest of the column;
## narrow: the options tab scrolls on its own.
func _fit_left_column() -> void:
	var scroll := panes.options as ScrollContainer
	if scroll != null:
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO if narrow else ScrollContainer.SCROLL_MODE_DISABLED
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL if narrow else Control.SIZE_FILL
	(panes.setup as Control).size_flags_vertical = Control.SIZE_FILL if narrow else Control.SIZE_EXPAND_FILL


func _place(controls: Array, parent: Control) -> void:
	for i in controls.size():
		var c: Control = controls[i]
		if c.get_parent() != parent:
			if c.get_parent() != null:
				c.get_parent().remove_child(c)
			parent.add_child(c)
		parent.move_child(c, i)


func _show_tab() -> void:
	for t in TAB_ORDER:
		_tab_boxes[t].visible = narrow and t == tab
		(tab_buttons[t] as Button).set_pressed_no_signal(t == tab)
	var tasks_shown: bool = (panes.tasks as Control).visible
	_right.visible = not narrow and tasks_shown
	(tab_buttons[TASKS] as Button).visible = tasks_shown
	if narrow and tab == TASKS and not tasks_shown:
		tab = SQUAD
		_tab_boxes[SQUAD].visible = true
		_tab_boxes[TASKS].visible = false

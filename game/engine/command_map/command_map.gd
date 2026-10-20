class_name CommandMap
extends PanelContainer
## The command map (docs/COMMAND_MAP.md): the battlefield from above (CommandMapView) beside the units the player
## commands and the orders for what he picked. Pick a place, a nav point, a structure, a combatant or yourself on
## the map (click, or the cursor with the ui directions and ui_accept), choose units (the first is ticked on opening;
## none ticked = all), then an order: its button, or its letter from the game's own menu (CommandProvider: the original's command keys are typed
## text, like the original shell's hotkeys, docs/CODING_STANDARDS.md section 2). The Tribes 2 commander map look:
## a translucent teal panel (siege_theme ModalShade / ModalPanel and the shared widgets). menu_back, Close or the
## command_map action closes it; the battle keeps running, as in the originals. In an extraction raid the side panel also lists
## the call-ins: pick one, click its point (and direction) on the map (CommandMapCallins).

signal closed

const LAYER := 80
const LAYER_NAME := "CommandMapLayer"
const MAP_SIZE := Vector2(560, 560)
const SIDE_WIDTH := 260.0
const SIDE_SCROLLBAR := 16.0
const TOGGLE_ACTION := "command_map"

var battle: Node3D
var viewer: Node3D
var orders: CommandOrders
var view: CommandMapView
var pick: Dictionary = {}
var _orders_box: VBoxContainer
var _target_label: Label
var _status: Label
var _markers_box: VBoxContainer
var _hidden: Array = []
var _unit_panel: CommandUnitPanel
## Extraction raid: ordering call-ins on the map (null in every other battle).
var callin_order: CommandMapCallins


## Opens the command map for the local player's `unit` (his soldier or vehicle).
static func open(p_battle: Node3D, unit: Node3D) -> CommandMap:
	var m := CommandMap.new()
	m.battle = p_battle
	m.viewer = unit
	m.orders = CommandOrders.of(p_battle)
	var layer := CanvasLayer.new()
	layer.layer = LAYER
	layer.name = LAYER_NAME
	layer.add_child(m)
	p_battle.add_child(layer)
	m._build()
	m._hide_battle_ui()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	m.view.build_background()
	return m


## The open command map of `p_battle` (null when none).
static func find_open(p_battle: Node) -> CommandMap:
	var layer := p_battle.get_node_or_null(LAYER_NAME)
	return layer.get_child(0) as CommandMap if layer and layer.get_child_count() > 0 else null


func _build() -> void:
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
	box.add_child(Widgets.label(orders.provider.make_title(), "HeaderLabel"))
	var row := HBoxContainer.new()
	box.add_child(row)
	view = CommandMapView.new()
	view.custom_minimum_size = MAP_SIZE
	view.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(view)
	view.setup(battle, viewer)
	view.picked.connect(_on_picked)
	view.cancelled.connect(func() -> void: if callin_order != null: callin_order.apply_cancel())
	row.add_child(_build_side_scroll())
	_status = Widgets.label("Pick a place, a unit or yourself on the map, then an order.", "DimLabel")
	box.add_child(_status)
	var buttons := Widgets.row([Widgets.button("Close", close)])
	buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(buttons)
	view.grab_focus.call_deferred()
	_apply_first_pick.call_deferred()


## On opening: the player himself is picked when his game has orders on him ("join on me"), else nothing yet.
func _apply_first_pick() -> void:
	var me := view.make_pick(view.to_map(viewer.global_position))
	if not orders.make_menu(str(me.menu)).is_empty():
		_on_picked(me)


## The side panel in a scroll box as tall as the map: a long list of orders and call-ins scrolls, it never stretches the map.
func _build_side_scroll() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(SIDE_WIDTH + SIDE_SCROLLBAR, MAP_SIZE.y)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(_build_side())
	return scroll


func _build_side() -> VBoxContainer:
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(SIDE_WIDTH, 0)
	side.add_child(Widgets.section("Units"))
	_unit_panel = CommandUnitPanel.new()
	_unit_panel.selection_changed.connect(func(ids: Array) -> void: view.selected = ids)
	side.add_child(_unit_panel)
	_fill_units()
	callin_order = CommandMapCallins.make_for(self)
	if callin_order != null:
		view.callin_order = callin_order
		callin_order.build_panel(side)
	side.add_child(Widgets.section("My waypoints"))
	side.add_child(Widgets.button("Mark this spot  (P)", place_marker))
	_markers_box = VBoxContainer.new()
	side.add_child(_markers_box)
	_fill_markers()
	side.add_child(Widgets.section("Orders"))
	_target_label = Widgets.label("Target: none", "DimLabel")
	side.add_child(_target_label)
	_orders_box = VBoxContainer.new()
	side.add_child(_orders_box)
	return side


## Sticks a personal waypoint (PersonalWaypoints: local, on the compass) at the picked spot, else at the cursor.
func place_marker() -> bool:
	var at: Vector3 = pick.point if not pick.is_empty() else view.to_world(view.cursor)
	var ok := PersonalWaypoints.add(at)
	_status.text = "Waypoint P%d placed." % PersonalWaypoints.points.size() if ok else "Only %d waypoints: remove one first." % PersonalWaypoints.MAX
	_fill_markers()
	return ok


func _fill_markers() -> void:
	for c in _markers_box.get_children():
		c.queue_free()
	for i in PersonalWaypoints.points.size():
		_markers_box.add_child(Widgets.small_button("Remove P%d" % (i + 1), func() -> void:
			PersonalWaypoints.remove(i)
			_fill_markers()))


func _fill_units() -> void:
	_unit_panel.setup(orders.make_commandable(viewer))      # the first unit is preselected


## The units the order goes to: those selected in the unit panel, else all.
func make_recipients() -> Array:
	return view.selected if not view.selected.is_empty() else _unit_panel._rows.keys()


func _process(delta: float) -> void:
	if callin_order != null:
		callin_order.apply_frame(delta)


## The status line under the map.
func set_status(text: String) -> void:
	_status.text = text


func _on_picked(p: Dictionary) -> void:
	if callin_order != null and callin_order.is_ordering():
		callin_order.apply_click(view.to_world(view.cursor))
		return
	pick = p
	_target_label.text = "Target: %s" % str(p.name)
	for c in _orders_box.get_children():
		c.queue_free()
	for entry in orders.make_menu(str(p.menu)):
		_orders_box.add_child(Widgets.button("%s  (%s)" % [entry.label, str(entry.key).to_upper()], func() -> void: give(entry)))
	if orders.make_menu(str(p.menu)).is_empty():
		_status.text = "No orders for that target."


## Gives the chosen units order `entry` on the current pick.
func give(entry: Dictionary) -> void:
	if pick.is_empty():
		return
	var recipients := make_recipients()
	if recipients.is_empty():
		_status.text = "Nobody to command."
		return
	orders.request_order(entry, recipients, pick.point, int(pick.target), str(pick.object))
	_status.text = "%s: %d unit(s)." % [str(entry.label), recipients.size()]


## A proper modal: the battle's HUD, hints, chat and objectives hide under the map (shown again on close).
func _hide_battle_ui() -> void:
	for n in _battle_ui():
		if n.get("visible") == true:
			n.visible = false
			_hidden.append(n)


func _battle_ui() -> Array:
	var out := []
	for name in ["overlay", "hud"]:
		var n = battle.get(name)
		if n != null and n.get("visible") != null:
			out.append(n)
	return out


func close() -> void:
	for n in _hidden:
		if is_instance_valid(n):
			n.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	closed.emit()
	get_parent().queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event) and callin_order != null and callin_order.apply_cancel():
		get_viewport().set_input_as_handled()
		return
	if UiActions.is_back(event) or event.is_action_pressed(TOGGLE_ACTION):
		get_viewport().set_input_as_handled()
		close()
		return
	if _apply_unit_step(event):
		get_viewport().set_input_as_handled()
		return
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.unicode > 0:
		var letter := char(key.unicode).to_lower()
		if not pick.is_empty() and give_by_letter(letter):
			return
		if letter == "p":
			get_viewport().set_input_as_handled()
			place_marker()


## Pad: the shoulder buttons step through the units (select only that one), Y selects them all; keys: Page Up / Down.
func _apply_unit_step(event: InputEvent) -> bool:
	var pad := event as InputEventJoypadButton
	var key := event as InputEventKey
	var dir := 0
	if pad and pad.pressed:
		if pad.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			dir = 1
		elif pad.button_index == JOY_BUTTON_LEFT_SHOULDER:
			dir = -1
		elif pad.button_index == JOY_BUTTON_Y:
			_unit_panel.apply_all()
			return true
	elif key and key.pressed and not key.echo:
		dir = 1 if key.keycode == KEY_PAGEDOWN else (-1 if key.keycode == KEY_PAGEUP else 0)
	if dir == 0:
		return false
	_unit_panel.step(dir)
	return true


## The original's order letter for the current pick (true when one matched).
func give_by_letter(letter: String) -> bool:
	for entry in orders.make_menu(str(pick.menu)):
		if str(entry.key).to_lower() == letter:
			if is_inside_tree():
				get_viewport().set_input_as_handled()
			give(entry)
			return true
	return false

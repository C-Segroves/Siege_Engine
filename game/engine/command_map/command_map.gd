class_name CommandMap
extends PanelContainer
## The command map (docs/COMMAND_MAP.md): the battlefield from above (CommandMapView) beside the units the player
## commands and the orders for what he picked. Pick a place, a nav point, a structure, a combatant or yourself on
## the map (click, or the cursor with the ui directions and ui_accept), choose units (the first is ticked on opening;
## none ticked = all), then an order: its button, or its letter from the game's own menu (CommandProvider: the original's command keys are typed
## text, like the original shell's hotkeys, docs/CODING_STANDARDS.md section 2). The Tribes 2 commander map look:
## a translucent teal panel (siege_theme ModalShade / ModalPanel and the shared widgets). menu_back, Close or the
## command_map action closes it; the battle keeps running, as in the originals.

signal closed

const LAYER := 80
const LAYER_NAME := "CommandMapLayer"
const MAP_SIZE := Vector2(560, 560)
const TOGGLE_ACTION := "command_map"

var battle: Node3D
var viewer: Node3D
var orders: CommandOrders
var view: CommandMapView
var pick: Dictionary = {}
var _units: VBoxContainer
var _orders_box: VBoxContainer
var _target_label: Label
var _status: Label
var _unit_boxes := {}               # net id -> CheckBox


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
	row.add_child(view)
	view.setup(battle, viewer)
	view.picked.connect(_on_picked)
	row.add_child(_build_side())
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


func _build_side() -> VBoxContainer:
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(260, 0)
	side.add_child(Widgets.section("Units"))
	_units = VBoxContainer.new()
	side.add_child(_units)
	_fill_units()
	side.add_child(Widgets.section("Orders"))
	_target_label = Widgets.label("Target: none", "DimLabel")
	side.add_child(_target_label)
	_orders_box = VBoxContainer.new()
	side.add_child(_orders_box)
	return side


func _fill_units() -> void:
	for v in orders.make_commandable(viewer):
		var cb := Widgets.check_box(str(v.display_name), false)
		cb.toggled.connect(func(_on: bool) -> void: _sync_selection())
		_units.add_child(cb)
		_unit_boxes[int(v.net_id)] = cb
	if _unit_boxes.is_empty():
		_units.add_child(Widgets.label("Nobody to command.", "DimLabel"))
	else:
		(_unit_boxes.values()[0] as CheckBox).button_pressed = true      # the first unit is preselected
		_sync_selection()


func _sync_selection() -> void:
	view.selected = _unit_boxes.keys().filter(func(id: int) -> bool: return (_unit_boxes[id] as CheckBox).button_pressed)


## The units the order goes to: those ticked, else all.
func make_recipients() -> Array:
	return view.selected if not view.selected.is_empty() else _unit_boxes.keys()


func _on_picked(p: Dictionary) -> void:
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


func close() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	closed.emit()
	get_parent().queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event) or event.is_action_pressed(TOGGLE_ACTION):
		get_viewport().set_input_as_handled()
		close()
		return
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.unicode > 0 and not pick.is_empty():
		give_by_letter(char(key.unicode).to_lower())


## The original's order letter for the current pick (true when one matched).
func give_by_letter(letter: String) -> bool:
	for entry in orders.make_menu(str(pick.menu)):
		if str(entry.key).to_lower() == letter:
			if is_inside_tree():
				get_viewport().set_input_as_handled()
			give(entry)
			return true
	return false

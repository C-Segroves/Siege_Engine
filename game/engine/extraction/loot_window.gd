class_name LootWindow
extends VBoxContainer
## The loot transfer screen (interact on a death bag, a dropped pile or a cache; ExtractionDirector.make_loot_offer):
## the container's contents on the left and the kit on the right, two windows on a ModalSheet (stacked on a narrow
## screen) with the weight and slots, so the player takes what he wants and leaves the rest.
##   mouse         Take / Put buttons per row, Take all (the sheet's primary), drag a row to the other window
##   keyboard/pad  ui_accept presses the focused button, menu_secondary puts the focused kit row back, menu_zone_next /
##                 prev (Tab, LT / RT) switch windows, menu_primary takes all, menu_back / interact / inventory_toggle close
## The host decides every move (LootTransfer) and answers with a message, shown in the sheet's status line. The game
## keeps running behind (PlayerHold holds only the controls) and the window closes when the container is gone or out
## of reach, the player is downed or leaves the raid, and, if LootSettings says so, when he is hit.

const LAYER := 85
const LAYER_NAME := "LootWindowLayer"
const SIDE_CONTAINER := "container"
const SIDE_KIT := "kit"
const TITLE_SUFFIX := "  -  LOOT"
const FOCUS_META := "loot_focus"
const ITEM_META := "loot_item"
const SIDE_META := "loot_side"

var director: ExtractionDirector
var container_id := 0
var sheet: ModalSheet
var tooltip: ItemTooltip
var container_pane: LootPane
var kit_pane: LootPane
var _panes: BoxContainer
var _shown_key := ""
var _watched: Infantry


## Opens the window on container `p_container_id` (one at a time; the inventory panel gives way).
static func open(p_director: ExtractionDirector, p_container_id: int) -> LootWindow:
	close_open(p_director)
	InventoryPanel.close_open(p_director)
	var layer := CanvasLayer.new()
	layer.layer = LAYER
	layer.name = LAYER_NAME
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	p_director.battle.add_child(layer)
	var window := LootWindow.new()
	window.director = p_director
	window.container_id = p_container_id
	window.sheet = ModalSheet.open(root, "")
	window.sheet.set_title(window.make_container().make_title().to_upper() + TITLE_SUFFIX)
	window.sheet.set_back("Close")
	window.sheet.set_primary("Take all", window.take_all)
	window.sheet.closed.connect(window._on_sheet_closed.bind(layer))
	window.sheet.body.add_child(window)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	PlayerHold.apply(p_director.battle, true)
	return window


## The open loot window (null when none).
static func find_open(p_director: ExtractionDirector) -> LootWindow:
	var layer := p_director.battle.get_node_or_null(LAYER_NAME)
	if layer == null:
		return null
	var found := layer.find_children("*", "LootWindow", true, false)
	return found[0] if not found.is_empty() else null


## Closes the open window; false when none was open.
static func close_open(p_director: ExtractionDirector) -> bool:
	var window := find_open(p_director)
	if window == null:
		return false
	window.close()
	return true


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	tooltip = ItemTooltip.new()
	sheet.add_child(tooltip)
	_build_panes()
	add_child(Widgets.row([_build_close_check()]))
	director.notified.connect(sheet.set_status)
	_watch_damage()
	_apply_layout()
	_rebuild()


func close() -> void:
	sheet.close()


## The container this window shows (null once it is gone).
func make_container() -> LootContainer:
	var c := director.containers.get(container_id) as LootContainer
	return c if c != null and is_instance_valid(c) else null


func take_all() -> void:
	director.request_loot_take_all(container_id)


func take(item_id: String, units: int) -> void:
	director.request_loot_take(container_id, item_id, units)


func put(item_id: String, units: int) -> void:
	director.request_loot_put(container_id, item_id, units)


func _build_panes() -> void:
	_panes = BoxContainer.new()
	_panes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_panes)
	container_pane = LootPane.new("")
	kit_pane = LootPane.new("YOUR KIT")
	_panes.add_child(container_pane)
	_panes.add_child(kit_pane)
	container_pane.apply_drop_target(func(d: Dictionary) -> bool: return d.get("from") == SIDE_KIT,
		func(d: Dictionary) -> void: put(str(d.item), int(d.units)))
	kit_pane.apply_drop_target(func(d: Dictionary) -> bool: return d.get("from") == SIDE_CONTAINER,
		func(d: Dictionary) -> void: take(str(d.item), int(d.units)))


func _build_close_check() -> CheckBox:
	var check := Widgets.check_box("Close this window when I am hit", LootSettings.make_close_on_damage())
	check.toggled.connect(LootSettings.apply_close_on_damage)
	return check


func _watch_damage() -> void:
	_watched = director.battle.player as Infantry
	if _watched:
		_watched.damaged.connect(_on_damaged)


func _on_damaged(_herc: Herc, _attacker: Node) -> void:
	if LootSettings.make_close_on_damage():
		close()


func _on_sheet_closed(layer: Node) -> void:
	if is_instance_valid(_watched) and _watched.damaged.is_connected(_on_damaged):
		_watched.damaged.disconnect(_on_damaged)
	if director.notified.is_connected(sheet.set_status):
		director.notified.disconnect(sheet.set_status)
	PlayerHold.apply(director.battle, false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	layer.name = LAYER_NAME + "Closed"   # the name is free at once for the next window
	layer.queue_free()


# ------------------------------------------------------------------ every frame

func _process(_delta: float) -> void:
	if not sheet.is_open:
		return
	if make_close_reason() != "":
		close()
		return
	_apply_layout()
	if _make_shown_key() != _shown_key:
		_rebuild()


## "" while the window may stay open, else why it closes (a fixed word for tests).
func make_close_reason() -> String:
	var soldier := director.battle.player as Infantry
	var c := make_container()
	if director.battle.is_over() or director.my_status != ExtractionDirector.STATUS_IN_RAID:
		return "raid"
	if soldier == null or not soldier.alive or soldier.stowed or DownedState.is_downed(soldier):
		return "soldier"
	if c == null:
		return "emptied"
	return "" if LootTransfer.is_within_reach(soldier.global_position, c.position) else "far"


## Side by side on a wide screen, stacked on a narrow one (the window decides, not the sheet: side by side needs more than the narrow width).
func _apply_layout() -> void:
	_panes.vertical = get_viewport_rect().size.x < Widgets.metric("narrow_width")


func _make_shown_key() -> String:
	var c := make_container()
	var soldier := director.battle.player as Infantry
	var worn := [soldier.make_loadout(), soldier.weapon_slot, soldier.kit.pack_id] if soldier else []
	return JSON.stringify([c.make_record() if c else {}, director.my_inventory.make_state(), worn])


# ------------------------------------------------------------------ rows

func _rebuild() -> void:
	var c := make_container()
	if c == null:
		return
	_shown_key = _make_shown_key()
	var remembered := _make_focus_key()
	container_pane.heading.text = c.make_title().to_upper()
	container_pane.summary.text = LootText.make_container_summary(c)
	kit_pane.summary.text = LootText.make_kit_summary(director.my_inventory)
	container_pane.apply_clear()
	kit_pane.apply_clear()
	_fill_container_rows(c)
	_fill_kit_rows()
	_restore_focus.call_deferred(remembered)


func _fill_container_rows(c: LootContainer) -> void:
	if c.money > 0:
		_add_row(container_pane, SIDE_CONTAINER, LootTransfer.MONEY_ID, c.money)
	for s in c.stacks:
		_add_row(container_pane, SIDE_CONTAINER, str(s[0]), int(s[1]))
	if c.is_empty():
		container_pane.rows.add_child(Widgets.label("Empty.", "DimLabel"))


func _fill_kit_rows() -> void:
	var inv := director.my_inventory
	if inv.money > 0:
		_add_row(kit_pane, SIDE_KIT, LootTransfer.MONEY_ID, inv.money)
	for id in inv.stacks:
		_add_row(kit_pane, SIDE_KIT, id, inv.count(id))
	if inv.is_empty():
		kit_pane.rows.add_child(Widgets.label("Nothing carried.", "DimLabel"))


## One row of `pane`: an item, or the credits (`id` MONEY_ID, `units` the credits).
func _add_row(pane: LootPane, side: String, id: String, units: int) -> void:
	var is_money := id == LootTransfer.MONEY_ID
	var fit := "" if is_money or side == SIDE_KIT else LootText.make_fit_note(director.my_inventory, id, units)
	var title := ExtractionRules.make_money_text(units) if is_money else ExtractionItems.make_stack_text(id, units)
	if side == SIDE_KIT and not is_money:
		title += InventoryPanel.make_marks(director, id, director.make_my_insured_id())
	var buttons := _make_buttons(side, id, units)
	var row := InventoryPanel.make_row(title, "no weight" if is_money else LootText.make_detail(id, units) + fit, buttons)
	pane.rows.add_child(row)
	_apply_drag(row, {"from": side, "item": id, "units": units}, title)
	if not is_money:
		tooltip.watch(row, func() -> Dictionary: return LootText.make_tooltip(id, units, fit.strip_edges().trim_prefix("-").strip_edges()))
	for i in buttons.size():
		(buttons[i] as Button).set_meta(ITEM_META, id)
		(buttons[i] as Button).set_meta(SIDE_META, side)
		(buttons[i] as Button).set_meta(FOCUS_META, i)


## The row is dragged whole (every unit of it) to the other window.
func _apply_drag(row: Control, data: Dictionary, title: String) -> void:
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.set_drag_forwarding(_make_drag_data.bind(row, data, title), Callable(), Callable())


func _make_drag_data(_at: Vector2, row: Control, data: Dictionary, title: String) -> Variant:
	if row.get_viewport().gui_is_dragging():
		row.set_drag_preview(Widgets.label(title, "StatusLabel"))
	return data


## The buttons of a row: one unit, one stack, all (credits: all at once).
func _make_buttons(side: String, id: String, units: int) -> Array:
	var verb := "Take" if side == SIDE_CONTAINER else "Put"
	var move: Callable = take if side == SIDE_CONTAINER else put
	if id == LootTransfer.MONEY_ID:
		return [Widgets.small_button("%s all" % verb, func() -> void: move.call(id, units), Widgets.PRIMARY)]
	var out := [Widgets.small_button("%s 1" % verb, func() -> void: move.call(id, 1), Widgets.PRIMARY)]
	var stack := LootText.make_stack_units(id, units)
	if stack > 1:
		out.append(Widgets.small_button(("All %d" if stack == units else "Stack %d") % stack, func() -> void: move.call(id, stack)))
	if units > stack:
		out.append(Widgets.small_button("All %d" % units, func() -> void: move.call(id, units)))
	return out


# ------------------------------------------------------------------ focus and keys

## "side|item|button index" of the focused row button ("" when none): kept across a rebuild.
func _make_focus_key() -> String:
	var owner_control := get_viewport().gui_get_focus_owner()
	if owner_control == null or not owner_control.has_meta(ITEM_META):
		return ""
	return "%s|%s|%d" % [owner_control.get_meta(SIDE_META), owner_control.get_meta(ITEM_META), owner_control.get_meta(FOCUS_META)]


func _restore_focus(key: String) -> void:
	if not is_inside_tree() or not sheet.is_open:
		return
	var parts := key.split("|")
	var wanted: Control = null
	if parts.size() == 3:
		wanted = _find_button(parts[0], parts[1], int(parts[2]))
	if wanted == null:
		wanted = _first_button(parts[0] if parts.size() == 3 else SIDE_CONTAINER)
	if wanted == null:
		wanted = _first_button(SIDE_KIT)
	if wanted != null:
		wanted.grab_focus()
	else:
		sheet.focus_first()


func _find_button(side: String, item_id: String, index: int) -> Control:
	var matches := _buttons_of(side).filter(func(b: Control) -> bool: return b.get_meta(ITEM_META) == item_id)
	return null if matches.is_empty() else matches[mini(index, matches.size() - 1)]


func _first_button(side: String) -> Control:
	var all := _buttons_of(side)
	return all[0] if not all.is_empty() else null


func _buttons_of(side: String) -> Array:
	var pane := container_pane if side == SIDE_CONTAINER else kit_pane
	return UiActions.focusables(pane.rows).filter(func(b: Control) -> bool: return b.has_meta(ITEM_META))


## Tab / LT, RT jump between the two windows. Handled before the GUI's own focus walk takes Tab.
func _input(event: InputEvent) -> void:
	if not sheet.is_open:
		return
	if UiActions.is_pressed(event, "menu_zone_next") or UiActions.is_pressed(event, "menu_zone_prev"):
		get_viewport().set_input_as_handled()
		apply_other_side()


func _unhandled_input(event: InputEvent) -> void:
	if not sheet.is_open:
		return
	if event.is_action_pressed("interact") or event.is_action_pressed("inventory_toggle"):
		get_viewport().set_input_as_handled()
		close()
	elif UiActions.is_pressed(event, "menu_secondary"):
		get_viewport().set_input_as_handled()
		_apply_put_back_focused()


## Moves focus to the first row of the window the focus is not in.
func apply_other_side() -> void:
	var owner_control := get_viewport().gui_get_focus_owner()
	var on_kit := owner_control != null and kit_pane.is_ancestor_of(owner_control)
	var target := _first_button(SIDE_CONTAINER if on_kit else SIDE_KIT)
	if target != null:
		target.grab_focus()


## menu_secondary on a kit row puts one unit of it back.
func _apply_put_back_focused() -> void:
	var owner_control := get_viewport().gui_get_focus_owner()
	if owner_control != null and owner_control.has_meta(SIDE_META) and owner_control.get_meta(SIDE_META) == SIDE_KIT:
		put(str(owner_control.get_meta(ITEM_META)), 1)

class_name InventoryPanel
extends PanelContainer
## The raid inventory (inventory_toggle; ExtractionDirector): what the local player carries, his load and money,
## with Drop (one / all: into a bag at his feet) and Equip (a weapon not in hand, a pack not
## worn: playtest X4) per item. A modal like ConfirmDialog: the theme's ModalShade dims the whole HUD (radar,
## objectives, instruments) and the ModalPanel sits centred above it, on a layer over every HUD layer. Each row is
## two columns: the name and detail wrap on the left, the buttons keep their place on the right. Keyboard and
## gamepad move the focus, menu_back or Close shuts it. The battle keeps running and the player's controls are held
## while it is open (PlayerHold).

## Above the battle HUD, overlay and chat; below the battle menu (BattleMenu.LAYER 90).
const LAYER := 85
const LAYER_NAME := "InventoryPanelLayer"
const SIZE := Vector2(620, 560)
## The panel never takes more than this share of the screen.
const MAX_SCREEN_SHARE := 0.9
## The text column of a row is at least this wide before its labels wrap (pixels).
const TEXT_MIN_WIDTH := 200
## After the insured item's name (ExtractionProfile insured slot: kept on death, one slot of it).
const INSURED_MARK := "   [INSURED]"
const IN_HAND_MARK := "   [IN HAND]"
const WORN_MARK := "   [WORN]"
const READY_MARK := "   [READY]"

var director: ExtractionDirector
var _rows: VBoxContainer
var _summary: Label
var _shown_key := ""


## Opens the panel, or closes it when it is open.
static func toggle(p_director: ExtractionDirector) -> void:
	if not close_open(p_director):
		open(p_director)


static func open(p_director: ExtractionDirector) -> InventoryPanel:
	return show_panel(p_director, InventoryPanel.new())


## Shows `panel` (this panel or a raid panel built on it, StationShopPanel) in the panel layer; one at a time.
static func show_panel(p_director: ExtractionDirector, panel: InventoryPanel) -> InventoryPanel:
	close_open(p_director)
	var layer := CanvasLayer.new()
	layer.layer = LAYER
	layer.name = LAYER_NAME
	panel.director = p_director
	var shade := PanelContainer.new()
	shade.theme_type_variation = "ModalShade"
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	var center := CenterContainer.new()
	shade.add_child(center)
	center.add_child(panel)
	layer.add_child(shade)
	p_director.battle.add_child(layer)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	PlayerHold.apply(p_director.battle, true)
	return panel


## Closes the open panel; false when none was open.
static func close_open(p_director: ExtractionDirector) -> bool:
	var layer := p_director.battle.get_node_or_null(LAYER_NAME)
	if layer == null:
		return false
	for c in layer.find_children("*", "InventoryPanel", true, false):
		(c as InventoryPanel).close()
		return true
	layer.queue_free()
	return true


## The open raid panel (null when none).
static func find_open(p_director: ExtractionDirector) -> InventoryPanel:
	var layer := p_director.battle.get_node_or_null(LAYER_NAME)
	if layer == null:
		return null
	var found := layer.find_children("*", "InventoryPanel", true, false)
	return found[0] if not found.is_empty() else null


func _ready() -> void:
	theme_type_variation = "ModalPanel"
	var screen := get_viewport_rect().size
	custom_minimum_size = Vector2(minf(SIZE.x, screen.x * MAX_SCREEN_SHARE), minf(SIZE.y, screen.y * MAX_SCREEN_SHARE))
	var box := VBoxContainer.new()
	add_child(box)
	box.add_child(Widgets.label(_make_title(), "HeaderLabel"))
	_summary = Widgets.label("", "DimLabel")
	box.add_child(_summary)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	box.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)
	var close_button := Widgets.button("Close", close, Widgets.PRIMARY)
	var footer := Widgets.row([close_button])
	footer.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(footer)
	_rebuild()


func _process(_delta: float) -> void:
	if _make_shown_key() != _shown_key:
		_rebuild()


## What the panel shows: the inventory and what is in hand / worn (an Equip lands a moment later).
func _make_shown_key() -> String:
	var s := director.battle.player as Infantry
	var worn := [s.make_loadout(), s.weapon_slot, s.kit.pack_id] if s else []
	return JSON.stringify([director.my_inventory.make_state(), worn])


func _make_title() -> String:
	return "INVENTORY"


func _rebuild() -> void:
	var inv := director.my_inventory
	_shown_key = _make_shown_key()
	_summary.text = "%s   %.1f / %.0f kg   %d / %d slots" % [ExtractionRules.make_money_text(inv.money), inv.make_used_kg(),
		inv.max_kg, inv.make_used_slots(), inv.max_slots]
	_summary.text += "
" + inv.make_capacity_text()
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	if inv.stacks.is_empty():
		_rows.add_child(Widgets.label("Nothing carried.", "DimLabel"))
	var insured_id := director.make_my_insured_id()
	for id in inv.stacks:
		var title := ExtractionItems.make_stack_text(id, inv.count(id)) + _make_marks(id, insured_id)
		_rows.add_child(make_row(title, _make_detail(id, inv.count(id)), _make_buttons(id, inv.count(id))))
	if ExtractionItems.kind_of(insured_id) == ExtractionItems.ARMOR_KIND:
		_rows.add_child(Widgets.label("Worn: %s%s" % [ExtractionItems.make_name(insured_id), INSURED_MARK], "DimLabel"))
	_link_focus.call_deferred()


## "   [IN HAND]", "   [READY]" (in a weapon slot), "   [WORN]", "   [INSURED]" after an item's name.
func _make_marks(id: String, insured_id: String) -> String:
	var s := director.battle.player as Infantry
	var marks := ""
	if s and ExtractionLoadout.is_equipped(s, id):
		marks += IN_HAND_MARK if ExtractionItems.kind_of(id) == "weapon" else WORN_MARK
	elif s and ExtractionLoadout.is_carried_ready(s, id):
		marks += READY_MARK
	return marks + (INSURED_MARK if id == insured_id else "")


## An item row whose name and detail wrap in their own column, clear of the buttons.
static func make_row(title: String, detail: String, buttons: Array) -> ItemRow:
	var row := ItemRow.make(title, detail, buttons)
	var text := row.get_child(0) as Control
	text.custom_minimum_size.x = TEXT_MIN_WIDTH
	for label in text.get_children():
		(label as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var buttons_box := HBoxContainer.new()
	buttons_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for b in buttons:
		row.remove_child(b)
		buttons_box.add_child(b)
	row.add_child(buttons_box)
	return row


static func _make_detail(id: String, units: int) -> String:
	return "%.1f kg   worth %s" % [float(ExtractionItems.item(id).get("kg", 0.0)) * units,
		ExtractionRules.make_money_text(ExtractionItems.make_sell_price(id, units))]


func _make_buttons(id: String, units: int) -> Array:
	var out := []
	var s := director.battle.player as Infantry
	if s and ExtractionLoadout.can_equip(s, id):
		out.append(Widgets.small_button("Equip", func() -> void: director.request_equip(id), Widgets.PRIMARY))
	out.append(Widgets.small_button("Drop 1", func() -> void: director.request_drop(id, 1)))
	if units > 1:
		out.append(Widgets.small_button("Drop all", func() -> void: director.request_drop(id, units)))
	return out


func close() -> void:
	PlayerHold.apply(director.battle, false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var layer := _find_layer()
	layer.name = LAYER_NAME + "Closed"   # the name is free at once for the next panel
	layer.queue_free()


func _find_layer() -> Node:
	var n: Node = self
	while n != null and not (n is CanvasLayer):
		n = n.get_parent()
	return n


func _link_focus() -> void:
	if not is_inside_tree():
		return
	var chain := UiActions.focusables(self)
	UiActions.link_vertical(chain)
	var owner_control := get_viewport().gui_get_focus_owner()
	if not chain.is_empty() and (owner_control == null or not is_ancestor_of(owner_control)):
		chain[0].grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event) or event.is_action_pressed("inventory_toggle"):
		get_viewport().set_input_as_handled()
		close()

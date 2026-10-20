class_name ArmourPreview
extends VBoxContainer
## The centre of Operator Setup: the soldier in the armour (or the vehicle) in the hangar view, the card of the part last
## added or hovered (name, game, numbers, allowed or not), and the INFANTRY / VEHICLE switch (a third STASH button in a raid).

signal side_requested(side: String)

const TALL_HEIGHT := 260
const COMPACT_HEIGHT := 140
const SIDE_LABELS := {"infantry": "INFANTRY", "vehicle": "VEHICLE", "stash": "STASH"}
const SIDE_BUTTON_HEIGHT := 56

var hangar: HangarView
var _state: OperatorState
var _card_title: Label
var _card_lines: Label
var _card_badge: Label
var _side_row: HBoxContainer
var _detail: VBoxContainer
var _preview_toggle: Button
var _compact := false
var _side_buttons := {}
var _shown_key := ""
var _with_3d := true


func _init(state: OperatorState, with_3d := true) -> void:
	_state = state
	_with_3d = with_3d
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail = VBoxContainer.new()
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_detail)
	_detail.add_child(Widgets.section("PREVIEW"))
	_build_hangar()
	_detail.add_child(_build_card())
	_build_preview_toggle()
	_build_side_row()


## Narrow screens: the model and the card are folded away behind a toggle so the list keeps the room.
func set_compact(on: bool) -> void:
	_compact = on
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN if on else Control.SIZE_EXPAND_FILL
	if hangar != null:
		hangar.custom_minimum_size = Vector2(0, COMPACT_HEIGHT if on else TALL_HEIGHT)
	_preview_toggle.visible = on
	_apply_detail_visibility()


## The preview toggle (narrow only) and the side buttons: what the keyboard can reach in the centre.
func make_controls() -> Array[Control]:
	var out: Array[Control] = []
	if _preview_toggle.is_visible_in_tree():
		out.append(_preview_toggle)
	out.append_array(make_side_buttons())
	return out


func _apply_detail_visibility() -> void:
	_detail.visible = not _compact or _preview_toggle.button_pressed
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL if not _compact else Control.SIZE_SHRINK_BEGIN


func _build_preview_toggle() -> void:
	_preview_toggle = Button.new()
	_preview_toggle.text = "Show preview"
	_preview_toggle.toggle_mode = true
	_preview_toggle.theme_type_variation = "TabButton"
	_preview_toggle.visible = false
	_preview_toggle.toggled.connect(func(on: bool) -> void:
		_preview_toggle.text = "Hide preview" if on else "Show preview"
		_apply_detail_visibility())
	add_child(_preview_toggle)


## The side buttons, left to right.
func make_side_buttons() -> Array[Control]:
	var out: Array[Control] = []
	for b in _side_row.get_children():
		out.append(b)
	return out


## Redraws the model and the side switch for the open slot and side.
func refresh() -> void:
	_refresh_sides()
	_refresh_model()
	if _state.last_entry.is_empty():
		_show_card({})


## Shows `entry` on the card (a store entry; {} = the hint).
func show_entry(entry: Dictionary) -> void:
	_show_card(entry)


func _build_hangar() -> void:
	if not _with_3d:
		var gap := Control.new()
		gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_detail.add_child(gap)
		return
	hangar = HangarView.new()
	hangar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hangar.custom_minimum_size = Vector2(0, TALL_HEIGHT)
	_detail.add_child(hangar)


func _build_card() -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "CardPanel"
	var box := VBoxContainer.new()
	panel.add_child(box)
	var head := HBoxContainer.new()
	_card_title = Widgets.label("", "SectionLabel")
	_card_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_card_badge = Widgets.label("", "BadgeNotAllowed")
	head.add_child(_card_title)
	head.add_child(_card_badge)
	box.add_child(head)
	_card_lines = Widgets.paragraph("", "DimLabel")
	box.add_child(_card_lines)
	return panel


func _build_side_row() -> void:
	_side_row = HBoxContainer.new()
	add_child(_side_row)
	var group := ButtonGroup.new()
	for side in _state.make_sides():
		var b := Button.new()
		b.text = SIDE_LABELS.get(side, str(side).to_upper())
		b.toggle_mode = true
		b.button_group = group
		b.theme_type_variation = "TabButton"
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, SIDE_BUTTON_HEIGHT)
		b.pressed.connect(func() -> void: side_requested.emit(side))
		_side_row.add_child(b)
		_side_buttons[side] = b


func _refresh_sides() -> void:
	for side in _side_buttons:
		(_side_buttons[side] as Button).set_pressed_no_signal(side == _state.side)


func _refresh_model() -> void:
	if hangar == null:
		return
	var slot := _state.make_slot()
	var key := _make_model_key(slot)
	if key == _shown_key:
		return
	_shown_key = key
	if _state.side == LoadoutLayout.SIDE_VEHICLE and slot.vehicle != "":
		hangar.apply_skin(slot.herc_skin)
		hangar.show_herc(slot.vehicle, slot.herc_loadout)
		return
	var shape := slot.body if slot.body != "" else PlayerProfile.make_default_body(slot.armor)
	if shape != "":
		hangar.apply_skin(slot.skin)
		hangar.show_herc(shape)


func _make_model_key(slot: CharacterSlot) -> String:
	if _state.side == LoadoutLayout.SIDE_VEHICLE:
		return "v|%s|%s|%s" % [slot.vehicle, slot.herc_skin, ",".join(PackedStringArray(slot.herc_loadout))]
	return "i|%s|%s|%s" % [slot.armor, slot.body, slot.skin]


func _show_card(entry: Dictionary) -> void:
	if entry.is_empty():
		_card_title.text = "Hover or select a part"
		_card_lines.text = "Its numbers and whether this mode allows it show here."
		_card_badge.visible = false
		return
	_card_title.text = str(entry.name)
	var lines: Array = [Packs.pack_name(str(entry.pack)) if str(entry.pack) != "" else "Any game"]
	lines.append_array(OperatorText.make_stat_lines(entry))
	var price := OperatorText.make_price_line(entry)
	if price != "":
		lines.append(price)
	var blocked := str(entry.state) == StoreCatalog.STATE_NOT_ALLOWED
	if not blocked:
		lines.append("allowed in this mode")
	_card_lines.text = "  -  ".join(PackedStringArray(lines.map(func(x: Variant) -> String: return str(x))))
	_card_badge.visible = blocked
	_card_badge.text = "NOT ALLOWED"
	if blocked:
		_card_lines.text += "\n" + str(entry.reason)

class_name KitRow
extends HBoxContainer
## One row of the raid loadout list (ExtractionKitEditor rows, and the armour): its label and a drop-down of what the
## stash and the kit offer for that place, the empty choice first. The drop-down is an OptionButton, so mouse, keyboard
## (accept opens it, up / down pick) and gamepad all work; right click / pad X (menu_secondary) picks the empty choice.

signal chosen(row_key: String, choice: String)
signal removed(row_key: String)

const LABEL_WIDTH := 76

var row := {}
var option: OptionButton


## `badge` is OperatorText.make_row_badge's answer.
static func make(p_row: Dictionary, badge: Array) -> KitRow:
	var r := KitRow.new()
	r.row = p_row
	r.build_content(badge)
	return r


func build_content(badge: Array) -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(0, Widgets.metric("row_height"))
	var label := Widgets.label(str(row.label), "DimLabel")
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_child(label)
	option = Widgets.option_button(_make_texts(), _find_selected())
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.set_meta("row_key", str(row.key))
	for i in (row.choices as Array).size():
		option.set_item_metadata(i, str(row.choices[i].id))
	option.item_selected.connect(_on_item_selected)
	option.gui_input.connect(_on_option_input)
	add_child(option)
	if not badge.is_empty():
		var b := Widgets.label(str(badge[0]), str(badge[1]))
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		add_child(b)


## The choice id the drop-down shows now.
func make_choice() -> String:
	return str(option.get_item_metadata(option.selected)) if option.selected >= 0 else ""


func _make_texts() -> Array:
	return (row.choices as Array).map(func(c: Dictionary) -> String: return str(c.text))


func _find_selected() -> int:
	for i in (row.choices as Array).size():
		if str(row.choices[i].id) == str(row.choice):
			return i
	return 0


func _on_item_selected(index: int) -> void:
	chosen.emit(str(row.key), str(option.get_item_metadata(index)))


func _on_option_input(event: InputEvent) -> void:
	if RowButton.is_secondary(event):
		removed.emit(str(row.key))
		option.accept_event()

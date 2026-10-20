class_name LoadoutRow
extends RowButton
## One row of the loadout list (a LoadoutLayout row): its label, what it holds, ammunition / count controls and a badge.
## Right click or pad X (menu_secondary) asks to remove; left / right on an ammunition or gear row adjust it.

signal removed(row_key: String)
signal adjusted(row_key: String, direction: int)

const LABEL_WIDTH := 96
const COUNT_WIDTH := 56

var row := {}


## `part_name` is what the row holds (or its empty prompt); `badge` is OperatorText.make_row_badge's answer.
static func make(p_row: Dictionary, part_name: String, badge: Array) -> LoadoutRow:
	var r := LoadoutRow.new()
	r.row = p_row
	r.build_content(part_name, badge)
	return r


func is_adjustable() -> bool:
	return int(row.ammo_max) > 0 and not bool(row.locked)


func build_content(part_name: String, badge: Array) -> void:
	add_text(str(row.label), "DimLabel", false, LABEL_WIDTH)
	add_text(part_name, "DimLabel" if str(row.current) == "" and str(row.kind) != "ammo" else "", true)
	if is_adjustable():
		add_mouse_button("-", func() -> void: adjusted.emit(str(row.key), -1))
		add_text("%d/%d" % [int(row.ammo), int(row.ammo_max)], "", false, COUNT_WIDTH).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_mouse_button("+", func() -> void: adjusted.emit(str(row.key), 1))
	if not badge.is_empty():
		add_text(str(badge[0]), str(badge[1]))


func _gui_input(event: InputEvent) -> void:
	if is_secondary(event):
		removed.emit(str(row.key))
		accept_event()
	elif is_adjustable() and UiActions.is_pressed(event, "ui_left"):
		adjusted.emit(str(row.key), -1)
		accept_event()
	elif is_adjustable() and UiActions.is_pressed(event, "ui_right"):
		adjusted.emit(str(row.key), 1)
		accept_event()

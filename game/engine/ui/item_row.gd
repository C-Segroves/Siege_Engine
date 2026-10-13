class_name ItemRow
extends HBoxContainer
## One item in a list (shared widget: the raid inventory, the stash, the shop): its name, a dim detail line
## (weight, price, worth) and the row's action buttons on the right.
##   ItemRow.make("Disc Launcher x2", "12 kg  worth 600 cr", [Widgets.small_button("Sell", ...)])


static func make(title: String, detail: String, buttons: Array) -> ItemRow:
	var row := ItemRow.new()
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_child(Widgets.label(title))
	if detail != "":
		text.add_child(Widgets.label(detail, "DimLabel"))
	row.add_child(text)
	for b in buttons:
		(b as Control).size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(b)
	return row

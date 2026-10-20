class_name OptionRow
extends HBoxContainer
## One labelled setting: a fixed-width label (theme constant `label_width`) and its control,
## which fills the rest of the row.
##   OptionRow.new("Kill limit", Widgets.slider(1, 100, 10))
## Sliders get a live value readout (`with_value_readout`).

var label: Label
var control: Control


func _init(label_text := "", p_control: Control = null) -> void:
	label = Widgets.label(label_text)
	label.custom_minimum_size = Vector2(Widgets.metric("label_width"), 0)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_child(label)
	if p_control != null:
		set_control(p_control)


func set_control(p_control: Control) -> void:
	control = p_control
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(control)


## Adds a number readout after a Range control (slider), kept in sync; `format` e.g. "%d %%".
func with_value_readout(format := "%d") -> OptionRow:
	var range_control := control as Range
	if range_control == null:
		push_error("OptionRow.with_value_readout: control is not a Range")
		return self
	var readout := Widgets.label(format % range_control.value)
	readout.custom_minimum_size = Vector2(Widgets.metric("row_height") * 2, 0)
	add_child(readout)
	range_control.value_changed.connect(func(v: float) -> void: readout.text = format % v)
	return self


## A row for a setting only the host may change: the same label column, the value as plain text (a Label, so it
## never takes focus or looks editable). `row.control` is the value Label; set `.text` to update it.
static func make_readonly(label_text: String, value_text: String) -> OptionRow:
	var value := Widgets.label(value_text)
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value.focus_mode = Control.FOCUS_NONE
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return OptionRow.new(label_text, value)

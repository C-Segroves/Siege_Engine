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

class_name ChatOptions
extends VBoxContainer
## The options screen's chat section (ChatSettings, saved at once): visible and history lines, fade time, panel
## width, background opacity, font size, position preset, timestamps, which channels show, and a reset.
## The chat panel picks changes up while a battle runs (ChatPanel polls the settings).

const PERCENT := 100.0
const WIDTH_STEP := 20.0

var _sliders := {}          # setting key -> HSlider
var _position: OptionButton
var _timestamps: CheckBox
var _filters := {}          # channel -> CheckBox
var _loading := false       # _apply_values is filling the controls


func _init() -> void:
	name = "ChatOptions"
	var current := ChatSettings.load_settings()
	add_child(Widgets.section("Chat"))
	add_child(Widgets.paragraph("Enter: chat to all, Y: team chat, K / pad Share: quick chat, U: full history "
		+ "(drag its title strip to move the panel, its corner to resize it). Rebind them under Controls.", "DimLabel"))
	_add_slider_row("Visible lines", "visible_lines", 1.0, "%d", current)
	_add_slider_row("History lines (open)", "history_lines", 1.0, "%d", current)
	_add_slider_row("Fade after (0 = never)", "fade_seconds", 1.0, "%d s", current)
	_add_slider_row("Width", "width", WIDTH_STEP, "%d px", current)
	_add_slider_row("Font size", "font_size", 1.0, "%d px", current)
	_add_opacity_row(current)
	_add_position_row()
	_add_toggles()
	add_child(Widgets.row([Widgets.small_button("Reset chat settings", _reset, Widgets.DANGER)]))
	_apply_values(current)


func _add_slider_row(text: String, key: String, step: float, format: String, current: Dictionary) -> void:
	var lim: Vector2 = ChatSettings.LIMITS[key]
	var s := Widgets.slider(lim.x, lim.y, float(current[key]), step)
	s.value_changed.connect(func(v: float) -> void: _save(key, v))
	_sliders[key] = s
	add_child(OptionRow.new(text, s).with_value_readout(format))


func _add_opacity_row(current: Dictionary) -> void:
	var s := Widgets.slider(0.0, PERCENT, float(current.opacity) * PERCENT, 5.0)
	s.value_changed.connect(func(v: float) -> void: _save("opacity", v / PERCENT))
	_sliders["opacity"] = s
	add_child(OptionRow.new("Background opacity", s).with_value_readout("%d %%"))


func _add_position_row() -> void:
	_position = Widgets.option_button(ChatSettings.PRESETS.map(func(p: String) -> String: return ChatSettings.PRESET_NAMES[p]))
	_position.item_selected.connect(func(i: int) -> void: ChatSettings.apply_value("position", ChatSettings.PRESETS[i]))
	add_child(OptionRow.new("Position", _position))


func _add_toggles() -> void:
	_timestamps = Widgets.check_box("Show the time of each line", false)
	_timestamps.toggled.connect(func(on: bool) -> void: ChatSettings.apply_value("timestamps", on))
	add_child(OptionRow.new("Timestamps", _timestamps))
	var boxes := []
	for c in ChatChannels.ORDER:
		var b := Widgets.check_box(ChatChannels.label_of(c), true)
		b.toggled.connect(func(on: bool) -> void: ChatSettings.apply_filter(c, on))
		_filters[c] = b
		boxes.append(b)
	add_child(OptionRow.new("Channels shown", Widgets.row(boxes)))


## Shows `s` in the controls (the slider readouts follow) without saving anything again.
func _apply_values(s: Dictionary) -> void:
	_loading = true
	for key in _sliders:
		var v := float(s[key]) * (PERCENT if key == "opacity" else 1.0)
		(_sliders[key] as HSlider).value = v
	_position.select(maxi(ChatSettings.PRESETS.find(str(s.position)), 0))
	_timestamps.set_pressed_no_signal(bool(s.timestamps))
	for c in _filters:
		(_filters[c] as CheckBox).set_pressed_no_signal(bool(s.filters.get(c, true)))
	_loading = false


func _save(key: String, value: Variant) -> void:
	if not _loading:
		ChatSettings.apply_value(key, value)


func _reset() -> void:
	ChatSettings.reset()
	_apply_values(ChatSettings.load_settings())

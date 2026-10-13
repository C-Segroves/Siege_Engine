class_name Widgets
## Factory for the small controls every screen uses, styled only through the project theme
## (engine/ui/siege_theme.gd): sizes come from the theme's "Siege" constants, looks from its
## type variations.

const PRIMARY := "PrimaryButton"
const DANGER := "DangerButton"


## A theme constant of type "Siege" (margin, gap, label_width, button_width, row_height, font_size_*).
static func metric(name: String) -> int:
	var theme := ThemeDB.get_project_theme()
	if theme != null and theme.has_constant(name, "Siege"):
		return theme.get_constant(name, "Siege")
	push_error("Widgets: theme constant Siege/%s missing" % name)
	return 0


## A menu-sized button calling `on_pressed`; `variation` = "", PRIMARY or DANGER.
static func button(text: String, on_pressed: Callable, variation := "") -> Button:
	var b := Button.new()
	b.text = text
	b.theme_type_variation = variation
	b.custom_minimum_size = Vector2(metric("button_width"), metric("row_height"))
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.pressed.connect(on_pressed)
	return b


## A button sized to its text (rows of small actions).
static func small_button(text: String, on_pressed: Callable, variation := "") -> Button:
	var b := button(text, on_pressed, variation)
	b.custom_minimum_size = Vector2(0, metric("row_height"))
	return b


static func label(text: String, variation := "") -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	return l


static func section(text: String) -> Label:
	return label(text, "SectionLabel")


## Wrapping paragraph that fills the available width.
static func paragraph(text: String, variation := "") -> Label:
	var l := label(text, variation)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


static func option_button(items: Array, selected := 0) -> OptionButton:
	var o := OptionButton.new()
	o.fit_to_longest_item = false
	o.clip_text = true
	for item in items:
		o.add_item(str(item))
	if not items.is_empty():
		o.select(clampi(selected, 0, items.size() - 1))
	return o


static func check_box(text: String, on: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	return c


static func line_edit(text: String, placeholder := "") -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	return e


## Horizontal slider (left/right change the value, up/down move focus - gamepad friendly).
static func slider(min_value: float, max_value: float, value: float, step := 1.0) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_value
	s.max_value = max_value
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(metric("button_width"), metric("row_height") / 2)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return s


## Bordered card (the theme's Panel style) holding a VBox; returns the VBox to fill.
static func card(parent: Node) -> VBoxContainer:
	var panel := PanelContainer.new()
	parent.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	return box


## Row of controls left to right.
static func row(controls: Array) -> HBoxContainer:
	var r := HBoxContainer.new()
	for c in controls:
		r.add_child(c)
	return r

class_name RowButton
extends Button
## A focusable list row that holds several labels and badges (the shared base of the store and loadout rows).
## It is a Button so the theme's hover / focus / pressed looks and keyboard, mouse and gamepad activation all work;
## the content row on top ignores the mouse so a click always lands on the row. Small controls inside it (the ammunition
## -/+ buttons) take mouse clicks only and are reached from the keyboard through the row's own left / right keys.

const CONTENT_MARGIN := 8

var content: HBoxContainer


func _init() -> void:
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = Vector2(0, Widgets.metric("row_height"))
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content = HBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, CONTENT_MARGIN)
	add_child(content)


## A label in the row; `expand` makes it take the free width (and trim with "..." when it does not fit).
func add_text(text: String, variation := "", expand := false, min_width := 0) -> Label:
	var l := Widgets.label(text, variation)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l.custom_minimum_size = Vector2(min_width, 0)
	if expand:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.clip_text = true
	content.add_child(l)
	return l


## A small mouse-only button inside the row (focus_mode none: the keyboard reaches its action through the row).
func add_mouse_button(text: String, on_pressed: Callable) -> Button:
	var b := Widgets.small_button(text, on_pressed)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(Widgets.metric("row_height") * 0.8, Widgets.metric("row_height") * 0.7)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	content.add_child(b)
	return b


## True for the "remove / alternate action" press (right click, pad X) on the row.
static func is_secondary(event: InputEvent) -> bool:
	return UiActions.is_pressed(event, "menu_secondary")

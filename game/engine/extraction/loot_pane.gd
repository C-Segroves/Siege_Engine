class_name LootPane
extends PanelContainer
## One of the loot window's two windows (LootWindow): a card with a heading, a summary line and a scrolling list of
## item rows. It is also a drop target: a row dragged from the other pane lands on it anywhere on the card.

var heading: Label
var summary: Label
var rows: VBoxContainer
var _scroll: ScrollContainer
var _accepts := Callable()
var _on_drop := Callable()


func _init(title: String) -> void:
	theme_type_variation = "CardPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var column := VBoxContainer.new()
	add_child(column)
	heading = Widgets.label(title, "SectionLabel")
	column.add_child(heading)
	summary = Widgets.label("", "DimLabel")
	column.add_child(summary)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	column.add_child(_scroll)
	rows = VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(rows)


## Removes every row (they are freed).
func apply_clear() -> void:
	for c in rows.get_children():
		rows.remove_child(c)
		c.queue_free()


## Takes rows dragged from the other pane, dropped anywhere on this card: `accepts.call(data) -> bool`, then `on_drop.call(data)`.
func apply_drop_target(p_accepts: Callable, p_on_drop: Callable) -> void:
	_accepts = p_accepts
	_on_drop = p_on_drop
	for target in [self, _scroll, rows]:
		(target as Control).set_drag_forwarding(Callable(), _can_drop_forwarded, _drop_forwarded)


## True when `data` (a dragged row) may be dropped here.
func make_accepts(data: Variant) -> bool:
	return _accepts.is_valid() and data is Dictionary and _accepts.call(data)


## Does the drop of `data` (what a mouse release over the card calls).
func apply_drop(data: Variant) -> void:
	if make_accepts(data):
		_on_drop.call(data)


func _can_drop_forwarded(_at: Vector2, data: Variant) -> bool:
	return make_accepts(data)


func _drop_forwarded(_at: Vector2, data: Variant) -> void:
	apply_drop(data)

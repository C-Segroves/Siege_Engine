class_name MediaBox
extends Control
## The media area of a launcher page (briefing movie, talking head): as wide as its column, as tall as `ratio`
## gives (never more than MAX_SCREEN_FRACTION of the screen), black, clipped. `fit(child, aspect)` letterboxes a
## child inside it, centred, aspect kept. Sized by the container, not by pixels, so it follows the UI scale.

const MAX_SCREEN_FRACTION := 0.5

var ratio := 1.6
var _fitted: Array = []   # [{node, aspect}]


func _init(box_ratio := 1.6) -> void:
	ratio = box_ratio
	clip_contents = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	resized.connect(_relayout)


## Places `child` inside the box at `aspect` (width / height), centred and letterboxed.
func fit(child: Control, aspect: float) -> void:
	if child.get_parent() == null:
		add_child(child)
	_fitted = _fitted.filter(func(f): return f.node != child)
	_fitted.append({"node": child, "aspect": aspect})
	_relayout()


func _relayout() -> void:
	var h := size.x / maxf(ratio, 0.01)
	h = minf(h, get_viewport_rect().size.y * MAX_SCREEN_FRACTION)
	if absf(custom_minimum_size.y - h) > 0.5:
		custom_minimum_size.y = h
	for f in _fitted:
		if not is_instance_valid(f.node):
			continue   # a skipped movie frees its player: the typed assignment below would fail on it
		var n: Control = f.node
		var box := size
		var a: float = maxf(f.aspect, 0.01)
		var s := Vector2(box.x, box.x / a)
		if s.y > box.y:
			s = Vector2(box.y * a, box.y)
		n.anchor_left = 0
		n.anchor_top = 0
		n.anchor_right = 0
		n.anchor_bottom = 0
		n.position = ((box - s) * 0.5).floor()
		n.size = s.floor()

class_name ShellStyle
extends RefCounted
## One CFG\STYLES.DAT entry drawn the way GO.EXE draws a style box (0x44b86): the face, three
## one-pixel rings and the four CORNERS.DBA corner pieces (docs/formats/shell.md section 5).
## MTButton (ctor 0x1cde8, draw 0x1d200) uses style 0 normal, 1 pushed, 2 inactive.

## colour[0] fills the box inset by FACE_INSET (0x44b86 -> 0x51c74).
const FACE_SLOT := 0
const FACE_INSET := 3
## Rings outer to inner (0x44dc8 called with slot 1/5/9, inset 0/1/2); each ring is 4 colour slots
## in the order left, top, right, bottom. Colour 0 = line not drawn.
const RING_FIRST_SLOTS := [1, 5, 9]
## Used when STYLES.DAT is missing: style 0 of the original file.
const FALLBACK_COLORS := [21, 29, 29, 29, 29, 17, 16, 27, 25, 19, 19, 23, 22]
const FALLBACK_CORNERS := [4, 5, 6, 7]
const FALLBACK_BORDER := [2, 2]

var colors: Array = FALLBACK_COLORS
var corner_frames: Array = FALLBACK_CORNERS     # CORNERS.DBA frames: top-left, top-right, bottom-left, bottom-right
var border := Vector2i(2, 2)                     # corner piece offset from the right / bottom edge


## Style `index` of the exported shell.json "styles" list (fallback when it is missing).
static func load_style(index: int) -> ShellStyle:
	var s := ShellStyle.new()
	var all: Array = ShellData.meta().get("styles", [])
	if index < 0 or index >= all.size():
		push_warning("shell style %d missing; using the default" % index)
		return s
	var e: Dictionary = all[index]
	s.colors = e.get("colors", FALLBACK_COLORS)
	s.corner_frames = e.get("corners_dba_index", FALLBACK_CORNERS)
	var b: Array = e.get("border", FALLBACK_BORDER)
	s.border = Vector2i(int(b[0]), int(b[1]))
	return s


func face_color() -> int:
	return int(colors[FACE_SLOT])


## The whole box: face, rings, corners. `r` is inclusive of its last row / column (r.end - 1).
func draw_box(img: Image, r: Rect2i, corners: Array) -> void:
	ShellData.fill(img, r.grow(-FACE_INSET), face_color())
	draw_frame(img, r, corners)


## Rings and corners only (the face is left as it is).
func draw_frame(img: Image, r: Rect2i, corners: Array) -> void:
	for ring in RING_FIRST_SLOTS.size():
		_draw_ring(img, r.grow(-ring), int(RING_FIRST_SLOTS[ring]))
	_draw_corners(img, r, corners)


func _draw_ring(img: Image, r: Rect2i, first_slot: int) -> void:
	var x1 := r.position.x
	var y1 := r.position.y
	var x2 := r.end.x - 1
	var y2 := r.end.y - 1
	var edges := [[x1, y1 + 1, x1, y2 - 1], [x1 + 1, y1, x2 - 1, y1], [x2, y1 + 1, x2, y2 - 1], [x1 + 1, y2, x2 - 1, y2]]
	for k in edges.size():
		var c := int(colors[first_slot + k])
		if c != 0:
			var e: Array = edges[k]
			ShellData.line(img, e[0], e[1], e[2], e[3], c)


## 0x451c1: corner k at (x1 | x2 - border.x, y1 | y2 - border.y).
func _draw_corners(img: Image, r: Rect2i, corners: Array) -> void:
	var x2 := r.end.x - 1 - border.x
	var y2 := r.end.y - 1 - border.y
	var points := [Vector2i(r.position.x, r.position.y), Vector2i(x2, r.position.y),
		Vector2i(r.position.x, y2), Vector2i(x2, y2)]
	for k in mini(corner_frames.size(), points.size()):
		var frame := int(corner_frames[k])
		if frame < corners.size() and corners[frame] != null:
			ShellData.blit(img, corners[frame], points[k].x, points[k].y)

class_name ShellButton
extends RefCounted
## Draws a DLG type-3 button of a ShellMenu the way GO.EXE does (docs/formats/shell.md section 4/5):
## text buttons are MTButton (ctor 0x1cde8, draw 0x1d200), bitmap buttons MTBmpButton (0x1d47d).

## A "selected" MTButton (+0x94, draw 0x1d2a3) gets a rectangle in UI colour 10 (blue) round its
## whole rect (0x4b867); the remake shows it on the highlighted button (mouse, keyboard, gamepad).
const SELECTED_OUTLINE_COLOR := 10
## Pushed label offset (ctor 0x1cf41: state 1 text at y + 1, same x).
const PUSHED_LABEL_DY := 1
## Arrow buttons whose 56-px slider frames do not fit: drawn with the 24-px arrows 44..47 [approx].
const SMALL_ARROW_IDS := [1806, 1807, 2003, 2004]
const SMALL_ARROW_LEFT_IDS := [1806, 2003]
const SMALL_ARROW_FIRST_FRAME := 44
const SMALL_ARROW_PRESSED_STEP := 2
const ARROW_FIT_SLACK := 2


static func draw(m: ShellMenu, img: Image, i: int, c: Dictionary) -> void:
	if int(c.flags) == 1 and c.get("images") != null:
		_draw_bitmap(m, img, i, c)
	else:
		_draw_text(m, img, i, c)


## MTButton: style box 0/1/2 + font active/pushed/inactive by state.
static func _draw_text(m: ShellMenu, img: Image, i: int, c: Dictionary) -> void:
	var r: Rect2i = c.r
	var label := str(c.label)
	if not c.enabled:
		m.draw_box(img, r, ShellMenu.STYLE_INACTIVE)
		_draw_label(img, m.font("INACTIVE"), r, label, 0)
		return
	var down := m.pressed == i and m.hover == i
	m.draw_box(img, r, ShellMenu.STYLE_PUSHED if down else ShellMenu.STYLE_NORMAL)
	if m.hover == i:
		_draw_outline(img, r, SELECTED_OUTLINE_COLOR)
	if down:
		_draw_label(img, m.font("PUSHED"), r, label, PUSHED_LABEL_DY)
	else:
		_draw_label(img, m.font("ACTIVE"), r, label, 0)


static func _draw_bitmap(m: ShellMenu, img: Image, i: int, c: Dictionary) -> void:
	var down := m.pressed == i and m.hover == i
	var ims: Dictionary = c.images
	var k := int(ims.normal)
	if not c.enabled:
		k = int(ims.disabled)
	elif down:
		k = int(ims.pressed)
	var arrow := int(c.id) in SMALL_ARROW_IDS
	if arrow and k < m.corners.size() and m.corners[k] and m.corners[k].get_width() > c.r.size.x + ARROW_FIT_SLACK:
		k = SMALL_ARROW_FIRST_FRAME + (0 if int(c.id) in SMALL_ARROW_LEFT_IDS else 1) + (SMALL_ARROW_PRESSED_STEP if down else 0)
	if k < m.corners.size():
		ShellData.blit(img, m.corners[k], c.r.position.x, c.r.position.y)
	var label := str(c.label)
	if label != "" and not arrow:
		m.font("ACTIVE").draw_in(img, c.r, label, 2)


## MTButton label: centred over x2 - x1 like 0x520d8 (justify 2 over width +0x235), vertically centred.
static func _draw_label(img: Image, f: ShellFont, r: Rect2i, text: String, dy: int) -> void:
	var x := r.position.x + (r.size.x - 1 - f.width(text)) / 2
	var y := r.position.y + (r.size.y - f.height) / 2 + 1 + dy
	f.draw(img, x, y, text)


static func _draw_outline(img: Image, r: Rect2i, index: int) -> void:
	var x1 := r.position.x
	var y1 := r.position.y
	var x2 := r.end.x - 1
	var y2 := r.end.y - 1
	ShellData.line(img, x1, y1, x2, y1, index)
	ShellData.line(img, x1, y2, x2, y2, index)
	ShellData.line(img, x1, y1, x1, y2, index)
	ShellData.line(img, x2, y1, x2, y2, index)

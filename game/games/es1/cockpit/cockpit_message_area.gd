class_name CockpitMessageArea
extends RefCounted
## Fits the remake's own overlay messages ("You are piloting: ...", the objective, "E: get out of the ...", seat
## roles) into a cockpit's message area, in that HUD's font and colours, so they never spill over its windows
## (docs/formats/cockpit.md section 9.6): a multi-line window (Starsiege chat, Tribes / Tribes 2 message area)
## word-wraps and keeps the newest lines, a one-line window (Earthsiege 1 / 2 message line, Battledrome chat line)
## scrolls a long line through it. A HUD without a message area gets one in a free band of its canvas
## (make_free_rect: no meter's rect intersects it).

## Earthsiege 1 MESSAGE scroll speed floor (px per second, CockpitGauges).
const MIN_SCROLL_SPEED := 30.0
const MIN_SCROLL_SECONDS := 0.5
## Free-band search: canvas margin, row step and the least useful width (share of the canvas width).
const FREE_MARGIN := 4.0
const FREE_ROW_STEP := 2.0
const FREE_MIN_WIDTH_SHARE := 0.4


## The newest `max_lines` lines of `texts` (oldest first) word-wrapped to `width` in cockpit font `font`.
static func make_lines(canvas: CockpitCanvas, font: String, texts: PackedStringArray, width: float,
		max_lines: int) -> PackedStringArray:
	var out := PackedStringArray()
	for t in texts:
		out.append_array(make_wrapped(canvas, font, t, width))
	return out.slice(maxi(out.size() - max_lines, 0))


## `text` broken at spaces into lines no wider than `width`; a word wider than a line is cut (TextWrap).
static func make_wrapped(canvas: CockpitCanvas, font: String, text: String, width: float) -> PackedStringArray:
	return TextWrap.make_lines(text, width, func(t: String) -> float: return canvas.text_width(font, t))


## Left x of a line `text_width` wide in a one-line window `r` (text inset `inset`): fixed when it fits, else
## scrolling right to left, once through the window over the entry's lifetime (Earthsiege 1 MESSAGE line).
## `entry` is [text, seconds_left, seconds_total].
static func make_scroll_x(r: Rect2, inset: float, text_width: float, entry: Array) -> float:
	var x := r.position.x + inset
	if text_width <= r.size.x - inset * 2.0:
		return x
	var total := float(entry[2])
	var elapsed := total - float(entry[1])
	var speed := maxf(MIN_SCROLL_SPEED, (text_width + r.size.x) / maxf(total, MIN_SCROLL_SECONDS))
	return r.end.x - fmod(elapsed * speed, text_width + r.size.x)


## A band `height` high on a canvas `canvas_size`, as wide as possible, clear of every rect in `occupied`:
## the first band from the top whose widest free gap is at least FREE_MIN_WIDTH_SHARE of the canvas, else the
## widest gap found.
static func make_free_rect(occupied: Array, canvas_size: Vector2, height: float) -> Rect2:
	var best := Rect2()
	var y := FREE_MARGIN
	while y + height <= canvas_size.y - FREE_MARGIN:
		var gap := _make_widest_gap(occupied, canvas_size.x, y, height)
		if gap.size.x >= canvas_size.x * FREE_MIN_WIDTH_SHARE:
			return gap
		if gap.size.x > best.size.x:
			best = gap
		y += FREE_ROW_STEP
	return best


## The widest horizontal gap between the rects of `occupied` that cross the band [y, y + height].
static func _make_widest_gap(occupied: Array, width: float, y: float, height: float) -> Rect2:
	var band := Rect2(0.0, y, width, height)
	var spans := []
	for r in occupied:
		if (r as Rect2).intersects(band):
			spans.append(Vector2(r.position.x, r.end.x))
	spans.sort_custom(func(a, b): return a.x < b.x)
	var best := Rect2()
	var x := FREE_MARGIN
	for s in spans + [Vector2(width - FREE_MARGIN, width)]:
		if s.x - x > best.size.x:
			best = Rect2(x, y, s.x - x, height)
		x = maxf(x, s.y + 1.0)
	return best

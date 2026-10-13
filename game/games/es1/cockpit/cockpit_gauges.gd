class_name CockpitGauges
extends CockpitPainter
## The front panel's small gauges: indicator lamps and LINK / TRACK buttons, the engine output bar
## (Earthsiege 2: the energy pool), brightness buttons, throttle (speed bars and lever), mission clock and
## the scrolling message line.

const BRIGHTNESS_UP := 58
const BRIGHTNESS_DOWN := 61
const DEFAULT_LEVER := 27
const DEFAULT_LEVER_SIZE := [13.0, 6.0]
const NEAR_TARGET_RANGE := 400.0    # metres; lamp III
const LAMP_LABELS := ["I", "II", "III", "LINK", "TRACK"]
const ENGINE_LOW := 0.3
const ENGINE_BAR_HORIZONTAL := 3    # bar_type 3: horizontal; 4: vertical / dial
const MESSAGE_INSET := 2.0
const DEFAULT_MESSAGE_BOUNDS := [0, 100, 319, 110]
const DEFAULT_ENGINE_COLORS := [56, 54, 0]


func draw() -> void:
	_draw_indicators()
	_draw_engine()
	_draw_brightness()
	_draw_throttle()
	_draw_clock()


# ---- indicator lamps and LINK / TRACK buttons

func _draw_indicators() -> void:
	var g := gauge("indicators")
	var items: Array = g.get("items", [])
	var names: Array = g.get("labels", LAMP_LABELS)
	var lit := make_lamp_states()
	var lamps := int(skin.value("indicators", "lamp_count", 3))
	for i in mini(items.size(), names.size()):
		var r := CockpitCanvas.rect_of(items[i])
		var on: bool = lit.get(names[i], false)
		var lab := label("indicators", i, names[i])
		if i < lamps:
			canvas.text_centered(skin.font("indicators", "font_on" if on else "font_off"), r, lab)
		else:
			canvas.blit(canvas.dba(skin.dba("buttons"), skin.frame("indicators", "button_on" if on else "button_off")),
				r.position.x, r.position.y, r)
			canvas.text_centered(skin.font("indicators", "button_font_on" if on else "button_font_off"), r, lab)


## Lamp states by label: I / II primary / secondary group firing, III target near, LINK a wingman alive,
## TRACK a target locked.
func make_lamp_states() -> Dictionary:
	var prim := false
	var sec := false
	for w in herc.weapons:
		if w.trigger:
			if w.group == 0:
				prim = true
			else:
				sec = true
	var has_t := has_live_target()
	var near: bool = has_t and herc.global_position.distance_to(herc.target.global_position) < NEAR_TARGET_RANGE
	return {"I": prim, "II": sec, "III": near, "LINK": not wingmen().is_empty(), "TRACK": has_t}


# ---- engine output bar (Earthsiege 2: energy pool = beam capacitor)

func _draw_engine() -> void:
	var e := gauge("engine_bar")
	if e.is_empty():
		return
	var r := CockpitCanvas.rect_of(e.bar)
	var level := make_engine_level()
	var colors := skin.list("engine_bar", "colors")
	if colors.is_empty():
		colors = e.get("params", DEFAULT_ENGINE_COLORS)
	var col := canvas.color(int(colors[0]) if level > ENGINE_LOW else int(colors[1]))
	var spans = e.get("clip_spans")
	var horizontal := int(e.get("bar_type", ENGINE_BAR_HORIZONTAL)) == ENGINE_BAR_HORIZONTAL
	if horizontal and spans == null:
		canvas.fill(Rect2(r.position, Vector2(roundf(r.size.x * level), r.size.y)), col)
	elif horizontal:
		_draw_engine_spans_horizontal(r, spans, level, col)
	elif spans == null:
		var top := roundf(r.size.y * (1.0 - level))
		canvas.fill(Rect2(r.position.x, r.position.y + top, r.size.x, r.size.y - top), col)
	elif _is_ring(spans):
		_draw_engine_dial(r, spans, level, col)
	else:
		_draw_engine_spans_vertical(r, spans, level, col)


## 0..1 the bar shows: the engine output (display.engine_level) or the beam capacitor (skin "source").
func make_engine_level() -> float:
	if skin.value("engine_bar", "source", "engine") == "capacitor":
		return clampf(herc.capacitor / maxf(herc.capacitor_max, 1.0), 0.0, 1.0)
	return display.engine_level


func _draw_engine_spans_horizontal(r: Rect2, spans: Array, level: float, col: Color) -> void:
	var lim_x := r.position.x + roundf(r.size.x * level)
	for s in spans:
		var x0 := r.position.x + float(s[1])
		var x1 := minf(r.position.x + float(s[2]) + 1.0, lim_x)
		if x1 > x0:
			canvas.fill(Rect2(x0, r.position.y + float(s[0]), x1 - x0, 1), col)


## Vertical bar in an edge-table shape, filling from the bottom.
func _draw_engine_spans_vertical(r: Rect2, spans: Array, level: float, col: Color) -> void:
	var cut := _span_extent(spans).y * (1.0 - level)
	for s in spans:
		if float(s[0]) >= cut:
			canvas.fill(Rect2(r.position.x + float(s[1]), r.position.y + float(s[0]), float(s[2]) - float(s[1]) + 1.0, 1), col)


## (columns, rows) covered by the clip spans [row, x1, x2].
static func _span_extent(spans: Array) -> Vector2:
	var ext := Vector2.ZERO
	for s in spans:
		ext.y = maxf(ext.y, float(s[0]) + 1.0)
		ext.x = maxf(ext.x, float(s[2]) + 1.0)
	return ext


## Several spans on one row: a ring-shaped clip (dial).
static func _is_ring(spans: Array) -> bool:
	var per_row := {}
	for s in spans:
		per_row[s[0]] = per_row.get(s[0], 0) + 1
	return per_row.values().max() > 1


## Ring-shaped clip (dial): fills clockwise from 6 o'clock.
func _draw_engine_dial(r: Rect2, spans: Array, level: float, col: Color) -> void:
	var cc := _span_extent(spans) * 0.5
	var lim := level * TAU
	for s in spans:
		var run_x := -1.0
		for xi in range(int(s[1]), int(s[2]) + 2):
			var inside := false
			if xi <= int(s[2]):
				var v := Vector2(xi + 0.5, float(s[0]) + 0.5) - cc
				inside = fposmod(atan2(-v.x, v.y), TAU) <= lim
			if inside and run_x < 0.0:
				run_x = xi
			elif not inside and run_x >= 0.0:
				canvas.fill(Rect2(r.position.x + run_x, r.position.y + float(s[0]), xi - run_x, 1), col)
				run_x = -1.0


# ---- brightness, throttle, clock

func _draw_brightness() -> void:
	var b := gauge("brightness")
	if b.is_empty() or CockpitCanvas.rect_of(b.button_up).size.x <= 1.0:
		return
	canvas.blit_button(skin.dba("buttons"), BRIGHTNESS_UP, b.button_up)
	canvas.blit_button(skin.dba("buttons"), BRIGHTNESS_DOWN, b.button_down)
	canvas.text_centered("CPGREEN", CockpitCanvas.rect_of(b.text_up), str(display.brightness))


## Throttle speed bars (Earthsiege 1: LED bitmaps; Earthsiege 2: plain bars) and lever (throttle command).
func _draw_throttle() -> void:
	var t := gauge("throttle")
	if t.is_empty():
		return
	var vertical: bool = t.get("orientation") == "vertical"
	var fr := CockpitCanvas.rect_of(t.bar_forward)
	var rr := CockpitCanvas.rect_of(t.bar_reverse)
	var dba_name = t.get("led_dba")
	if dba_name != null:
		_draw_speed_leds(dba_name, fr, rr, vertical)
	elif t.has("lever_pbutton"):
		return    # an Earthsiege 1 LED type without bitmaps on the disc (type 0, WPN_LED1): no throttle
	else:
		_draw_speed_bars(fr, rr, vertical)
	var lv := canvas.dba(skin.dba("throttle"), int(t.get("lever_pbutton", skin.value("throttle", "lever", DEFAULT_LEVER))))
	if lv:
		_draw_lever(lv, CockpitCanvas.rect_of(t.lever), fr, rr, vertical)


func _make_speed_fractions() -> Vector2:
	return Vector2(clampf(herc.speed / maxf(herc.max_speed, 0.01), 0.0, 1.0),
		clampf(-herc.speed / maxf(herc.reverse_speed, 0.01), 0.0, 1.0))


## Forward bar: unlit frame 0, lit 1; reverse: unlit 2, lit 1.
func _draw_speed_leds(dba_name: String, fr: Rect2, rr: Rect2, vertical: bool) -> void:
	var f := _make_speed_fractions()
	var ff := f.x
	var rf := f.y
	var lit := canvas.dba(dba_name, 1)
	canvas.blit(canvas.dba(dba_name, 0), fr.position.x, fr.position.y, fr)
	canvas.blit(canvas.dba(dba_name, 2), rr.position.x, rr.position.y, rr)
	if vertical:
		var n := roundf(fr.size.y * ff)
		canvas.blit(lit, fr.position.x, fr.position.y, Rect2(fr.position.x, fr.end.y - n, fr.size.x, n))
		var m := roundf(rr.size.y * rf)
		canvas.blit(lit, rr.position.x, rr.position.y, Rect2(rr.position.x, rr.position.y, rr.size.x, m))
	else:
		var n := roundf(fr.size.x * ff)
		canvas.blit(lit, fr.position.x, fr.position.y, Rect2(fr.position.x, fr.position.y, n, fr.size.y))
		var m := roundf(rr.size.x * rf)
		canvas.blit(lit, rr.position.x, rr.position.y, Rect2(rr.end.x - m, rr.position.y, m, rr.size.y))


## Earthsiege 2 (BarGraphV 0x439344): forward speed fills its bar from the bottom, reverse its bar from
## the top (horizontal: from the meeting point outwards).
func _draw_speed_bars(fr: Rect2, rr: Rect2, vertical: bool) -> void:
	var f := _make_speed_fractions()
	var fc := skin_color("throttle", "bar_color", C_GREEN)
	var rc := skin_color("throttle", "reverse_color", C_YELLOW)
	if vertical:
		var n := roundf(fr.size.y * f.x)
		canvas.fill(Rect2(fr.position.x, fr.end.y - n, fr.size.x, n), fc)
		canvas.fill(Rect2(rr.position.x, rr.position.y, rr.size.x, roundf(rr.size.y * f.y)), rc)
	else:
		canvas.fill(Rect2(fr.position.x, fr.position.y, roundf(fr.size.x * f.x), fr.size.y), fc)
		var m := roundf(rr.size.x * f.y)
		canvas.fill(Rect2(rr.end.x - m, rr.position.y, m, rr.size.y), rc)


## The lever's zero is where the two bars meet.
func _draw_lever(lv: Texture2D, lr: Rect2, fr: Rect2, rr: Rect2, vertical: bool) -> void:
	var ls: Array = skin.value("throttle", "lever_size", DEFAULT_LEVER_SIZE)
	var lever_size := Vector2(float(ls[0]), float(ls[1]))
	var th := herc.throttle
	if vertical:
		var zero := (fr.end.y + rr.position.y) * 0.5
		var y := lerpf(zero, fr.position.y, th) if th >= 0.0 else lerpf(zero, rr.end.y, -th)
		canvas.blit(lv, lr.position.x, clampf(roundf(y - lever_size.y * 0.5), lr.position.y, lr.end.y - lever_size.y))
	else:
		var zero := (rr.end.x + fr.position.x) * 0.5
		var x := lerpf(zero, fr.end.x, th) if th >= 0.0 else lerpf(zero, rr.position.x, -th)
		canvas.blit(lv, clampf(roundf(x - lever_size.x * 0.5), lr.position.x, lr.end.x - lever_size.x), lr.position.y)


func _draw_clock() -> void:
	var c := gauge("clock")
	if c.is_empty():
		return
	var r := CockpitCanvas.rect_of(c.text)
	canvas.text("CPBLUE", r.position.x, r.position.y, make_clock_text(), r)


# ---- message line

## The newest message on the panel line (look-down view) or the 3D-view line, scrolling when long. A line
## shown in every view ("all_views", Earthsiege 2's message port) keeps its screen position when looking down.
func draw_message(panel_view: bool) -> void:
	var m := display.make_newest_entry()
	var r := make_message_rect(panel_view)
	if not m.is_empty() and r.has_area():
		_draw_scrolling(m, r)


## The message line's canvas rect in the panel view or the 3D view (no area: none in this view).
func make_message_rect(panel_view: bool) -> Rect2:
	var g := gauge("message_panel")
	var r := CockpitCanvas.rect_of(g.get("bounds", DEFAULT_MESSAGE_BOUNDS))
	var on_panel := r.position.y >= display.panel_top
	if panel_view and g.get("all_views", false):
		r.position.y += display.panel_top
	elif panel_view and not on_panel:
		return Rect2()
	elif not panel_view and display.look_down != on_panel:
		r = CockpitCanvas.rect_of(gauge("message_view").get("bounds", DEFAULT_MESSAGE_BOUNDS))
	return r


func _draw_scrolling(m: Array, r: Rect2) -> void:
	var font := skin.font("message", "font")
	var s: String = m[0]
	var x := CockpitMessageArea.make_scroll_x(r, MESSAGE_INSET, canvas.text_width(font, s), m)
	canvas.text(font, roundf(x), r.position.y + floorf((r.size.y - 8.0) * 0.5), s, r)

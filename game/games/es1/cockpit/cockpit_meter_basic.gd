class_name CockpitMeterBasic
extends CockpitMeterPainter
## HUD meters made only of art, bars and texts (Tribes / Tribes 2 frames, health / energy / heat bars, speed,
## altitude, clock, sensor ping, vehicle icon, crew seats; the Tribes compass; message windows). Decoded layouts:
## tools/tribes_vehicle_hud.py (docs/formats/cockpit.md section 9).

const DEFAULT_MESSAGE_LINES := 3
const MESSAGE_INSET := 2.0
const COMPASS_MARKS := ["N", "E", "S", "W"]
## Tribes 2 window art: 9 frames (corners, edges, centre) around the window rect.
const NINE_SLICE_FRAMES := 9
## Waypoint dot on the Tribes compass dial (layout pixels).
const WAYPOINT_DOT := 3.0


## Remake heading tape: HUD green, waypoint in the friend-or-foe neutral colour; text in the fallback font.
const TAPE_COLOR := Color(0.35, 1.0, 0.45, 0.85)
const TAPE_FONT_SIZE := 10


func draw_meter(m: Dictionary) -> void:
	var mod := meter_mod(m)
	if str(m.get("kind", "")) == "heading_tape":
		_draw_heading_tape(m, mod)
		return
	if m.has("nine_slice"):
		_draw_nine_slice(m.nine_slice, CockpitCanvas.rect_of(m.rect), mod)
	draw_layers(m, mod)
	if m.has("bar"):
		var b: Dictionary = m.bar.duplicate()
		if m.has("dba"):
			b["dba"] = m.dba
		draw_bar(b, mod)
	match str(m.kind):
		"heading":
			_draw_compass(m, mod)
		"messages":
			_draw_messages(m, mod)
		"crew":
			_draw_crew(m, mod)
		_:
			_draw_texts(m, mod)


func _draw_texts(m: Dictionary, mod: Color) -> void:
	if m.has("text"):
		draw_text(m.text, make_value_text(m.text), mod)
	if m.has("label"):
		draw_text(m.label, str(m.label.get("value", "")), mod)


## The compass letters turn with the view heading around the dial centre (Tribes CompassHud; the mark radius
## and letter placement are estimates, hud.json confidence L).
func _draw_compass(m: Dictionary, mod: Color) -> void:
	if not m.has("center"):
		return
	var c := Vector2(float(m.center[0]), float(m.center[1]))
	var t: Dictionary = m.get("text", {"font": m.get("font", "")})
	var font := str(t.get("font", m.get("font", "")))
	var tint: Color = make_color(t.color) if t.has("color") else CockpitCanvas.NO_TINT
	var radius := float(m.get("mark_radius", 20))
	var heading := view_yaw()
	_draw_compass_waypoint(c, radius, heading, mod)
	for i in COMPASS_MARKS.size():
		var a := float(i) * PI * 0.5 + heading
		var p := c + Vector2(sin(a), -cos(a)) * radius
		var s: String = COMPASS_MARKS[i]
		canvas.text(font, p.x - floorf(canvas.text_width(font, s) * 0.5), p.y - floorf(canvas.font_height(font) * 0.5), s,
			CockpitCanvas.NO_CLIP, tint, mod)


## The current waypoint on the dial: a dot at its bearing, turned with the letters (remake, playtest A7).
func _draw_compass_waypoint(c: Vector2, radius: float, heading: float, mod: Color) -> void:
	for m in PersonalWaypoints.make_marks(herc.global_position):
		var pa := deg_to_rad(HeadingFrame.make_bearing_deg(herc.global_position, m.pos)) + heading
		var pp := (c + Vector2(sin(pa), -cos(pa)) * (radius + WAYPOINT_DOT * 2.0)).round()
		canvas.fill(Rect2(pp - Vector2(1, 2), Vector2(2, 4)), PersonalWaypoints.COLOR * mod)
	var wp := HeadingFrame.make_current_waypoint(herc, display.battle)
	if wp.is_empty():
		return
	var a := deg_to_rad(HeadingFrame.make_bearing_deg(herc.global_position, wp.pos)) + heading
	var p := (c + Vector2(sin(a), -cos(a)) * (radius + WAYPOINT_DOT * 2.0)).round()
	canvas.fill(Rect2(p - Vector2.ONE * WAYPOINT_DOT * 0.5, Vector2.ONE * WAYPOINT_DOT), TargetInfo.NEUTRAL_COLOR * mod)


func _draw_heading_tape(m: Dictionary, mod: Color) -> void:
	var t: Array = m.tape
	var tape := Rect2(float(t[0]), float(t[1]), float(t[2]) - float(t[0]), float(t[3]) - float(t[1]))
	HudCompass.draw(canvas.item, tape, herc, HeadingFrame.make_current_waypoint(herc, display.battle),
		{"font": ThemeDB.fallback_font, "font_size": TAPE_FONT_SIZE, "color": TAPE_COLOR * mod,
			"marker_color": TargetInfo.NEUTRAL_COLOR * mod})


## The newest cockpit messages and the standing hint, oldest first, word-wrapped to the window's text rect and
## clipped to the window (CockpitMessageArea).
func _draw_messages(m: Dictionary, mod: Color) -> void:
	var t: Dictionary = m.get("text", {})
	var font := _message_font(m)
	var tint: Color = make_color(t.color) if t.has("color") else CockpitCanvas.NO_TINT
	var clip := CockpitCanvas.rect_of(m.rect)
	var origin := _message_origin(m)
	var width := clip.end.x - MESSAGE_INSET - float(origin[0])
	var lines := CockpitMessageArea.make_lines(canvas, font, display.make_message_texts(), width,
		make_message_line_count(m))
	var y := float(origin[1])
	for line in lines:
		canvas.text(font, float(origin[0]), y, line, clip, tint, mod)
		y += canvas.font_height(font)


## Lines the message window `m` shows: the layout's line count, cut to the lines of its font that fit its rect
## (the Tribes 1 chatDisplayHud's line count is a guess, its rect is the original's: the newest line - the
## standing hint - must never fall below the window).
func make_message_line_count(m: Dictionary) -> int:
	var wanted := int(m.get("text", {}).get("lines", DEFAULT_MESSAGE_LINES))
	var height := CockpitCanvas.rect_of(m.rect).end.y - float(_message_origin(m)[1])
	return clampi(floori(height / maxf(canvas.font_height(_message_font(m)), 1.0)), 1, maxi(wanted, 1))


static func _message_font(m: Dictionary) -> String:
	return str(m.get("text", {}).get("font", m.get("fonts", {}).get("new", m.get("font", ""))))


static func _message_origin(m: Dictionary) -> Array:
	var t: Dictionary = m.get("text", {})
	return t.get("at", t.get("rect", [m.rect[0] + MESSAGE_INSET, m.rect[1] + MESSAGE_INSET]))


## Tribes 2 vPassengerHud: a dot per taken seat; the remake's vehicle has its pilot in seat 0.
func _draw_crew(m: Dictionary, mod: Color) -> void:
	var seats: Array = m.get("seats", [])
	if not seats.is_empty():
		draw_layer(seats[0], mod)


func _draw_nine_slice(n: Dictionary, r: Rect2, mod: Color) -> void:
	var frames: Array = n.get("frames", [])
	if frames.size() < NINE_SLICE_FRAMES:
		return
	var k := float(n.get("corner", 8))
	var xs := [r.position.x, r.position.x + k, r.end.x - k, r.end.x]
	var ys := [r.position.y, r.position.y + k, r.end.y - k, r.end.y]
	for row in 3:
		for col in 3:
			var tex := canvas.dba(str(n.dba), int(frames[row * 3 + col]))
			if tex:
				canvas.item.draw_texture_rect(tex, Rect2(xs[col], ys[row], xs[col + 1] - xs[col], ys[row + 1] - ys[row]), false, mod)

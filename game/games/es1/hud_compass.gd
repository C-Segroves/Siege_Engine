class_name HudCompass
extends RefCounted
## The remake's heading tape with the current waypoint's marker (playtest 2026-10-11 A7), for every view whose own
## instruments have no compass: the plain HUD (soldiers on foot, vehicles without a cockpit layout) and the decoded
## HUDs without a heading meter (Starsiege, Battledrome). Same frame as every radar and the Earthsiege tapes
## (HeadingFrame). Drawn with plain canvas calls on any CanvasItem, in that item's coordinates.

## Degrees from the centre to either end of the tape.
const HALF_SPAN_DEG := 60.0
const MINOR_TICK_DEG := 10.0
const MAJOR_TICK_DEG := 30.0
const LETTERS := {0: "N", 90: "E", 180: "S", 270: "W"}
const TICK_MINOR := 4.0
const TICK_MAJOR := 8.0
const CARET := 5.0
const MARKER := 5.0


## The tape: `rect` is its band (ticks hang from the top edge, labels under them), `style` {font, font_size,
## color, marker_color}. `heading_deg` from HeadingFrame.make_heading_deg; `waypoint` from
## HeadingFrame.make_current_waypoint ({} = none); `viewer` gives its bearing and distance.
static func draw(item: CanvasItem, rect: Rect2, viewer: Herc, waypoint: Dictionary, style: Dictionary) -> void:
	var heading := HeadingFrame.make_heading_deg(viewer)
	var px_per_deg := rect.size.x * 0.5 / HALF_SPAN_DEG
	var cx := rect.get_center().x
	var col: Color = style.color
	item.draw_line(Vector2(rect.position.x, rect.position.y), Vector2(rect.end.x, rect.position.y), col, 1.0)
	var first := ceilf((heading - HALF_SPAN_DEG) / MINOR_TICK_DEG) * MINOR_TICK_DEG
	var deg := first
	while deg <= heading + HALF_SPAN_DEG:
		_draw_tick(item, Vector2(cx + (deg - heading) * px_per_deg, rect.position.y), int(fposmod(deg, 360.0)), style)
		deg += MINOR_TICK_DEG
	item.draw_colored_polygon(PackedVector2Array([Vector2(cx, rect.position.y), Vector2(cx - CARET, rect.position.y - CARET),
		Vector2(cx + CARET, rect.position.y - CARET)]), col)
	if not waypoint.is_empty():
		_draw_waypoint(item, rect, viewer, waypoint, style)
	_draw_personal(item, rect, viewer, style)
	_draw_team(item, rect, viewer, style)


## Teammates: small team-coloured ticks hanging under the tape (only within its span) with a short label.
static func _draw_team(item: CanvasItem, rect: Rect2, viewer: Herc, style: Dictionary) -> void:
	for m in HeadingFrame.make_team_marks(viewer):
		var rel := HeadingFrame.make_relative_bearing_deg(viewer, m.pos)
		if absf(rel) > HALF_SPAN_DEG:
			continue
		var x := make_marker_x(rect, rel)
		var y := rect.end.y
		item.draw_colored_polygon(PackedVector2Array([Vector2(x, y), Vector2(x - 3, y + 6), Vector2(x + 3, y + 6)]), m.color)
		item.draw_string(style.font, Vector2(x - 8.0, y + 6.0 + style.font_size), m.label, HORIZONTAL_ALIGNMENT_LEFT, -1,
			maxi(style.font_size - 2, 8), m.color)


## The player's own waypoints: cyan squares on the tape (below the mission marker) with "P1 d m" under the tape.
static func _draw_personal(item: CanvasItem, rect: Rect2, viewer: Herc, style: Dictionary) -> void:
	var at: float = rect.position.y + TICK_MAJOR + style.font_size + 2.0
	for m in PersonalWaypoints.make_marks(viewer.global_position):
		var x := make_marker_x(rect, HeadingFrame.make_relative_bearing_deg(viewer, m.pos))
		item.draw_rect(Rect2(x - MARKER * 0.6, rect.position.y + 1.0, MARKER * 1.2, MARKER * 1.2), PersonalWaypoints.COLOR)
		item.draw_string(style.font, Vector2(x - 14.0, at + style.font_size), "%s %d m" % [m.label, int(m.distance)],
			HORIZONTAL_ALIGNMENT_LEFT, -1, style.font_size, PersonalWaypoints.COLOR)


static func _draw_tick(item: CanvasItem, at: Vector2, deg: int, style: Dictionary) -> void:
	var major := deg % int(MAJOR_TICK_DEG) == 0
	item.draw_line(at, at + Vector2(0, TICK_MAJOR if major else TICK_MINOR), style.color, 1.0)
	if not major:
		return
	var text: String = LETTERS.get(deg, str(deg / 10))
	var size: int = style.font_size
	var w := (style.font as Font).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	item.draw_string(style.font, at + Vector2(-w * 0.5, TICK_MAJOR + size), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, style.color)


## The waypoint's marker on the tape (pinned to the nearer end when it lies outside the span) and "WP n  d m".
static func _draw_waypoint(item: CanvasItem, rect: Rect2, viewer: Herc, waypoint: Dictionary, style: Dictionary) -> void:
	var x := make_marker_x(rect, HeadingFrame.make_relative_bearing_deg(viewer, waypoint.pos))
	var y := rect.position.y
	var mc: Color = style.marker_color
	item.draw_colored_polygon(PackedVector2Array([Vector2(x, y + 1), Vector2(x - MARKER, y + MARKER * 2.0),
		Vector2(x + MARKER, y + MARKER * 2.0)]), mc)
	var flat: Vector3 = waypoint.pos - viewer.global_position
	var text := "WP %s  %d m" % [waypoint.label, int(Vector2(flat.x, flat.z).length())]
	item.draw_string(style.font, Vector2(rect.end.x + MARKER * 2.0, y + style.font_size), text, HORIZONTAL_ALIGNMENT_LEFT,
		-1, style.font_size, mc)


## Tape position (x) of a bearing `rel_deg` relative to the heading, for tests: the band's centre +- half its width.
static func make_marker_x(rect: Rect2, rel_deg: float) -> float:
	return rect.get_center().x + clampf(rel_deg, -HALF_SPAN_DEG, HALF_SPAN_DEG) * rect.size.x * 0.5 / HALF_SPAN_DEG

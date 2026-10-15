class_name UnitSymbols
extends RefCounted
## The remake's map symbology for extraction raids and every map without a game icon: the viewer and his team are
## arrows pointing the way they face; enemies and other radar contacts are plain squares (no direction); extraction
## zones and task targets are labelled markers. Drawn with canvas calls on any CanvasItem.

const ARROW_SIZE := 6.0
const SQUARE_SIZE := 4.0
const DIAMOND_SIZE := 6.0


## An arrow at `at` pointing along screen direction `facing` (any length > 0; zero points up).
static func draw_arrow(canvas: CanvasItem, at: Vector2, facing: Vector2, color: Color, scale := 1.0) -> void:
	var f := facing.normalized() if facing.length() > 0.001 else Vector2.UP
	var side := Vector2(-f.y, f.x)
	var s := ARROW_SIZE * scale
	canvas.draw_colored_polygon(PackedVector2Array([at + f * s * 1.3, at - f * s * 0.9 + side * s * 0.8,
		at - f * s * 0.3, at - f * s * 0.9 - side * s * 0.8]), color)
	canvas.draw_polyline(PackedVector2Array([at + f * s * 1.3, at - f * s * 0.9 + side * s * 0.8, at - f * s * 0.3,
		at - f * s * 0.9 - side * s * 0.8, at + f * s * 1.3]), Color.BLACK, 1.0)


## A plain square contact at `at`.
static func draw_square(canvas: CanvasItem, at: Vector2, color: Color, scale := 1.0) -> void:
	var h := SQUARE_SIZE * scale
	canvas.draw_rect(Rect2(at - Vector2.ONE * h, Vector2.ONE * h * 2.0), color)
	canvas.draw_rect(Rect2(at - Vector2.ONE * h, Vector2.ONE * h * 2.0), Color.BLACK, false, 1.0)


## A diamond with a label right of it (extraction zones, task targets).
static func draw_labeled_marker(canvas: CanvasItem, at: Vector2, label: String, color: Color, font: Font, font_size: int) -> void:
	var d := DIAMOND_SIZE
	canvas.draw_colored_polygon(PackedVector2Array([at + Vector2(0, -d), at + Vector2(d, 0), at + Vector2(0, d), at + Vector2(-d, 0)]), color)
	canvas.draw_polyline(PackedVector2Array([at + Vector2(0, -d), at + Vector2(d, 0), at + Vector2(0, d), at + Vector2(-d, 0), at + Vector2(0, -d)]), Color.BLACK, 1.0)
	canvas.draw_string_outline(font, at + Vector2(d + 3.0, font_size * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color(0, 0, 0, 0.85))
	canvas.draw_string(font, at + Vector2(d + 3.0, font_size * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## Screen direction (map: +x east, +y south; radar: heading up) of unit `u`'s facing, `heading` = the frame's rotation
## (rad; 0 for a north-up map, the viewer's HeadingFrame.make_heading for a heading-up radar).
static func make_facing(u: Node3D, heading := 0.0) -> Vector2:
	var fwd := -u.global_basis.z
	if u is Herc:
		fwd = -(u as Herc).sight_basis().z
	return Vector2(fwd.x, fwd.z).rotated(heading)

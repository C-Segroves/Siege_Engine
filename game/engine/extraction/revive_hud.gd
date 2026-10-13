class_name ReviveHud
extends Control
## The downed / revive instruments of an extraction raid (ExtractionRevive; every peer, for its local player):
##   downed     a red veil, "DOWNED", the bleed-out time and the revive progress while a teammate works on him
##   reviving   "Reviving NAME" with a progress bar while the local player holds interact by a downed teammate
##   world      a marker on every downed soldier allied with the local player

const VEIL_COLOR := Color(0.55, 0.0, 0.0, 0.35)
const TEXT_COLOR := Color(1.0, 0.4, 0.35)
const BAR_COLOR := Color(0.4, 1.0, 0.5)
const BAR_BACK := Color(0.0, 0.0, 0.0, 0.6)
const BAR_SIZE := Vector2(320, 14)
const TITLE_FONT_SIZE := 42
const FONT_SIZE := 18
const MARKER_SIZE := 8.0

var revive: ExtractionRevive
var font: Font


func _init(p_revive: ExtractionRevive) -> void:
	revive = p_revive
	name = "ReviveHud"


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	size = get_viewport_rect().size
	queue_redraw()


func _draw() -> void:
	var me := revive.director.battle.player as Infantry
	if me == null:
		return
	_draw_markers(me)
	if DownedState.is_downed(me):
		_draw_downed(me)
	else:
		_draw_reviving()


## The text under the DOWNED title: "bleeding out 0:31 - a teammate can revive you" ("" when not downed).
func make_downed_text(me: Infantry) -> String:
	var state: Dictionary = revive.states.get(me.net_id, {})
	if state.is_empty():
		return ""
	var left := maxi(int(ceil(float(state.left))), 0)
	var text := "bleeding out %d:%02d" % [left / 60, left % 60]
	return text + ("  -  being revived" if int(state.reviver) != 0 else "  -  a teammate can revive you")


func _draw_downed(me: Infantry) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), VEIL_COLOR)
	_draw_centered("DOWNED", size.y * 0.32, TITLE_FONT_SIZE, TEXT_COLOR)
	_draw_centered(make_downed_text(me), size.y * 0.32 + TITLE_FONT_SIZE, FONT_SIZE, TEXT_COLOR)
	var state: Dictionary = revive.states.get(me.net_id, {})
	if int(state.get("reviver", 0)) != 0:
		_draw_bar(size.y * 0.32 + TITLE_FONT_SIZE * 1.6, float(state.progress))


func _draw_reviving() -> void:
	var r := revive.make_local_revive_state()
	if r.is_empty():
		return
	_draw_centered("Reviving %s - keep holding %s" % [str(r.name), InfantryInteraction.make_key_text()], size.y * 0.62, FONT_SIZE, BAR_COLOR)
	_draw_bar(size.y * 0.62 + FONT_SIZE * 0.8, float(r.progress))


func _draw_bar(y: float, fraction: float) -> void:
	var at := Vector2((size.x - BAR_SIZE.x) * 0.5, y)
	draw_rect(Rect2(at, BAR_SIZE), BAR_BACK)
	draw_rect(Rect2(at, Vector2(BAR_SIZE.x * clampf(fraction, 0.0, 1.0), BAR_SIZE.y)), BAR_COLOR)


func _draw_markers(me: Infantry) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	for net_id in revive.states:
		var s := revive.director.battle.vehicles.get(int(net_id)) as Infantry
		if s == null or s == me or not TeamRelations.is_allied(me.team, s.team):
			continue
		var p := s.global_position + Vector3.UP * 1.0
		if cam.is_position_behind(p):
			continue
		var at := cam.unproject_position(p)
		draw_rect(Rect2(at - Vector2.ONE * MARKER_SIZE * 0.5, Vector2.ONE * MARKER_SIZE), TEXT_COLOR, false, 2.0)
		draw_string(font, at + Vector2(MARKER_SIZE, -MARKER_SIZE), "DOWNED %s %d m" % [s.display_name, int(p.distance_to(me.global_position))],
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 4, TEXT_COLOR)


func _draw_centered(text: String, y: float, font_size: int, color: Color) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string_outline(font, Vector2((size.x - w) * 0.5, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(0, 0, 0, 0.8))
	draw_string(font, Vector2((size.x - w) * 0.5, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

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
## Rows of the downed block: title, text, progress bar; of the reviving block: prompt, progress bar.
const TITLE_ROW := 50.0
const TEXT_ROW := 26.0
const BAR_ROW := 20.0

var revive: ExtractionRevive
var font: Font


func _init(p_revive: ExtractionRevive) -> void:
	revive = p_revive
	name = "ReviveHud"
	ServerProfile.apply_client_only(self)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	size = get_viewport_rect().size
	_declare_elements()
	queue_redraw()


## Tells the layout which block is up: the veil and the downed block, or the reviving prompt.
func _declare_elements() -> void:
	var layout := HudLayout.of(self)
	var me := revive.director.battle.player as Infantry
	var downed := me != null and DownedState.is_downed(me)
	var reviving := me != null and not downed and not revive.make_local_revive_state().is_empty()
	var most: Vector2 = HudLayout.ELEMENTS[&"revive_banner"].max
	layout.declare(&"downed_veil", Vector2.ONE if downed else Vector2.ZERO)
	layout.declare(&"revive_banner", Vector2(most.x, TITLE_ROW + TEXT_ROW + BAR_ROW) if downed else
		(Vector2(most.x, TEXT_ROW + BAR_ROW) if reviving else Vector2.ZERO))


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
	var layout := HudLayout.of(self)
	draw_rect(layout.rect_of(&"downed_veil"), VEIL_COLOR)
	var block := layout.rect_of(&"revive_banner")
	_draw_centered("DOWNED", block, block.position.y + TITLE_FONT_SIZE, TITLE_FONT_SIZE, TEXT_COLOR)
	_draw_centered(make_downed_text(me), block, block.position.y + TITLE_ROW + FONT_SIZE, FONT_SIZE, TEXT_COLOR)
	var state: Dictionary = revive.states.get(me.net_id, {})
	if int(state.get("reviver", 0)) != 0:
		_draw_bar(block, block.position.y + TITLE_ROW + TEXT_ROW, float(state.progress))


func _draw_reviving() -> void:
	var r := revive.make_local_revive_state()
	var block := HudLayout.of(self).rect_of(&"revive_banner")
	if r.is_empty() or block.size == Vector2.ZERO:
		return
	_draw_centered("Reviving %s - keep holding %s" % [str(r.name), InfantryInteraction.make_key_text()], block, block.position.y + FONT_SIZE,
		FONT_SIZE, BAR_COLOR)
	_draw_bar(block, block.position.y + TEXT_ROW, float(r.progress))


func _draw_bar(block: Rect2, y: float, fraction: float) -> void:
	var at := Vector2(block.position.x + (block.size.x - BAR_SIZE.x) * 0.5, y)
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


func _draw_centered(text: String, block: Rect2, y: float, font_size: int, color: Color) -> void:
	var w := minf(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x, block.size.x)
	var at := Vector2(block.position.x + (block.size.x - w) * 0.5, y)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, block.size.x, font_size, 4, Color(0, 0, 0, 0.8))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, block.size.x, font_size, color)

class_name Nameplates
extends CanvasLayer
## Names over teammates' heads (playtest 2026-10-11 A5, a remake addition): every living, visible unit allied with
## the local player (TeamRelations; wingmen, LAN teammates, friendly soldiers) gets its display name (the pilot's LAN
## name for a player) in the friend colour, centred just above the top of its model, fading out with distance.
## Drawn in 2D on a layer below the battle overlay (BattleOverlay, layer 1), so every HUD panel covers it; a plate
## that would touch a HUD window (`occupied_provider`) is not drawn at all. The text shrinks with distance between
## MIN_FONT_SIZE and MAX_FONT_SIZE, so a nearby ally's name never fills the screen.

const LAYER := 0
const FADE_START := 150.0             # fully opaque up to this distance (m)
const FADE_END := 700.0               # invisible beyond this distance (m)
const RISE := 0.4                     # metres above the model's bounding box top
const MAX_FONT_SIZE := 15
const MIN_FONT_SIZE := 10
## Font size = FONT_SIZE_AT_DISTANCE / distance (m), clamped.
const FONT_SIZE_AT_DISTANCE := 450.0
const OUTLINE_SIZE := 4
const OUTLINE_COLOR := Color(0, 0, 0, 0.8)
const GAP := 2.0                      # pixels between the anchor point and the text's bottom
const VEHICLES := "vehicles"

## Supplies the viewer: an object with a `player` (Herc) property, the battle.
var source: Node
## func() -> Array of screen Rect2 the HUD in use draws into (BattleChat.make_occupied_rects); none when empty.
var occupied_provider := Callable()
## This frame's plates: [{unit, text, rect (screen), font_size, alpha}] (tests read them).
var plates: Array = []
var _canvas: Control
var _font: Font
var _tops := {}                       # unit -> bounding box top above its origin (m), measured once


func _init(p_source: Node) -> void:
	source = p_source
	name = "Nameplates"
	ServerProfile.apply_client_only(self)
	layer = LAYER
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_plates)
	add_child(_canvas)
	_font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	apply_plates()
	_canvas.size = _canvas.get_viewport_rect().size
	_canvas.queue_redraw()


## Rebuilds this frame's plates from the viewer, its camera and the HUD's windows.
func apply_plates() -> void:
	plates.clear()
	var viewer: Herc = source.get("player")
	var cam := _canvas.get_viewport().get_camera_3d()
	if viewer == null or not is_instance_valid(viewer) or cam == null:
		return
	var occupied: Array = occupied_provider.call() if occupied_provider.is_valid() else []
	for unit in make_teammates(viewer):
		var plate := _make_plate(unit, cam)
		if not plate.is_empty() and not _is_covered(plate.rect, occupied):
			plates.append(plate)
	_forget_gone()


## Units that get a plate seen from `viewer`: alive, visible, allied, not the viewer. Soldiers sitting visibly in a
## Tribes vehicle get their own plates on their seats and their vehicle none; the riders of the viewer's own
## vehicle (his own soldier among them) get none.
static func make_teammates(viewer: Herc) -> Array:
	var out := []
	var tree := viewer.get_tree()
	var carried := {}
	for rider in tree.get_nodes_in_group(Infantry.SEATED_RIDERS):
		var s := rider as Infantry
		carried[s.seat.vehicle] = true
		if s != viewer and s.seat.vehicle != viewer and s.alive and TargetInfo.is_friendly(viewer, s):
			out.append(s)
	for unit in tree.get_nodes_in_group(VEHICLES):
		if unit != viewer and unit is Herc and unit.alive and unit.is_visible_in_tree() and not carried.has(unit) \
				and TargetInfo.is_friendly(viewer, unit):
			out.append(unit)
	return out


## Opacity of a plate `distance` metres away.
static func make_alpha(distance: float) -> float:
	return clampf(1.0 - (distance - FADE_START) / (FADE_END - FADE_START), 0.0, 1.0)


## Font size of a plate `distance` metres away.
static func make_font_size(distance: float) -> int:
	return clampi(int(FONT_SIZE_AT_DISTANCE / maxf(distance, 1.0)), MIN_FONT_SIZE, MAX_FONT_SIZE)


## The plate of `unit` this frame, {} when it shows none.
func plate_of(unit: Node) -> Dictionary:
	for p in plates:
		if p.unit == unit:
			return p
	return {}


## World point the plate sits on: just above the top of the unit's model.
func make_anchor(unit: Herc) -> Vector3:
	if not _tops.has(unit):
		_tops[unit] = unit.make_body_size().y if unit.shape != null else TargetInfo.make_height(unit)
	return unit.global_position + Vector3.UP * (float(_tops[unit]) + RISE)


func _make_plate(unit: Herc, cam: Camera3D) -> Dictionary:
	var anchor := make_anchor(unit)
	var distance := cam.global_position.distance_to(unit.global_position)
	var alpha := make_alpha(distance)
	if alpha <= 0.0 or cam.is_position_behind(anchor):
		return {}
	var text := TargetInfo.make_name(unit)
	var size := make_font_size(distance)
	var extent := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	var at := cam.unproject_position(anchor)
	var rect := Rect2(at.x - extent.x * 0.5, at.y - GAP - extent.y, extent.x, extent.y)
	return {"unit": unit, "text": text, "rect": rect, "font_size": size, "alpha": alpha}


static func _is_covered(rect: Rect2, occupied: Array) -> bool:
	return occupied.any(func(r): return (r as Rect2).intersects(rect))


func _forget_gone() -> void:
	for unit in _tops.keys():
		if not is_instance_valid(unit):
			_tops.erase(unit)


func _draw_plates() -> void:
	for p in plates:
		var r: Rect2 = p.rect
		var base := Vector2(r.position.x, r.end.y - _font.get_descent(p.font_size))
		var outline := Color(OUTLINE_COLOR, OUTLINE_COLOR.a * p.alpha)
		_canvas.draw_string_outline(_font, base, p.text, HORIZONTAL_ALIGNMENT_LEFT, -1, p.font_size, OUTLINE_SIZE, outline)
		_canvas.draw_string(_font, base, p.text, HORIZONTAL_ALIGNMENT_LEFT, -1, p.font_size,
			Color(TargetInfo.FRIEND_COLOR, p.alpha))

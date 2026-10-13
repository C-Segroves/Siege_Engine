class_name CockpitOccupancy
## The canvas rects a cockpit's front view keeps for itself, which the chat panel's automatic placement avoids
## (ChatPlacement, docs/formats/cockpit.md section 9.6):
##   HUD layouts (Starsiege, Battledrome, Tribes): every meter window plus the message window;
##   panel cockpits (Earthsiege 1 / 2): every instrument rect of the layout seen in the front view (weapon slots,
##   indicators, HUD tapes and target area, the 3D-view message line) plus the instrument panel below the front
##   view's 3D area (layout views[0]). The HUD gauge's own bounds are the whole 3D area it may draw on (GAU 0x450,
##   cockpit.md section 3), not a window, so they are left out.

const HUD_GAUGE := "hud"
const HUD_AREA_KEY := "bounds"


static func make_rects(cockpit: CockpitDisplay) -> Array:
	var rects: Array = cockpit.make_window_rects()
	var message := cockpit.make_message_rect()
	if message.has_area():
		rects.append(message)
	if cockpit.is_hud_only():
		return rects
	var view := Rect2(Vector2.ZERO, cockpit.canvas_size)
	_append_rects(make_gauges_without_hud_area(cockpit.gauges), view, rects)
	_append_rects(cockpit.layout.get("weapon_slots", []), view, rects)
	var top := make_panel_top(cockpit.layout, cockpit.canvas_size.y)
	rects.append(Rect2(0.0, top, cockpit.canvas_size.x, cockpit.canvas_size.y - top))
	return rects


## `gauges` without the HUD gauge's bounds (its drawing area).
static func make_gauges_without_hud_area(gauges: Dictionary) -> Dictionary:
	var out := gauges.duplicate()
	if out.get(HUD_GAUGE) is Dictionary:
		var hud: Dictionary = (out[HUD_GAUGE] as Dictionary).duplicate()
		hud.erase(HUD_AREA_KEY)
		out[HUD_GAUGE] = hud
	return out


## Where the instrument panel starts in the front view: the bottom of the front view's 3D viewport.
static func make_panel_top(layout: Dictionary, canvas_height: float) -> float:
	var views: Array = layout.get("views", [])
	if views.is_empty() or not (views[0] is Dictionary):
		return canvas_height
	var vp: Array = views[0].get("viewport", [])
	return float(vp[3]) if vp.size() == 4 and float(vp[3]) > 0.0 else canvas_height


## Every [x0, y0, x1, y1] rect with an area found anywhere in `data` that lies on `view`.
static func _append_rects(data: Variant, view: Rect2, out: Array) -> void:
	if data is Dictionary:
		for v in data.values():
			_append_rects(v, view, out)
	elif data is Array and _is_rect(data):
		var r := CockpitCanvas.rect_of(data)
		if r.intersects(view):
			out.append(r)
	elif data is Array:
		for v in data:
			_append_rects(v, view, out)


static func _is_rect(a: Array) -> bool:
	if a.size() != 4 or not a.all(func(v): return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT):
		return false
	return float(a[2]) > float(a[0]) and float(a[3]) > float(a[1])

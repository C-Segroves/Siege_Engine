class_name CockpitMeters
extends CockpitPainter
## The HUD of a game that drew its instruments straight over the 3D view (docs/formats/cockpit.md section 9):
## the layout's "meters" (tools/cockpit_hud_layouts.py), each drawn by the painter of its kind. A flyer whose
## HUD has no altimeter gets the remake's flight readout (FLIGHT_METER) on top; a HUD without a message window
## gets the remake's message window in a free band (CockpitMessageArea.make_free_rect); a HUD without a compass
## gets the remake's heading tape with the waypoint marker (HudCompass, playtest A7).

## Meter kind -> painter: Tribes / Tribes 2 art-and-bar meters, aim meters, the Starsiege radar and status
## meters, the Battledrome vector-drawn meters.
const BASIC_KINDS := ["frame", "vehicle_icon", "health", "energy", "heat", "speed", "altitude", "clock", "sensor",
	"crew", "heading", "heading_tape", "messages"]
const AIM_KINDS := ["reticle", "lead"]
const STATUS_KINDS := ["shields", "weapons", "damage_self", "damage_target", "internal_damage"]
## The remake's altitude readout for flyers whose game had none for them (Starsiege flyers were not playable):
## "ALT <m> M" at the left edge, below the middle, in the HUD's first font.
const FLIGHT_METER_POS := Vector2(0.04, 0.6)
## Widest altitude the flight readout shows (its window rect).
const FLIGHT_METER_SAMPLE := "ALT 00000 M"
const REMAKE_MESSAGE_LINES := 2
## The remake's heading tape for a HUD without a compass: its band as shares of the canvas (below the Starsiege
## message window, top centre) and the room right of it for the waypoint text.
const COMPASS_BAND := Rect2(0.34375, 0.095, 0.3125, 0.045)
const COMPASS_TEXT_SHARE := 0.15
## Kinds that already show the heading.
const HEADING_KINDS := ["heading", "camera_heading"]
const MESSAGE_INSET := 2.0

var _basic: CockpitMeterBasic
var _aim: CockpitMeterAim
var _radar: CockpitMeterRadar
var _status: CockpitMeterStatus
var _vector: CockpitMeterVector
var _meters: Array = []


func _init(p_display: CockpitDisplay, p_canvas: CockpitCanvas) -> void:
	super(p_display, p_canvas)
	_basic = CockpitMeterBasic.new(p_display, p_canvas)
	_aim = CockpitMeterAim.new(p_display, p_canvas)
	_radar = CockpitMeterRadar.new(p_display, p_canvas)
	_status = CockpitMeterStatus.new(p_display, p_canvas)
	_vector = CockpitMeterVector.new(p_display, p_canvas)
	_meters = display.layout.get("meters", [])
	if herc is Flyer and not _has_kind("altitude"):
		_meters = _meters + [make_flight_meter()]
	if not _has_kind("messages"):
		_meters = _meters + [make_message_meter()]
	if not HEADING_KINDS.any(_has_kind):
		_meters = _meters + [make_compass_meter()]


## True when the HUD shows the heading: a compass meter of its own or the remake's heading tape.
func has_compass() -> bool:
	return _has_kind("heading_tape") or HEADING_KINDS.any(_has_kind)


func _has_kind(kind: String) -> bool:
	return _meters.any(func(m): return str(m.get("kind", "")) == kind)


## The HUD's first font (the remake's own meters use it).
func _make_first_font() -> String:
	for m in _meters:
		if str(m.get("font", "")) != "":
			return str(m.font)
	return ""


## The remake's altimeter for a HUD without one (text in the HUD's own font).
func make_flight_meter() -> Dictionary:
	var font := _make_first_font()
	var at := display.canvas_size * FLIGHT_METER_POS
	var top := at.y - canvas.font_height(font) - 1.0
	return {"kind": "altitude", "remake": true,
		"rect": [at.x, top, at.x + canvas.text_width(font, FLIGHT_METER_SAMPLE), at.y + canvas.font_height(font)],
		"text": {"font": font, "at": [at.x, at.y], "source": "altitude"},
		"label": {"font": font, "at": [at.x, top], "value": "ALT M"}}


## The remake's heading tape (HudCompass) for a HUD without a compass; "tape" is the band, "rect" adds the text room.
func make_compass_meter() -> Dictionary:
	var c := display.canvas_size
	var tape := Rect2(COMPASS_BAND.position * c, COMPASS_BAND.size * c)
	var r := tape.grow_individual(0.0, 0.0, c.x * COMPASS_TEXT_SHARE, 0.0)
	return {"kind": "heading_tape", "remake": true, "tape": [tape.position.x, tape.position.y, tape.end.x, tape.end.y],
		"rect": [r.position.x, r.position.y - HudCompass.CARET, r.end.x, r.end.y]}


## The remake's message window for a HUD without one: REMAKE_MESSAGE_LINES lines in the HUD's first font, in
## the first free band from the top.
func make_message_meter() -> Dictionary:
	var font := _make_first_font()
	var r := CockpitMessageArea.make_free_rect(make_window_rects(), display.canvas_size,
		canvas.font_height(font) * REMAKE_MESSAGE_LINES + MESSAGE_INSET * 2.0)
	return {"kind": "messages", "remake": true, "rect": [r.position.x, r.position.y, r.end.x - 1.0, r.end.y - 1.0],
		"text": {"font": font, "at": [r.position.x + MESSAGE_INSET, r.position.y + MESSAGE_INSET],
			"lines": REMAKE_MESSAGE_LINES}}


## Canvas rect of the HUD's message window.
func make_message_rect() -> Rect2:
	for m in _meters:
		if str(m.get("kind", "")) == "messages":
			return CockpitCanvas.rect_of(m.rect)
	return Rect2()


## Lines the HUD's message window shows (1: a one-line window that scrolls the newest message through).
func make_message_line_count() -> int:
	for m in _meters:
		if str(m.get("kind", "")) == "messages":
			return _basic.make_message_line_count(m) if _painter_of(m) == _basic else 1
	return 1


## Canvas rects of every other window of the HUD.
func make_window_rects() -> Array:
	var out := []
	for m in _meters:
		if str(m.get("kind", "")) != "messages" and m.has("rect"):
			out.append(CockpitCanvas.rect_of(m.rect))
	return out


## Keeps the model pictures on their vehicles (only while the HUD shows).
func follow(on: bool, delta: float) -> void:
	_status.follow(on, delta)


func draw() -> void:
	for m in _meters:
		_painter_of(m).draw_meter(m)


func _painter_of(m: Dictionary) -> CockpitMeterPainter:
	if m.has("shapes") or m.has("diamond_shapes"):
		return _vector
	var kind := str(m.get("kind", ""))
	if kind in AIM_KINDS:
		return _aim
	if kind == "radar":
		return _radar
	if kind in STATUS_KINDS and not m.has("layers"):
		return _status
	return _basic

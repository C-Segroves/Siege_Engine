class_name CockpitMeterPainter
extends CockpitPainter
## Base of the HUD meter painters (CockpitMeters): one meter record of a HUD layout ("meters", written by
## tools/cockpit_hud_layouts.py from the decoded hud.json of Starsiege, Battledrome, Tribes, Tribes 2) drawn on
## the cockpit canvas. Shared parts every decoded HUD uses:
##   layers  static bitmaps [{dba, frame, at, flip ("h" / "v"), opacity, tint, src_rect}]
##   bar     a value bar: Tribes 1 {origin, max_px, height, steps [{min_px, color, cap_frame}]} or Tribes 2
##           {rect, fill, direction, pulse_below, pulse_ms}; the value comes from "source"
##   text / label   a value or fixed text {font, color, at | rect, justify, source, format, scale, value}
## Colours are palette indices (Starsiege, Battledrome) or [r, g, b, a] (Tribes).

const PULSE_DIM := 0.35
const MS := 1000.0
const MPS_TO_KPH := 3.6

## Meter opacity of the original (Starsiege: every meter at 0.7).
func meter_mod(m: Dictionary) -> Color:
	return Color(1, 1, 1, float(m.get("alpha", m.get("opacity", 1.0))))


## Palette index or [r, g, b(, a)] -> Color.
func make_color(v: Variant, fallback := Color.WHITE) -> Color:
	if v is Array and v.size() >= 3:
		return Color8(int(v[0]), int(v[1]), int(v[2]), int(v[3]) if v.size() > 3 else 255)
	if v is float or v is int:
		return canvas.color(int(v))
	return fallback


## Draws `m.layers` in order.
func draw_layers(m: Dictionary, mod: Color) -> void:
	for l in m.get("layers", []):
		if l is Dictionary:
			draw_layer(l, mod)


func draw_layer(l: Dictionary, mod: Color) -> void:
	var tex := canvas.dba(str(l.dba), int(l.get("frame", 0)))
	if tex == null:
		return
	var at: Array = l.get("at", [0, 0])
	var c := mod * Color(1, 1, 1, float(l.get("opacity", 1.0)))
	if l.has("tint"):
		c *= make_color(l.tint)
	var flip := str(l.get("flip", ""))
	if flip != "":
		tex = _make_flipped(tex, flip)
	if l.has("src_rect"):
		var s: Array = l.src_rect
		var src := Rect2(float(s[0]), float(s[1]), float(s[2]) - float(s[0]), float(s[3]) - float(s[1]))
		canvas.item.draw_texture_rect_region(tex, Rect2(float(at[0]), float(at[1]), src.size.x, src.size.y), src, c)
	else:
		canvas.blit(tex, float(at[0]), float(at[1]), CockpitCanvas.NO_CLIP, c)


var _flipped := {}                  # [texture, flip] -> mirrored texture


## `tex` mirrored ("h" left-right, "v" upside down), cached; same drawn size.
func _make_flipped(tex: Texture2D, flip: String) -> Texture2D:
	var key := [tex, flip]
	if not _flipped.has(key):
		var img := tex.get_image()
		if flip.contains("h"):
			img.flip_x()
		if flip.contains("v"):
			img.flip_y()
		var out := ImageTexture.create_from_image(img)
		canvas.assets.set_scale_of(out, canvas.assets.scale_of(tex))
		_flipped[key] = out
	return _flipped[key]


# ------------------------------------------------------------------ values

## 0..1 value of a bar source ("vehicle.health", "control_object.energy", "player.heat" ...). The remake's pilot
## has no separate body inside a vehicle, so the pilot's own bars read full health / energy and no heat.
func make_value(source: String) -> float:
	if source.begins_with("player."):
		return 0.0 if source.ends_with("heat") else 1.0
	if source.ends_with("health"):
		return clampf(herc.integrity, 0.0, 1.0)
	if source.ends_with("energy"):
		return clampf(herc.capacitor / maxf(herc.capacitor_max, 1.0), 0.0, 1.0)
	return 0.0


## Text of a value source ("...speed...", "...altitude...", "mission time").
func make_value_text(t: Dictionary) -> String:
	var src := str(t.get("source", ""))
	if src.contains("speed"):
		return str(int(floorf(absf(herc.speed) * float(t.get("scale", MPS_TO_KPH)))))
	if src.contains("altitude"):
		return str(int(make_altitude()))
	if src.contains("time") or str(t.get("format", "")) == "mm:ss":
		return make_clock_text()
	return str(t.get("value", ""))


func make_altitude() -> float:
	return (herc as Flyer).make_altitude() if herc is Flyer else 0.0


## True during the dim half of a warning pulse.
func is_pulse_dim(period_ms: float) -> bool:
	return period_ms > 0.0 and fmod(display.time * MS, period_ms * 2.0) >= period_ms


# ------------------------------------------------------------------ bars and text

func draw_bar(b: Dictionary, mod: Color) -> void:
	var v := make_value(str(b.get("source", "")))
	if b.has("rect"):
		_draw_rect_bar(b, v, mod)
	elif b.has("origin"):
		_draw_capped_bar(b, v, mod)


## Tribes 2 HudDamage / HudEnergy: a fill over the bar rect, pulsing below `pulse_below`.
func _draw_rect_bar(b: Dictionary, v: float, mod: Color) -> void:
	var r := CockpitCanvas.rect_of(b.rect)
	var c := make_color(b.get("fill"), Color.GREEN) * mod
	if v < float(b.get("pulse_below", 0.0)) and is_pulse_dim(float(b.get("pulse_ms", 0.0))):
		c.a *= PULSE_DIM
	var w := roundf(r.size.x * v)
	canvas.fill(Rect2(r.position.x if str(b.get("direction", "")) != "right_to_left" else r.end.x - w, r.position.y, w, r.size.y), c)


## Tribes 1 HealthHud / JetPackHud: a coloured fill `v * max_px` long with a cap bitmap at each end, the colour
## and caps by length steps.
func _draw_capped_bar(b: Dictionary, v: float, mod: Color) -> void:
	var o: Array = b.origin
	var length := roundf(float(b.max_px) * v)
	if v > 0.0:
		length = maxf(length, float(b.get("min_px_alive", 0)))
	var step: Dictionary = _make_bar_step(b.get("steps", []), length)
	var clip := Rect2(float(o[0]), float(o[1]), length, float(b.height))
	canvas.fill(clip, make_color(step.get("color"), Color.GREEN) * mod)
	var cap := canvas.dba(str(b.get("dba", "")), int(step.get("cap_frame", -1))) if b.has("dba") else null
	if cap:
		canvas.blit(cap, float(o[0]), float(o[1]), clip, mod)


static func _make_bar_step(steps: Array, length: float) -> Dictionary:
	for s in steps:
		if length >= float(s.get("min_px", 0)):
			return s
	return steps[-1] if not steps.is_empty() else {}


## Draws text field `t` ({font, color?, at | rect, justify}) with string `s`.
func draw_text(t: Dictionary, s: String, mod: Color) -> void:
	var font := str(t.get("font", ""))
	var tint: Color = make_color(t.color) if t.has("color") else CockpitCanvas.NO_TINT
	if t.has("rect"):
		var r := CockpitCanvas.rect_of(t.rect)
		var x := r.position.x
		if str(t.get("justify", "")) == "center":
			x += floorf((r.size.x - canvas.text_width(font, s)) * 0.5)
		elif str(t.get("justify", "")) == "right":
			x = r.end.x - canvas.text_width(font, s)
		canvas.text(font, x, r.position.y, s, CockpitCanvas.NO_CLIP, tint, mod)
	elif t.has("at"):
		canvas.text(font, float(t.at[0]), float(t.at[1]), s, CockpitCanvas.NO_CLIP, tint, mod)


## Text in font `font` with its centre at (x, y)'s column.
func draw_text_centred(font: String, x: float, y: float, s: String, mod: Color) -> void:
	canvas.text(font, x - floorf(canvas.text_width(font, s) * 0.5), y, s, CockpitCanvas.NO_CLIP, CockpitCanvas.NO_TINT, mod)


## The vehicle's current living target (a vehicle, soldier or targetable structure), else null.
func live_target() -> Node3D:
	return herc.target if has_live_target() else null


## Window point of a world point on the cockpit canvas (null behind the camera).
func make_canvas_point(p: Vector3) -> Variant:
	return display.make_virtual_point(p)

class_name CockpitShields
extends CockpitPainter
## Earthsiege 2 shield gauge (ShieldsGauge, ctor 0x4434fc; docs/formats/cockpit.md 8.5): front and rear
## shield bars. The front bar fills upwards from its bottom, the rear bar downwards from its top, so the
## two meet in the middle like the throttle's speed bars (fill direction and colours: L).

const LOW_SHIELD := 0.25


func draw() -> void:
	var g := gauge("shields")
	if g.is_empty():
		return
	var half := maxf(herc.shield_max * 0.5, 1.0)
	_draw_bar(CockpitCanvas.rect_of(g.front), herc.shield_front / half, true)
	_draw_bar(CockpitCanvas.rect_of(g.rear), herc.shield_rear / half, false)


func _draw_bar(r: Rect2, level: float, upwards: bool) -> void:
	level = clampf(level, 0.0, 1.0)
	var col := skin_color("shields", "color_ok" if level > LOW_SHIELD else "color_low", C_GREEN)
	var h := roundf(r.size.y * level)
	var y := r.end.y - h if upwards else r.position.y
	canvas.fill(Rect2(r.position.x, y, r.size.x, h), col)

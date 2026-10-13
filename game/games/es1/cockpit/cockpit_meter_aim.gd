class_name CockpitMeterAim
extends CockpitMeterPainter
## Aim meters: the reticle (Starsiege HudMtrAimReticle 0x51b0e0: RETICAL frame 0 idle, 1 when the lead point is
## within `on_target_px` of the aim point, 2 when a missile is locked; Tribes 2 per-weapon reticle bitmaps;
## Tribes 1 crosshair with the friend / foe marker over the target) and the Starsiege lead indicator
## (0x51b85c: LEAD frame 1 in range / 0 out of range at the lead point, range text "%.0fm").

const DEFAULT_FONT_GAP := 2.0
const TARGET_MARK_RISE := 0.8       # Tribes 1 friend / foe marker: this share of the target's height above it


func draw_meter(m: Dictionary) -> void:
	match str(m.kind):
		"reticle":
			_draw_reticle(m)
		"lead":
			_draw_lead(m)


func _draw_reticle(m: Dictionary) -> void:
	var mod := meter_mod(m)
	if m.has("per_weapon") and not m.per_weapon.is_empty():
		var per: Array = m.per_weapon
		var l = per[clampi(_make_selected_index(), 0, per.size() - 1)]
		draw_layer(l if l is Dictionary else per[0], mod)
	elif m.has("layers") and not m.layers.is_empty():
		draw_layers(m, mod)
	elif m.has("dba"):
		var r: Array = m.rect
		canvas.blit(canvas.dba(str(m.dba), _make_reticle_frame(m)), float(r[0]), float(r[1]), CockpitCanvas.NO_CLIP, mod)
	if m.has("target_markers"):
		_draw_target_marker(m, mod)


## Index of the weapon whose trigger is held (the remake's "selected" weapon), else the first one.
func _make_selected_index() -> int:
	for i in herc.weapons.size():
		if herc.weapons[i].trigger:
			return i
	return 0


func _make_reticle_frame(m: Dictionary) -> int:
	var frames: Dictionary = m.get("frames", {})
	var t := live_target()
	if t == null:
		return int(frames.get("idle", 0))
	var lead = make_canvas_point(make_lead_point(t))
	var centre := CockpitCanvas.rect_of(m.rect).get_center()
	if lead == null or (lead as Vector2).distance_to(centre) > float(m.get("on_target_px", 0)):
		return int(frames.get("idle", 0))
	if _is_missile_locked(t):
		return int(frames.get("locked", frames.get("on_target", 0)))
	return int(frames.get("on_target", 0))


func _is_missile_locked(t: Node3D) -> bool:
	var w := _make_aim_weapon()
	return w != null and w.kind == "missile" and herc.global_position.distance_to(t.global_position) <= w.weapon_range


## The weapon the lead is computed for: the held one, else the first.
func _make_aim_weapon() -> Weapon:
	if herc.weapons.is_empty():
		return null
	return herc.weapons[clampi(_make_selected_index(), 0, herc.weapons.size() - 1)]


## Where to aim at `t` so a shot of the aim weapon meets it (the target's velocity times the flight time).
func make_lead_point(t: Node3D) -> Vector3:
	var w := _make_aim_weapon()
	var p := t.global_position + Vector3.UP * TargetInfo.make_height(t) * 0.5
	if w == null or w.fires_beam() or w.projectile_speed <= 0.0:
		return p
	return p + TargetInfo.make_velocity(t) * (herc.global_position.distance_to(p) / w.projectile_speed)


func _draw_lead(m: Dictionary) -> void:
	var t := live_target()
	if t == null:
		return
	var pt = make_canvas_point(make_lead_point(t))
	if pt == null:
		return
	var mod := meter_mod(m)
	var d := herc.global_position.distance_to(t.global_position)
	var w := _make_aim_weapon()
	var frames: Dictionary = m.get("frames", {})
	var in_range := w != null and d <= w.weapon_range
	var off: Array = m.get("offset_from_lead_point", [0, 0])
	var p: Vector2 = pt
	canvas.blit(canvas.dba(str(m.dba), int(frames.get("in_range" if in_range else "out_of_range", 0))),
		p.x + float(off[0]), p.y + float(off[1]), CockpitCanvas.NO_CLIP, mod)
	var s := "%.0fm" % d
	var to: Array = m.get("range_text_offset", [0, 0])
	var font := str(m.get("font", ""))
	canvas.text(font, p.x + float(to[0]) - canvas.text_width(font, s), p.y + float(to[1]), s, CockpitCanvas.NO_CLIP,
		CockpitCanvas.NO_TINT, mod)


## Tribes 1 Crosshair: the friend / foe marker above the targeted vehicle.
func _draw_target_marker(m: Dictionary, mod: Color) -> void:
	var t := live_target()
	if t == null:
		return
	var tm: Dictionary = m.target_markers
	var top := t.global_position + Vector3.UP * TargetInfo.make_height(t) * (1.0 + TARGET_MARK_RISE)
	var pt = make_canvas_point(top)
	var tex := canvas.dba(str(m.dba), int(tm.get("friend" if TargetInfo.is_friendly(herc, t) else "foe", 0)))
	if pt == null or tex == null:
		return
	var sz := canvas.size_of(tex)
	canvas.blit(tex, (pt as Vector2).x - floorf(sz.x * 0.5), (pt as Vector2).y - sz.y - DEFAULT_FONT_GAP, CockpitCanvas.NO_CLIP, mod)

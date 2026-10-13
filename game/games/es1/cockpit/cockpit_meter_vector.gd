class_name CockpitMeterVector
extends CockpitMeterPainter
## Battledrome's code-drawn HUD (tools/bd_hud.py, SIM.EXE Hud::render 0x23a40): every window is line art
## ("shapes": polyline / line / ellipse / fill / polygon / text, relative to the window's top-left, palette
## colours of NRMPAL) plus its live parts:
##   energy        SHIELDS / ENGINE / WEAPONS sliders (levels 0..255 summing to 255; the remake has no power
##                 split: the default 85 each)
##   throttle      MechSpinners: chassis / torso / view pointers on the compass and the throttle marker
##   camera_heading  CameraSpinners: the view pointer (the cockpit camera: the torso direction)
##   weapons       a row per weapon: slot number, name (damage colour), charge ticks or ammo; the held one lit
##   shields       the 19-tick shield bar and the Herc's front diagram (one colour: the remake's BD Hercs have
##                 a single hull component)
##   target_info   TARGET: kind and DIST:; control_mode / active_camera: HERC / COCKPIT; messages: the newest line
## Texts are placed by baseline (font "baseline" rows above it).

const ANGLE_UNITS := 65536.0
const LEVEL_MAX := 255.0
const ENERGY_DEFAULT := 85.0
const DAMAGE_YELLOW := 100.0
const DAMAGE_RED := 180.0
const GREEN := 4
const YELLOW := 10
const RED := 7
const BLACK := 0
const ELLIPSE_SEGMENTS := 32
const THROTTLE_STEPS := 127.0
const CHARGE_STEPS := 256.0
const DISTANCE_LIMITS := Vector2i(-999, 9999)
const LINE_WIDTH := 1.0
## Weapon names fit the name cell (x 8..40 at the 4 px font advance).
const NAME_CHARS := 8

var _origin := Vector2.ZERO


func draw_meter(m: Dictionary) -> void:
	var kind := str(m.get("kind", ""))
	_origin = Vector2.ZERO if kind == "reticle" else Vector2(float(m.rect[0]), float(m.rect[1]))
	if kind == "reticle":
		_draw_shapes(m.shapes if display.cam != null and display.cam.current else m.get("diamond_shapes", m.shapes))
		return
	_draw_shapes(m.get("shapes", []))
	match kind:
		"energy":
			_draw_energy(m)
		"throttle":
			_draw_throttle(m)
		"camera_heading":
			_draw_pointers(m, [0.0, 0.0])
		"weapons":
			_draw_weapons(m)
		"shields":
			_draw_shields(m)
		"target_info":
			_draw_target(m)
		"control_mode":
			_text(str(m.value["values"][0]), m.value.at, int(m.value.color))
		"active_camera":
			_text(str(m.camera["values"][0]), m.camera.at, int(m.camera.color))
		"messages":
			_draw_message(m)
		"camera_list":
			_draw_camera_list(m)


# ------------------------------------------------------------------ primitives

func _p(a: Array) -> Vector2:
	return _origin + Vector2(float(a[0]), float(a[1])) + Vector2(0.5, 0.5)


func _draw_shapes(shapes: Array) -> void:
	for s in shapes:
		_draw_shape(s)


func _draw_shape(s: Dictionary) -> void:
	var c := canvas.color(int(s.get("color", 0)))
	match str(s.op):
		"line", "polyline":
			var pts := PackedVector2Array()
			for p in s.points:
				pts.append(_p(p))
			canvas.item.draw_polyline(pts, c, LINE_WIDTH)
		"polygon":
			_polygon(s.points, int(s.color))
		"fill":
			_fill(s.rect, int(s.color))
		"ellipse":
			_ellipse(s.rect, c)
		"text":
			_text(str(s.text), s.at, int(s.color))


func _fill(r: Array, color_i: int) -> void:
	canvas.fill(Rect2(_origin + Vector2(float(r[0]), float(r[1])), Vector2(float(r[2]) - float(r[0]) + 1.0, float(r[3]) - float(r[1]) + 1.0)),
		canvas.color(color_i))


func _polygon(points: Array, color_i: int) -> void:
	var pts := PackedVector2Array()
	for p in points:
		pts.append(_p(p))
	if pts.size() >= 3 and not Geometry2D.triangulate_polygon(pts).is_empty():
		canvas.item.draw_colored_polygon(pts, canvas.color(color_i))


func _ellipse(r: Array, c: Color) -> void:
	var a := _p([r[0], r[1]])
	var b := _p([r[2], r[3]])
	var centre := (a + b) * 0.5
	var radius := (b - a) * 0.5
	var pts := PackedVector2Array()
	for i in ELLIPSE_SEGMENTS + 1:
		var t := TAU * i / ELLIPSE_SEGMENTS
		pts.append(centre + Vector2(cos(t) * radius.x, sin(t) * radius.y))
	canvas.item.draw_polyline(pts, c, LINE_WIDTH)


## Text with its baseline at `at` (relative to the window), clipped to `clip` (layout pixels).
func _text(s: String, at: Array, color_i: int, clip := CockpitCanvas.NO_CLIP) -> void:
	var f := canvas.assets.font("HUD")
	var base := float(f.get("h", 5)) - 1.0
	canvas.text("HUD", _origin.x + float(at[0]), _origin.y + float(at[1]) - base, s.to_upper(), clip, canvas.color(color_i))


# ------------------------------------------------------------------ live parts

func _draw_energy(m: Dictionary) -> void:
	var bar: Dictionary = m.bar
	for row in m.rows:
		var y := float(row.baseline)
		_text(str(row.label), [row.label_x, y], int(m.colors.label))
		var n := floorf(ENERGY_DEFAULT * float(bar.px_per_level))
		var x := float(bar.x)
		_draw_shape({"op": "line", "points": [[x, y - 2], [x + n, y - 2]], "color": m.colors.bar})
		_fill([x + n, y - 4, x + n + 2, y], int(m.colors.bar))


## Pointer angles: 0 up, clockwise, in 1/65536 turns; the chassis pointer is the heading, the torso and view
## pointers the torso twist relative to it (L: which game angle drives which pointer).
func _draw_pointers(m: Dictionary, angles: Array) -> void:
	var c: Array = m.centre
	var pointers: Array = m.pointers
	for i in pointers.size():
		var p: Dictionary = pointers[i]
		var a := float(angles[i]) if i < angles.size() else 0.0
		for poly in p.get("polygons", [p.get("points", [])]):
			_polygon(_make_rotated(poly, a, c, float(p.get("y_scale", 1.0))), int(p.color))


static func _make_rotated(points: Array, angle: float, centre: Array, y_scale: float) -> Array:
	var out := []
	for p in points:
		var v := Vector2(float(p[0]), float(p[1])).rotated(angle)
		out.append([roundf(float(centre[0]) + v.x), roundf(float(centre[1]) + v.y * y_scale)])
	return out


func _draw_throttle(m: Dictionary) -> void:
	var twist := -herc.torso_yaw
	_draw_pointers(m, [twist, -herc.global_rotation.y, twist])
	var th: Dictionary = m.throttle
	var t := clampf(herc.throttle, -1.0, 1.0) * THROTTLE_STEPS
	var forward := t >= 0.0
	var btn: Dictionary = th.forward_button if forward else th.reverse_button
	_polygon(btn.polygon, int(th.colors.button))
	_text("F", th.forward_button.at, int(th.colors.label_active if forward else th.colors.label))
	_text("R", th.reverse_button.at, int(th.colors.label if forward else th.colors.label_active))
	if absf(t) < 1.0:
		return
	var base := maxf(8.0, 19.0 - floorf(12.0 * t / THROTTLE_STEPS)) if forward else minf(32.0, 22.0 + floorf(11.0 * -t / THROTTLE_STEPS))
	var tip := base + (-3.0 if forward else 3.0)
	_polygon([[48, base], [51, tip], [54, base]], int(th.colors.marker))
	for ty in (th.forward if forward else th.reverse).ticks_y:
		if (forward and float(ty) > base) or (not forward and float(ty) < base):
			_draw_shape({"op": "line", "points": [[48, ty], [54, ty]], "color": th.colors.tick})


func _damage_color(health: float) -> int:
	var damage := (1.0 - clampf(health, 0.0, 1.0)) * LEVEL_MAX
	return GREEN if damage < DAMAGE_YELLOW else (YELLOW if damage < DAMAGE_RED else RED)


func _draw_weapons(m: Dictionary) -> void:
	var rows: Array = m.rows
	for k in mini(herc.weapons.size(), rows.size()):
		var w: Weapon = herc.weapons[k]
		var y := float(rows[k].baseline)
		_text(str(k + 1), [m.number.x, y], int(m.number.color))
		var col := _damage_color(herc.integrity)
		if w.trigger:
			var f: Array = m.selected.fill
			_fill([f[0], y + float(f[1]), f[2], y + float(f[3])], col)
			col = int(m.selected.name_color)
		_text(str(w.display_name).left(NAME_CHARS), [m.name.x, y], col)
		if w.ammo >= 0:
			_text(str(w.ammo), [m.ammo.at_x, y], int(m.ammo.color))
		else:
			_draw_charge(m.charge, y, 1.0 - clampf(w.cooldown / maxf(w.refire, 0.01), 0.0, 1.0))


func _draw_charge(ch: Dictionary, y: float, charge: float) -> void:
	var x0 := int(ch.x0)
	var x_end := x0 + int(charge * CHARGE_STEPS * 15.0) / int(CHARGE_STEPS)
	for x in range(x0, x_end, int(ch.step)):
		_draw_shape({"op": "line", "points": [[x, y - 4], [x, y]], "color": ch.color})


func _draw_shields(m: Dictionary) -> void:
	var bar: Dictionary = m.bar
	var level := clampf((herc.shield_front + herc.shield_rear) / maxf(herc.shield_max, 1.0), 0.0, 1.0) * LEVEL_MAX
	var col := int(bar.colors.from_180) if level >= DAMAGE_RED else (int(bar.colors.from_100) if level >= DAMAGE_YELLOW else int(bar.colors["else"]))
	var top := floorf((LEVEL_MAX - level) * 39.0 / LEVEL_MAX)
	for y in bar.ticks_y:
		if float(y) > top:
			_draw_shape({"op": "line", "points": [[bar.x0, y], [mini(56, 48 + int(y)), y]], "color": col})
	if level > 0.0:
		_polygon(bar.base_polygon, col)
	_draw_diagram(m.diagram, m.get("herc_order", []))


func _draw_diagram(d: Dictionary, order: Array) -> void:
	var by_herc: Array = d.by_herc
	var i := order.find(make_unit_key(herc))
	var entries: Array = by_herc[i if i >= 0 else 0] if not by_herc.is_empty() else []
	var col := _damage_color(herc.integrity)
	for e in entries:
		for seg in d.part_lines.get(str(int(e.kind)), []):
			_draw_shape({"op": "line", "points": [[float(e.at[0]) + seg[0], float(e.at[1]) + seg[1]],
				[float(e.at[0]) + seg[2], float(e.at[1]) + seg[3]]], "color": col})


func _draw_target(m: Dictionary) -> void:
	var t := live_target()
	if t == null:
		return
	_text(str(m.name["values"][0]), m.name.at, int(m.name.color))
	var d := clampi(int(herc.global_position.distance_to(t.global_position)), DISTANCE_LIMITS.x, DISTANCE_LIMITS.y)
	_text(str(d), m.distance.at, int(m.distance.color))


## The chat line: the newest message, else the standing hint, scrolling through the window when too long.
func _draw_message(m: Dictionary) -> void:
	var entry := display.make_newest_entry()
	if entry.is_empty():
		return
	var s := str(entry[0]).to_upper()
	var r := CockpitCanvas.rect_of(m.rect)
	var inset := float(m.text.at[0])
	var x := CockpitMessageArea.make_scroll_x(r, inset, canvas.text_width("HUD", s), entry)
	_text(s, [x - _origin.x, m.text.at[1]], int(m.text.color_normal), r.grow_individual(-inset, 0.0, -inset, 0.0))


## CamButton: COCKPIT (active, the remake has no probes) and the probe rows.
func _draw_camera_list(m: Dictionary) -> void:
	var rows: Array = m.rows
	var fills: Array = m.get("active_fills", [])
	for k in rows.size():
		var y := float(rows[k].baseline)
		if k == 0:
			for j in fills.size():
				var f: Array = fills[j]
				_fill([f[0], y + float(f[1]), f[2], y + float(f[3])], int(m.colors["active_name_fill" if j == 0 else "active_mode_fill"]))
		_text(str(rows[k].name), [m.name_x, y], int(m.colors["active_text" if k == 0 else "name"]))

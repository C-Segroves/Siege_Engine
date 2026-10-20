class_name CockpitMfd
extends CockpitPainter
## The multi-function display: page buttons and its pages (STATUS, COMM, NAV, SCANNER, TARGET, MISSILE),
## docs/formats/cockpit.md 3.7 / 8.2. Earthsiege 2 adds a background bitmap per page and per-page option
## buttons (skin "page_frames" / "option_buttons").

const MODE_STATUS := 0
const MODE_COMM := 1
const MODE_NAV := 2
const MODE_SCANNER := 3
const MODE_TARGET := 4
const MODE_MISSILE := 5
const MODE_COUNT := 6
const RADAR_RANGES := [30000.0, 80000.0, 120000.0]   # original units (PMFD)
const OPTION_ON := 3
const OPTION_OFF := 5
const RANGE_DOWN := 29
const RANGE_UP := 32
const TITLE_BUTTON := 6
const FIRST_OPTION := 7
const BLINK_PERIOD := 0.5
const BLINK_ON := 0.3
const LOCK_PERIOD := 0.6
const LOCK_ON := 0.35
## Earthsiege 1 option buttons 7..10 (the first shows RANGE / TARGET on those pages), 11 / 12 range.
const ES1_OPTIONS := 4
const RANGE_LABEL := 8
const TARGET_LABEL := 9
const RNG_VALUE_DX := 20.0
## MISSILE CAM page hit flash: the frame alternates between these palette colours (ES1 0x36566: 0x3c / 0x3f).
const CAM_FLASH_COLORS := [0x3c, 0x3f]
const CAM_FRAME_WIDTH := 1.0


func draw() -> void:
	var m := gauge("mfd")
	if m.is_empty():
		return
	var d := CockpitCanvas.rect_of(m.display)
	_draw_page_frame(d)
	_draw_buttons(m)
	match display.mfd_mode:
		MODE_SCANNER:
			_draw_radar(d, true)
		MODE_NAV:
			_draw_radar(d, false)
		MODE_STATUS:
			_draw_unit_status(d, herc)
		MODE_TARGET:
			_draw_target_page(d)
		MODE_COMM:
			canvas.text(_label_font(), d.position.x + 2, d.position.y + 2, label("mfd", 1, "FLASH COMM"), d)
			canvas.text(_page_font(), d.position.x + 2, d.position.y + 14, item_label("no_info", "NO INFO AVAILABLE"), d)
		MODE_MISSILE:
			_draw_missile_cam(d)


func _label_font() -> String:
	return skin.font("mfd", "label_font")


func _page_font() -> String:
	return skin.font("mfd", "page_font")


## Earthsiege 2: the page's background bitmap (0x4461f7).
func _draw_page_frame(d: Rect2) -> void:
	var frames := skin.list("mfd", "page_frames")
	if display.mfd_mode < frames.size():
		canvas.blit(canvas.dba(skin.dba("mfd"), int(frames[display.mfd_mode])), d.position.x, d.position.y)


func _draw_buttons(m: Dictionary) -> void:
	var b: Array = m.buttons
	var mode: int = display.mfd_mode
	var off := skin.frame("mfd", "mode_off")
	var step := int(skin.value("mfd", "mode_step", 2))
	for i in MODE_COUNT:
		var f := off + step * i + ((skin.frame("mfd", "mode_on") - off) if i == mode else 0)
		canvas.blit_button(skin.dba("mfd"), f, b[i])
	if m.has("title"):
		var tr := CockpitCanvas.rect_of(m.title)
		canvas.text(skin.font("mfd", "title_font"), tr.position.x, tr.position.y, _make_title(mode), tr)
	else:
		canvas.text_centered(skin.font("mfd", "title_font"), CockpitCanvas.rect_of(b[TITLE_BUTTON]), _make_title(mode))
	if skin.list("mfd", "option_buttons").is_empty():
		_draw_es1_options(b, mode)
	else:
		_draw_page_options(b, mode)


## Page title: the two radar pages say what they point at (F4 SCANNER heading up, F3 NAV MAP north up).
func _make_title(mode: int) -> String:
	var t := label("mfd", mode, "SCANNER")
	if mode == MODE_SCANNER:
		return "%s HDG UP" % t
	return t


func _draw_es1_options(b: Array, mode: int) -> void:
	var opts := ["", "", "", ""]
	if mode == MODE_SCANNER:
		opts[0] = RadarMode.make_label(herc)   # ACT / PASS (STRINGS0 group 25; button 7 or P toggles it)
		opts[1] = label("mfd", RANGE_LABEL, "RANGE")   # the title button / F4 again steps it
	elif mode == MODE_TARGET:
		opts[0] = label("mfd", TARGET_LABEL, "TARGET")
	for i in ES1_OPTIONS:
		var r := CockpitCanvas.rect_of(b[FIRST_OPTION + i])
		canvas.blit(canvas.dba(skin.dba("buttons"), OPTION_ON if opts[i] != "" else OPTION_OFF), r.position.x, r.position.y, r)
		if opts[i] != "":
			canvas.text_centered(skin.font("mfd", "option_font"), r, opts[i])
	canvas.blit_button(skin.dba("buttons"), RANGE_DOWN, b[11])
	canvas.blit_button(skin.dba("buttons"), RANGE_UP, b[12])


## Earthsiege 2: the page's option buttons (table 0x49cbd8), labelled with STRINGS0 group 5 item = button.
func _draw_page_options(b: Array, mode: int) -> void:
	var pages := skin.list("mfd", "option_buttons")
	if mode >= pages.size():
		return
	var frames: Dictionary = skin.value("mfd", "option_frames", {})
	for i in pages[mode]:
		var r := CockpitCanvas.rect_of(b[int(i)])
		canvas.blit(canvas.dba(skin.dba("mfd"), int(frames.get(str(int(i)), -1))), r.position.x, r.position.y, r)
		canvas.text_centered(skin.font("mfd", "option_font"), r, label("mfd", int(i), ""))


# ---- SCANNER / NAV

## SCANNER (heading up) / NAV (north up): vehicles and nav points within the radar range.
func _draw_radar(d: Rect2, heading_up: bool) -> void:
	var org: Array = skin.list("mfd", "radar_origin")
	canvas.blit(canvas.dba(str(skin.value("mfd", "radar_dba", "RADAR")), _radar_frame()),
		d.position.x + float(org[0]), d.position.y + float(org[1]), d)
	var c: Array = skin.list("mfd", "radar_centre")
	var ctr := d.position + Vector2(float(c[0]), float(c[1]))
	var rng: float = RADAR_RANGES[display.radar_range_i] * Assets.UNIT
	var yaw := view_yaw() if heading_up else 0.0
	if not heading_up:
		_draw_nav_terrain(d, ctr, rng)
	_draw_radar_vehicles(d, ctr, rng, yaw)
	_draw_radar_navs(d, ctr, rng, yaw)
	if not heading_up:
		canvas.text(_page_font(), d.position.x + 1, d.position.y + 1, "N", d)
	var km := "%dM" % int(rng)
	canvas.text(_page_font(), d.end.x - canvas.text_width(_page_font(), km) - 1, d.end.y - 8, km, d)


## NAV MAP: the terrain picture (top-down, north up) of the metres round the Herc that fit the scope.
func _draw_nav_terrain(d: Rect2, ctr: Vector2, rng: float) -> void:
	var tex := display.nav_map
	var area := display.nav_area
	if tex == null or not area.has_area():
		return
	var view := Rect2(Vector2(herc.global_position.x, herc.global_position.z) - Vector2(rng, rng), Vector2(rng, rng) * 2.0)
	var vis := view.intersection(area)
	if not vis.has_area():
		return
	var px := _radar_radius() / rng
	var dst := Rect2(ctr + (vis.position - view.get_center()) * px, vis.size * px)
	var k := tex.get_size() / area.size
	var src := Rect2((vis.position - area.position) * k, vis.size * k)
	canvas.item.draw_texture_rect_region(tex, dst.intersection(d), Rect2(src.position + (dst.intersection(d).position - dst.position) / px * k,
		dst.intersection(d).size / px * k), Color(1, 1, 1, 0.8))


## Earthsiege 2's radar bitmaps are a ping animation; Earthsiege 1 has one scope picture.
func _radar_frame() -> int:
	var n := int(skin.value("mfd", "radar_frames", 1))
	return int(display.time * float(skin.value("mfd", "radar_fps", 0.0))) % maxi(n, 1)


func _radar_radius() -> float:
	return float(skin.value("mfd", "radar_radius", 22.0))


func _radar_color(key: String) -> Color:
	return canvas.color(int(skin.value("mfd", "radar_colors", {}).get(key, C_WHITE)))


## Scope offset (pixels from the scope centre) of world point `at`: HeadingFrame, `yaw` 0 = north up.
func _make_radar_offset(at: Vector3, rng: float, yaw: float) -> Vector2:
	return HeadingFrame.make_radar_offset(herc.global_position, yaw, at) / rng * _radar_radius()


## Pixel offset of world point `at` on the SCANNER (heading up) or NAV (north up) scope at the current range.
func make_radar_point(at: Vector3, heading_up: bool) -> Vector2:
	return _make_radar_offset(at, RADAR_RANGES[display.radar_range_i] * Assets.UNIT, view_yaw() if heading_up else 0.0)


func _draw_radar_vehicles(d: Rect2, ctr: Vector2, rng: float, yaw: float) -> void:
	var blink := fmod(display.time, BLINK_PERIOD) < BLINK_ON
	RadarContacts.apply_range(herc, rng)
	for v in vehicles() + SensorTowers.make_radar_structures(herc):
		if v == herc or not v.alive or not RadarContacts.is_shown(herc, v):
			continue
		var p := _make_radar_offset(v.global_position, rng, yaw)
		if p.length() > _radar_radius():
			continue
		var col := RadarColors.make_unit_color(herc, v)
		if v == herc.target:
			col = _radar_color("target") if blink else _radar_color("target_blink")
		canvas.fill(Rect2((ctr + p).round() - Vector2.ONE, Vector2(2, 2)), col, d)


func _draw_radar_navs(d: Rect2, ctr: Vector2, rng: float, yaw: float) -> void:
	for n in nav_points():
		var p := _make_radar_offset(n.global_position, rng, yaw)
		if p.length() <= _radar_radius():
			var q := (ctr + p).round()
			canvas.fill(Rect2(q - Vector2(1, 0), Vector2(3, 1)), RadarColors.OTHER, d)
			canvas.fill(Rect2(q - Vector2(0, 1), Vector2(1, 3)), RadarColors.OTHER, d)


func _draw_target_page(d: Rect2) -> void:
	if has_live_target():
		_draw_target_status(d, herc.target)
	else:
		canvas.text(_label_font(), d.position.x + 2, d.position.y + 12, item_label("no_target", "NO TARGET SELECTED"), d)


## The MISSILE CAM page: the live view behind the pilot's missile while one flies (and its hit, framed by a
## flashing border), else the launcher state text (ES1 0x360c0 class, update 0x364f8).
func _draw_missile_cam(d: Rect2) -> void:
	var cam := display.missile_cam
	if cam != null and cam.is_active():
		canvas.stretch(cam.get_texture(), d)
		if cam.is_showing_hit():
			_draw_cam_frame(d, canvas.color(CAM_FLASH_COLORS[1 if cam.is_flash_on() else 0]))
		return
	_draw_launcher_state(d)


func _draw_cam_frame(d: Rect2, col: Color) -> void:
	var w := CAM_FRAME_WIDTH
	canvas.fill(Rect2(d.position, Vector2(d.size.x, w)), col)
	canvas.fill(Rect2(d.position.x, d.end.y - w, d.size.x, w), col)
	canvas.fill(Rect2(d.position, Vector2(w, d.size.y)), col)
	canvas.fill(Rect2(d.end.x - w, d.position.y, w, d.size.y), col)


func _draw_launcher_state(d: Rect2) -> void:
	var loaded := 0
	for w in herc.weapons:
		if w.kind == "missile" and w.ammo != 0:
			loaded += 1
	var x := d.position.x + 2
	canvas.text(_label_font(), x, d.position.y + 2, label("missile", 0, "MISS"), d)
	if loaded == 0:
		canvas.text(_page_font(), x, d.position.y + 14, label("missile", 3, "NONE"), d)
		return
	canvas.text(_page_font(), x, d.position.y + 14, label("missile", 1, "READY TO"), d)
	if has_live_target():
		canvas.text(_page_font(), x, d.position.y + 22, label("missile", 2, "LAUNCH"), d)
		if fmod(display.time, LOCK_PERIOD) < LOCK_ON:
			canvas.text(skin.font("mfd", "lock_font"), x, d.position.y + 34, label("missile", 4, "LOCK"), d)


# ---- STATUS / TARGET pages: unit picture (CockpitTargetImage) + 5 text lines

func _draw_unit_status(d: Rect2, u: Herc) -> void:
	display.target_image.draw(d, u)
	var x := d.position.x + float(skin.value("mfd", "status_text_x", 26))
	var y := d.position.y + 1.0
	var rows := skin.list("mfd", "own_rows")
	canvas.text(_page_font(), x, y + rows[0], _unit_name(u), d)
	canvas.text(_label_font(), x, y + rows[1], make_status_text(u, false), d)
	var half := maxf(u.shield_max * 0.5, 1.0)
	canvas.text(_page_font(), x, y + rows[2], "SF %d%%" % int(u.shield_front / half * 100.0), d)
	canvas.text(_page_font(), x, y + rows[3], "SR %d%%" % int(u.shield_rear / half * 100.0), d)
	canvas.text(_page_font(), x, y + rows[4], "%d KPH" % int(absf(u.speed) * 3.6), d)


## The target page: picture, name with its friend-or-foe word (remake, A5), status and range; any target kind.
func _draw_target_status(d: Rect2, u: Node3D) -> void:
	display.target_image.draw(d, u)
	var x := d.position.x + float(skin.value("mfd", "status_text_x", 26))
	var y := d.position.y + 1.0
	var rows := skin.list("mfd", "status_rows")
	canvas.text(_label_font(), x, y + rows[0], item_label("target", "TARGET:"), d)
	canvas.text(_page_font(), x, y + rows[1], _make_target_name(u), d)
	canvas.text(_label_font(), x, y + rows[2], label("status", 0, "STATUS:"), d)
	canvas.text(_page_font(), x, y + rows[3], make_status_text(u, true), d)
	canvas.text(_label_font(), x, y + rows[4], label("range", 0, "RNG:"), d)
	canvas.text(_page_font(), x + RNG_VALUE_DX, y + rows[4], "%d" % int(herc.global_position.distance_to(u.global_position)), d)


## The target's name; a friendly or neutral one adds its friend-or-foe word (the original lists hostiles only).
func _make_target_name(u: Node3D) -> String:
	if TargetInfo.is_hostile(herc, u):
		return _unit_name(u)
	return "%s %s" % [TargetInfo.make_iff_text(herc, u), _unit_name(u)]


func _unit_name(u: Node3D) -> String:
	return TargetInfo.make_type_name(u).to_upper()


## Own status (Earthsiege 1 group 9 / 2: 10): OK, INT DMG, SHLD DWN, CRITICAL, WASTED;
## target (group 24 / 2: 28): OK, SHIELDS DN, INT DAMAGE, CRITICAL, DESTROYED.
func make_status_text(u: Node3D, target_strings: bool) -> String:
	var i := 0
	var health := TargetInfo.make_integrity(u)
	if not bool(u.get("alive")):
		i = 4
	elif health < 0.3:
		i = 3
	elif health < 0.95:
		i = 2 if target_strings else 1
	elif u is Herc and TargetInfo.make_shield_share(u) < 0.1:
		i = 1 if target_strings else 2
	return label("target_status" if target_strings else "own_status", i, "OK")

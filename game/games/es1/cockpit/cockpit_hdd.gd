class_name CockpitHdd
extends CockpitPainter
## The look-down panel's head-down display: MAP / DAMAGE pages and the wingman comm windows
## (docs/formats/cockpit.md 3.8 / 8.6).

const PAGE_MAP := 0
const PAGE_DAMAGE := 1
const MAP_RANGES := [250.0, 500.0, 1000.0, 2000.0]   # metres from centre to screen edge
const GRID_FINE := 100.0            # metres between grid lines
const GRID_COARSE := 500.0          # when zoomed out beyond 500 m
const DEFAULT_ARROW_BASE := 35
const MAX_DAMAGE_ROWS := 19
const DAMAGE_ROW_HEIGHT := 7
const WINGMAN_WINDOWS := 3
const STATIC_FRAMES := 5
const STATIC_FPS := 12.0
const TALK_FIRST := 2
const TALK_FRAMES := 22
const TALK_FPS := 10.0
const BLINK_EVERY := 4.0            # seconds between a pilot's blinks
const BLINK_LENGTH := 0.15
const OCTANTS := 8
const NAV_FRAMES := 9


func draw() -> void:
	var d := gauge("hdd")
	if d.is_empty():
		return
	_draw_buttons(d)
	var scr := CockpitCanvas.rect_of(d.screen)
	if display.hdd_page == PAGE_MAP:
		_draw_map(scr)
	else:
		_draw_damage(scr, CockpitCanvas.rect_of(d.damage_area))
	_draw_wingmen(d)


func _font() -> String:
	return skin.font("hdd", "font")


func _draw_buttons(d: Dictionary) -> void:
	var b: Array = d.buttons
	var page: int = display.hdd_page
	var off := skin.frame("hdd", "page_off")
	var step := int(skin.value("hdd", "page_step", 2))
	var lit := skin.frame("hdd", "page_on") - off
	canvas.blit_button(skin.dba("hdd"), off + (lit if page == PAGE_MAP else 0), b[0])
	canvas.blit_button(skin.dba("hdd"), off + step + (lit if page == PAGE_DAMAGE else 0), b[1])
	var arrows := skin.list("hdd", "arrows")
	var ab := int(d.get("arrow_pbutton_base", DEFAULT_ARROW_BASE))
	for i in 4:
		canvas.blit_button(skin.dba("hdd"), int(arrows[i]) if i < arrows.size() else ab + 2 * i, b[2 + i])
	canvas.blit_button(skin.dba("hdd"), skin.frame("hdd", "button6"), b[6])
	canvas.blit_button(skin.dba("hdd"), skin.frame("hdd", "button7"), b[7])
	canvas.text_centered(skin.font("hdd", "title_font"), CockpitCanvas.rect_of(b[9]), label("hdd_pages", page, "MAP"))


# ---- MAP page

func _draw_map(scr: Rect2) -> void:
	var ctr := (scr.position + scr.size * 0.5).round()
	var rng: float = MAP_RANGES[display.map_zoom]
	var k := (scr.size.y * 0.5) / rng
	_draw_grid(scr, ctr, rng, k)
	_draw_map_navs(scr, ctr, k)
	_draw_map_vehicles(scr, ctr, k)
	canvas.text(_font(), scr.position.x + 2, scr.end.y - 9, "%d M" % int(rng), scr)


func _draw_grid(scr: Rect2, ctr: Vector2, rng: float, k: float) -> void:
	var origin := herc.global_position
	var step := GRID_FINE if rng <= 500.0 else GRID_COARSE
	var gcol := skin_color("hdd", "grid_color", C_GREEN_D)
	var x := floorf((origin.x - rng * 3.0) / step) * step
	while x < origin.x + rng * 3.0:
		var sx := roundf(ctr.x + (x - origin.x) * k)
		if sx >= scr.position.x and sx < scr.end.x:
			canvas.fill(Rect2(sx, scr.position.y, 1, scr.size.y), gcol)
		x += step
	var z := floorf((origin.z - rng) / step) * step
	while z < origin.z + rng:
		var sy := roundf(ctr.y + (z - origin.z) * k)
		if sy >= scr.position.y and sy < scr.end.y:
			canvas.fill(Rect2(scr.position.x, sy, scr.size.x, 1), gcol)
		z += step


func _make_map_point(at: Vector3, ctr: Vector2, k: float) -> Vector2:
	var p: Vector3 = at - herc.global_position
	return ctr + Vector2(p.x, p.z) * k


func _icons() -> Dictionary:
	return skin.value("hdd", "icons", {})


## Top-left of icon `tex` drawn at map point `sp` (Earthsiege 1: a fixed anchor; else centred).
func _icon_origin(tex: Texture2D, sp: Vector2) -> Vector2:
	var anchor = _icons().get("anchor")
	if anchor is Array:
		return Vector2(roundf(sp.x - float(anchor[0])), roundf(sp.y - float(anchor[1])))
	return (sp - canvas.size_of(tex) * 0.5).round()


func _draw_map_navs(scr: Rect2, ctr: Vector2, k: float) -> void:
	var first := int(_icons().get("nav_first", 0))
	for n in nav_points():
		var sp := _make_map_point(n.global_position, ctr, k)
		var ic := canvas.dba(str(_icons().get("dba", "ICONS")), first + clampi(int(str(n.get_meta("label", "1"))) - 1, 0, NAV_FRAMES - 1))
		if ic and scr.has_point(sp):
			var o := _icon_origin(ic, sp)
			canvas.blit(ic, o.x, o.y, scr)


func _draw_map_vehicles(scr: Rect2, ctr: Vector2, k: float) -> void:
	var offsets: Array = _icons().get("octant_offsets", [1, 2, 3, 4, 5, 6, 7, 8])
	for v in vehicles():
		if not v.alive:
			continue
		var sp := _make_map_point(v.global_position, ctr, k)
		if not scr.has_point(sp):
			continue
		var hdg := fposmod(-rad_to_deg(v.global_rotation.y), 360.0)
		var octant := int(roundf(hdg / 45.0)) % OCTANTS
		var ic := canvas.dba(str(_icons().get("dba", "ICONS")), _icon_base(v) + int(offsets[octant]))
		if ic:
			var o := _icon_origin(ic, sp)
			canvas.blit(ic, o.x, o.y, scr)


func _icon_base(v: Node) -> int:
	var icons := _icons()
	if v == herc:
		return int(icons.get("self", 18))
	if v == herc.target:
		return int(icons.get("target", 36))
	return int(icons.get("friend", 27)) if v.team == herc.team else int(icons.get("enemy", 9))


# ---- DAMAGE page

func _draw_damage(scr: Rect2, area: Rect2) -> void:
	var key := make_unit_key(herc)
	var pdg := canvas.assets.load_pdg(key)
	if not pdg.is_empty() and pdg.images.size() > 0:
		var im: Dictionary = pdg.images[0]
		canvas.blit(canvas.assets.diagram(key, 0, herc), scr.position.x + float(im.origin[0]), scr.position.y + float(im.origin[1]), scr)
	var y := area.position.y
	canvas.text(skin.font("mfd", "label_font"), area.position.x, y, label("damage_titles", 0, " STRUCT DAMAGE"), area)
	y += 10
	for i in mini(herc.components.size(), MAX_DAMAGE_ROWS):
		var c: Dictionary = herc.components[i]
		if c.get("name", "") == "" or float(c.max) <= 1.0:
			continue
		_draw_damage_row(area, y, i, c)
		y += DAMAGE_ROW_HEIGHT
		if y > area.end.y - DAMAGE_ROW_HEIGHT:
			break


func _draw_damage_row(area: Rect2, y: float, i: int, c: Dictionary) -> void:
	var f := clampf(float(c.hp) / maxf(float(c.max), 1.0), 0.0, 1.0)
	var font := _health_font(f)
	canvas.text(font, area.position.x, y, label("components", i, str(c.name)), area)
	var pct := "%d%%" % int(f * 100.0)
	canvas.text(font, area.end.x - canvas.text_width(font, pct) - 1, y, pct, area)


## Damage list colours: the page font when healthy, then yellow, then red.
func _health_font(f: float) -> String:
	if f > CockpitAssets.HEALTH_GOOD:
		return _font()
	return "CPYLW" if f > CockpitAssets.HEALTH_FAIR else "CPRED"


# ---- wingman windows

func _draw_wingmen(d: Dictionary) -> void:
	var b: Array = d.buttons
	var leds: Array = d.get("wingman_leds", [])
	var wing := wingmen()
	for k in WINGMAN_WINDOWS:
		var r := CockpitCanvas.rect_of(b[10 + k])
		if k < wing.size():
			var slot := WingmanRadio.slot_of(wing[k])
			_draw_pilot(r, WingmanRadio.pilot_number(slot if slot >= 0 else k), is_transmitting(wing[k]))
			if k < leds.size() and is_transmitting(wing[k]):
				canvas.fill(CockpitCanvas.rect_of(leds[k]), skin_color("hdd", "led_color", C_GREEN_B))
		else:
			var f := int(display.time * STATIC_FPS + k * 2) % STATIC_FRAMES
			canvas.blit(canvas.dba("STATIC", f), r.position.x, r.position.y, r)


## The comm window's transmit lamp (cockpit.md 3.8, [L]): lit while this wingman's voice is on the radio.
func is_transmitting(unit: Node) -> bool:
	var battle := herc.get_parent() if herc else null
	var chat = battle.get("chat") if battle else null
	var radio = chat.get("radio") if chat else null
	return radio != null and radio.is_speaker_talking(str(unit.get("display_name")))


## The face frame of a comm window: while the pilot's line plays, the face frames (PILOTn.DBA 2..23, the mouth and
## brow positions of the original's 24 face frames) run at TALK_FPS in a fixed pseudo-random order so the mouth
## moves; idle: frame 0 with a blink (frame 1). The original's frame order is not traced (L).
static func make_face_frame(pilot: int, talking: bool, time: float, face_count: int) -> int:
	if not talking:
		return 0 if fmod(time + pilot, BLINK_EVERY) > BLINK_LENGTH else 1
	var n := maxi(face_count - TALK_FIRST, 1)
	var step := int(time * TALK_FPS)
	return TALK_FIRST + int(absi(step * 7 + (step * step) % 5 + pilot * 3) % n)


## Wingman `pilot`'s talking head: background picture plus the face (blinking now and then).
func _draw_pilot(r: Rect2, pilot: int, talking := false) -> void:
	var meta = canvas.assets.pilot_meta(pilot)
	if meta == null:
		return
	var setn := "PILOT%d" % pilot
	var sizes: Array = meta.sets.get(setn, [])
	if sizes.is_empty():
		return
	var ofs := {}
	for o in meta.ofs:
		ofs[int(o[0])] = Vector2(float(o[1]), float(o[2]))
	canvas.fill(r, Color.BLACK)
	canvas.blit(canvas.assets.texture("pilots/%s_%d.png" % [setn, sizes.size() - 1]), r.position.x, r.position.y + 4, r)
	var face := make_face_frame(pilot, talking, display.time, mini(sizes.size() - 4, TALK_FIRST + TALK_FRAMES))
	var fo: Vector2 = ofs.get(face, Vector2.ZERO)
	canvas.blit(canvas.assets.texture("pilots/%s_%d.png" % [setn, face]), r.position.x + fo.x, r.position.y + fo.y + 4, r)

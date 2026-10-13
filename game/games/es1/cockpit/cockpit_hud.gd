class_name CockpitHud
extends CockpitPainter
## The head-up display in the front view: heading tape with the waypoint marker, torso-twist and pitch
## sliders, reticle and the target box (docs/formats/cockpit.md 3.6 / 8.4). Each element uses the game's
## bitmaps when the skin names them (Earthsiege 2: HUD.HBA reticles, brackets, slider), else the
## Earthsiege 1 slider bitmaps and drawn reticle / corners. Earthsiege 2 also shows speed and mission time
## texts and, in a flyer, the altimeter.

const TAPE_PX_PER_DEG := 3.0        # HUDHTICK: 60 px per 20 degrees
const TAPE_STRIP_PX := 120.0        # one HUDHTICK strip covers 40 degrees
const TAPE_STRIP_COUNT := 9
const TAPE_HEIGHT := 8.0
const TORSO_SLIDER_RANGE_DEG := 80.0   # slider rect inset 15/10, +-80 degrees
const TORSO_SLIDER_TRAVEL := 32.0
const PITCH_SLIDER_TRAVEL := 7.0
const RETICLE_ARM := 4
const TARGET_LOW := 1.0             # metres above the target's origin: box bottom
const TARGET_HIGH := 9.0            # box top
const TARGET_BOX_MIN := 4.0
const TARGET_BOX_MAX := 30.0
const FULL_BRIGHTNESS := 75.0
const MIN_HUD_ALPHA := 0.35
const ANGLE_UNITS := 65536.0        # 3Space angle units per turn
const MPS_TO_KPH := 3.6
const FRIENDLY := 0
const HOSTILE := 1


func draw() -> void:
	var h := gauge("hud")
	if not h.has("heading_tape"):
		return
	var mod := make_brightness_mod()
	var tr := CockpitCanvas.rect_of(h.heading_tape)
	var cx := floorf(tr.position.x + tr.size.x * 0.5)
	var heading := HeadingFrame.make_heading_deg(herc)
	_draw_heading_tape(tr, cx, heading, mod)
	_draw_waypoint(h, tr, cx, heading, mod)
	if h.has("torso_slider"):
		_draw_torso_bitmap_slider(CockpitCanvas.rect_of(h.torso_slider), mod)
	else:
		_draw_torso_slider(tr.position.y + 10.0, cx, mod)
	if h.has("pitch_slider"):
		_draw_pitch_slider(CockpitCanvas.rect_of(h.pitch_slider), mod)
	_draw_reticle(h, mod)
	_draw_target_box(Vector2(float(h.center[0]), float(h.center[1])), CockpitCanvas.rect_of(h.target_area), mod)
	_draw_readouts(h, mod)


## HUD tint from the brightness buttons (75 = the original full brightness).
func make_brightness_mod() -> Color:
	return Color(1, 1, 1, clampf(display.brightness / FULL_BRIGHTNESS, MIN_HUD_ALPHA, 1.0))


func _hud_dba() -> String:
	return skin.dba("hud")


func _draw_heading_tape(tr: Rect2, cx: float, heading: float, mod: Color) -> void:
	# strip k covers [40k-20, 40k+20] degrees in its first 120 px
	var p := (heading + 20.0) * TAPE_PX_PER_DEG
	var tape_clip := Rect2(tr.position.x, tr.position.y, tr.size.x, TAPE_HEIGHT)
	var tape := str(skin.value("hud", "tape_dba", "HUDHTICK"))
	for k in range(-1, 10):
		var x := cx - p + TAPE_STRIP_PX * k
		if x > tr.end.x or x + 128.0 < tr.position.x:
			continue
		canvas.blit(canvas.dba(tape, posmod(k, TAPE_STRIP_COUNT)), x, tr.position.y, tape_clip, mod)


## Marker on the tape; the "WP n: dddd M." text under it (Earthsiege 2: at the HUD's nav point, unless the
## Herc flies: the altimeter sits there).
func _draw_waypoint(h: Dictionary, tr: Rect2, cx: float, heading: float, mod: Color) -> void:
	var wp := make_current_waypoint()
	if wp.is_empty():
		return
	var rel: Vector3 = wp.pos - herc.global_position
	var dd := wrapf(HeadingFrame.make_bearing_deg(herc.global_position, wp.pos) - heading, -180.0, 180.0)
	var mx := clampf(cx + dd * TAPE_PX_PER_DEG, tr.position.x, tr.end.x - 1)
	canvas.fill(Rect2(mx - 1, tr.position.y + TAPE_HEIGHT, 3, 2), skin_color("hud", "marker_color", C_YELLOW) * mod)
	if herc is Flyer and h.has("nav_text"):
		return
	var dist := Vector2(rel.x, rel.z).length()
	var at := Vector2(tr.position.x + 2, tr.end.y + 3)
	if h.has("nav_text"):
		at = Vector2(float(h.nav_text[0]), float(h.nav_text[1]))
	canvas.text(skin.font("hud", "nav_font"), at.x, at.y, "WP %s: %d M." % [wp.label, int(dist)], CockpitCanvas.NO_CLIP,
		_text_tint(), mod)


## Tint of the HUD texts (Earthsiege 1: its black font recoloured yellow; -1: the font's own colour).
func _text_tint() -> Color:
	var c := int(skin.value("hud", "text_color", C_YELLOW))
	return canvas.color(c) if c >= 0 else CockpitCanvas.NO_TINT


## The mission's current nav point, else the nearest nav point: {pos, label} or {} (HeadingFrame).
func make_current_waypoint() -> Dictionary:
	return HeadingFrame.make_current_waypoint(herc, display.battle)


func _draw_torso_slider(sy: float, cx: float, mod: Color) -> void:
	canvas.blit(canvas.dba("HUDHSLID", 0), cx - 48, sy, CockpitCanvas.NO_CLIP, mod)
	var tw := clampf(-herc.torso_yaw / deg_to_rad(TORSO_SLIDER_RANGE_DEG), -1.0, 1.0)
	var at_lim := absf(herc.torso_yaw) >= herc.torso_limit - 0.01
	canvas.blit(canvas.dba("HUDHSLID", 2 if at_lim else 1), cx - 16 + roundf(tw * TORSO_SLIDER_TRAVEL), sy, CockpitCanvas.NO_CLIP, mod)


## Earthsiege 2 (HFixRotationGauge 0x43b4a0): track bitmap over the slider rect, marker sliding +-80
## degrees across it; the marker turns to its "centred" frame within +-300 angle units of straight ahead.
func _draw_torso_bitmap_slider(r: Rect2, mod: Color) -> void:
	var track := canvas.dba(_hud_dba(), skin.frame("hud", "torso_track"))
	canvas.blit(track, r.position.x, r.position.y, CockpitCanvas.NO_CLIP, mod)
	var centred := absf(herc.torso_yaw) < float(skin.value("hud", "torso_centred_units", 0)) / ANGLE_UNITS * TAU
	var marker := canvas.dba(_hud_dba(), skin.frame("hud", "torso_marker_centred" if centred else "torso_marker"))
	if track == null or marker == null:
		return
	var ts := canvas.size_of(track)
	var ms := canvas.size_of(marker)
	var travel := (ts.x - ms.x) * 0.5
	var tw := clampf(-herc.torso_yaw / deg_to_rad(TORSO_SLIDER_RANGE_DEG), -1.0, 1.0)
	canvas.blit(marker, r.position.x + travel + roundf(tw * travel), r.position.y + roundf((ts.y - ms.y) * 0.5),
		CockpitCanvas.NO_CLIP, mod)


func _draw_pitch_slider(pr: Rect2, mod: Color) -> void:
	canvas.blit(canvas.dba("HUDVSLID", 0), pr.position.x, pr.position.y, CockpitCanvas.NO_CLIP, mod)
	var pmax := maxf(absf(herc.pitch_max), absf(herc.pitch_min))
	var pf := clampf(herc.pitch / maxf(pmax, 0.01), -1.0, 1.0)
	canvas.blit(canvas.dba("HUDVSLID", 1), pr.position.x,
		pr.position.y + PITCH_SLIDER_TRAVEL - roundf(pf * PITCH_SLIDER_TRAVEL), CockpitCanvas.NO_CLIP, mod)


func _draw_reticle(h: Dictionary, mod: Color) -> void:
	var c := Vector2(float(h.center[0]), float(h.center[1]))
	var frames := skin.list("hud", "reticle")
	if frames.is_empty():
		_draw_pixel_reticle(c, int(h.get("reticle_half", 3)), canvas.color(C_GREEN_B) * mod)
		return
	var tex := canvas.dba(_hud_dba(), int(frames[_make_reticle_state(c) if frames.size() > 2 else 0]))
	if tex:
		var sz := canvas.size_of(tex)
		canvas.blit(tex, c.x - sz.x * 0.5, c.y - sz.y * 0.5, CockpitCanvas.NO_CLIP, mod)


func _draw_pixel_reticle(c: Vector2, q: int, green: Color) -> void:
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		for i in range(q, q + RETICLE_ARM):
			canvas.fill(Rect2(c + d * i, Vector2.ONE), green)
	canvas.fill(Rect2(c, Vector2.ONE), green)


## Earthsiege 2 crosshair (0x43b7e0): frame 0 without a target or when the target is not within
## +-reticle_lock_px of the crosshair, else 1 (hostile) / 2 (friendly).
func _make_reticle_state(c: Vector2) -> int:
	if not has_live_target():
		return 0
	var p = display.make_virtual_point(herc.target.global_position + Vector3.UP * (TARGET_LOW + TARGET_HIGH) * 0.5)
	var lock := float(skin.value("hud", "reticle_lock_px", 0))
	if p == null or absf(p.x - c.x) > lock or absf(p.y - c.y) > lock:
		return 0
	return 1 if _is_hostile(herc.target) else 2


func _is_hostile(t: Node) -> bool:
	return TargetInfo.is_hostile(herc, t)


func _draw_target_box(c: Vector2, area: Rect2, mod: Color) -> void:
	if not has_live_target():
		return
	var t: Node3D = herc.target
	var a = display.make_virtual_point(t.global_position + Vector3.UP * TARGET_LOW)
	var b = display.make_virtual_point(t.global_position + Vector3.UP * TARGET_HIGH)
	if a == null or b == null:
		return
	var ctr: Vector2 = (a + b) * 0.5
	var half := clampf(absf(a.y - b.y) * 0.6, TARGET_BOX_MIN, TARGET_BOX_MAX)
	var r := Rect2(ctr - Vector2(half, half), Vector2(half, half) * 2.0).abs()
	r.position = r.position.round()
	r.size = r.size.round()
	var corners := skin.list("hud", "target_corner")
	if corners.is_empty():
		_draw_es1_target_box(t, r, half, mod, area)
	else:
		var side := HOSTILE if _is_hostile(t) else FRIENDLY
		_draw_bitmap_brackets(r, int(corners[side]), mod)
		_draw_pipper(ctr, side, mod)


## Earthsiege 1 box: yellow corners and the target's integrity under them. A friendly or neutral target (remake,
## playtest A5: the original only targets hostiles) gets corners in its friend-or-foe colour and its IFF word.
func _draw_es1_target_box(t: Node3D, r: Rect2, half: float, mod: Color, area: Rect2) -> void:
	var hostile := TargetInfo.is_hostile(herc, t)
	var col := canvas.color(C_YELLOW) if hostile else TargetInfo.make_iff_color(herc, t)
	_draw_corners(r, maxf(2.0, roundf(half * 0.5)), col * mod, area)
	var pct := int(TargetInfo.make_integrity(t) * 100.0)
	var text := "[ %d%% ]" % pct if hostile else "[ %s %d%% ]" % [TargetInfo.make_iff_text(herc, t), pct]
	canvas.text("CPBLACK", r.position.x - 3, r.end.y + 3, text, area, canvas.color(C_LIGHT_YELLOW) if hostile else col, mod)


func _draw_corners(r: Rect2, ln: float, col: Color, area: Rect2) -> void:
	for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		var pt: Vector2 = r.position + r.size * corner
		var sx := -1.0 if corner.x > 0 else 1.0
		var sy := -1.0 if corner.y > 0 else 1.0
		canvas.fill(Rect2(Vector2(pt.x if sx > 0 else pt.x - ln, pt.y), Vector2(ln, 1)), col, area)
		canvas.fill(Rect2(Vector2(pt.x, pt.y if sy > 0 else pt.y - ln), Vector2(1, ln)), col, area)


## Earthsiege 2 (HUDLockingGunsight 0x43bbd0): one corner bitmap, mirrored into the box's four corners.
func _draw_bitmap_brackets(r: Rect2, frame: int, mod: Color) -> void:
	var tex := canvas.dba(_hud_dba(), frame)
	if tex == null:
		return
	var sz := canvas.size_of(tex)
	for corner in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		var x: float = r.position.x + (r.size.x - sz.x) * corner.x
		var y: float = r.position.y + (r.size.y - sz.y) * corner.y
		canvas.blit_flipped(tex, x, y, corner, mod)


func _draw_pipper(ctr: Vector2, side: int, mod: Color) -> void:
	var pippers := skin.list("hud", "target_pipper")
	if pippers.size() <= side:
		return
	var tex := canvas.dba(_hud_dba(), int(pippers[side]))
	if tex:
		var sz := canvas.size_of(tex)
		canvas.blit(tex, roundf(ctr.x - sz.x * 0.5), roundf(ctr.y - sz.y * 0.5), CockpitCanvas.NO_CLIP, mod)


# ---- Earthsiege 2 texts and the flyer altimeter

func _draw_readouts(h: Dictionary, mod: Color) -> void:
	if h.has("speed_text"):
		_draw_centred_text(h.speed_text, "%d K/H" % int(absf(herc.speed) * MPS_TO_KPH), mod)
	if h.has("clock_text"):
		_draw_centred_text(h.clock_text, make_clock_text(), mod)
	if herc is Flyer and h.has("nav_text"):
		_draw_altimeter(Vector2(float(h.nav_text[0]), float(h.nav_text[1])), herc as Flyer, mod)


## A HUD text centred on layout point `p` (both texts sit +-60 px either side of the screen centre; their
## exact alignment flag is not decoded).
func _draw_centred_text(p: Array, s: String, mod: Color) -> void:
	var f := skin.font("hud", "text_font")
	canvas.text(f, roundf(float(p[0]) - canvas.text_width(f, s) * 0.5), float(p[1]), s, CockpitCanvas.NO_CLIP, _text_tint(), mod)


## Flyer altimeter (0x43dd70): caps above and below a dotted scale, the marker at the altitude between the
## ground (bottom) and the flight ceiling + ceiling_margin (top).
func _draw_altimeter(at: Vector2, fl: Flyer, mod: Color) -> void:
	var alt: Dictionary = skin.value("hud", "altimeter", {})
	if alt.is_empty():
		return
	var height := float(alt.height)
	var top := canvas.dba(_hud_dba(), int(alt.top))
	var bottom := canvas.dba(_hud_dba(), int(alt.bottom))
	var scale := canvas.dba(_hud_dba(), int(alt.scale))
	var marker := canvas.dba(_hud_dba(), int(alt.marker))
	if top == null or bottom == null or marker == null:
		return
	canvas.blit(top, at.x, at.y, CockpitCanvas.NO_CLIP, mod)
	canvas.blit(bottom, at.x, at.y + height - canvas.size_of(bottom).y, CockpitCanvas.NO_CLIP, mod)
	canvas.blit(scale, at.x + (canvas.size_of(top).x - canvas.size_of(scale).x) * 0.5, at.y + canvas.size_of(top).y,
		CockpitCanvas.NO_CLIP, mod)
	var ceiling := fl.flight.make_ceiling() + float(alt.ceiling_margin) * Assets.UNIT
	var f := clampf(fl.make_altitude() / maxf(ceiling, 1.0), 0.0, 1.0)
	var ms := canvas.size_of(marker)
	canvas.blit(marker, at.x + (canvas.size_of(top).x - ms.x) * 0.5, roundf(at.y + (height - ms.y) * (1.0 - f)),
		CockpitCanvas.NO_CLIP, mod)

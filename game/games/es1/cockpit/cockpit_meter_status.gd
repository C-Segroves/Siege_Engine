class_name CockpitMeterStatus
extends CockpitMeterPainter
## Starsiege status meters (tools/starsiege_hud.py):
##   shields          HudMtrShields 0x519350: SHIELDS art with the STRCIRCLE ring recoloured segment by segment
##                    (0x51a258: bright around the shield focus, fading, dark behind) and the strength in %;
##   weapons          HudMtrWeapDisplay 0x51fea8: a row per weapon: name (font by state), three group circles
##                    (filled = the weapon fires in that group), the ammo count right-aligned;
##   damage_self /    HudMtrDamage 0x522b68: label, DAM_SELF / DAM_TAR art and a live 3D model of the own
##   damage_target    vehicle / the target in its damage colours (TargetView, as the plain HUD's target picture);
##   internal_damage  HudMtrIntDamage 0x523a30: "Internals Status:" and one line per internal system.
## The remake's front / rear shields map onto the ring: the focus points at the stronger side.

const SHIELD_SEGMENTS := 48
const SHIELD_FOCUS_STEPS := 8.0
const SHIELD_HALF_RING := 24
const COLOR_BRIGHT := 246
const COLOR_MID := 245
const COLOR_DIM := 244
const COLOR_BACK := 247
const SHIELD_TEXT_OFFSET := Vector2(40, 40)
const ROW_CIRCLE_GAP := 16.0
const CIRCLE_RISE := 3.0
const MODEL_VIEW := 64
const DEFAULT_ROW_HEIGHT := 13.0
const INTERNAL_OK := "OK"
const INTERNAL_DAMAGED := "DAMAGED"
const INTERNAL_DESTROYED := "DESTROYED"

var _self_view: TargetView
var _target_view: TargetView
var _ring_cache := {}                # LUT key -> texture


func _init(p_display: CockpitDisplay, p_canvas: CockpitCanvas) -> void:
	super(p_display, p_canvas)
	_self_view = TargetView.new(Vector2i(MODEL_VIEW, MODEL_VIEW), TargetLitPaint.new())
	_target_view = TargetView.new(Vector2i(MODEL_VIEW, MODEL_VIEW), TargetLitPaint.new())
	display.add_child(_self_view)
	display.add_child(_target_view)


## Keeps the two model views on the own vehicle and the target (only while the HUD shows, and only for the
## damage meters the HUD has: Battledrome and Tribes HUDs show no model pictures).
func follow(on: bool, delta: float) -> void:
	_self_view.apply_target(herc if on and _has_meter("damage_self") else null)
	_target_view.apply_target(live_target() if on and _has_meter("damage_target") else null)
	_self_view.advance(delta)
	_target_view.advance(delta)


func _has_meter(kind: String) -> bool:
	return (display.layout.get("meters", []) as Array).any(func(m): return str(m.get("kind", "")) == kind)


func draw_meter(m: Dictionary) -> void:
	match str(m.kind):
		"shields":
			if herc.shield_max > 0.0:
				_draw_shields(m)
		"weapons":
			_draw_weapons(m)
		"damage_self":
			_draw_damage(m, _self_view)
		"damage_target":
			_draw_damage(m, _target_view)
		"internal_damage":
			_draw_internals(m)


# ------------------------------------------------------------------ shields

func _draw_shields(m: Dictionary) -> void:
	var f := maxf(herc.shield_front, 0.0)
	var r := maxf(herc.shield_rear, 0.0)
	var strength := clampf((f + r) / maxf(herc.shield_max, 1.0), 0.0, 1.0)
	var focus := 0.5 + 0.5 * absf(f - r) / maxf(f + r, 1.0)
	var centre := 1 if f >= r else SHIELD_HALF_RING + 1
	var lut := make_ring_lut(centre, focus, strength)
	var at: Array = m.rect
	canvas.blit(_make_ring_texture(m, lut), float(at[0]), float(at[1]), CockpitCanvas.NO_CLIP, meter_mod(m))
	canvas.text(str(m.get("font", "")), float(at[0]) + SHIELD_TEXT_OFFSET.x, float(at[1]) + SHIELD_TEXT_OFFSET.y,
		"%d%%" % int(roundf(strength * 100.0)), CockpitCanvas.NO_CLIP, CockpitCanvas.NO_TINT, meter_mod(m))


## Palette index per ring segment (0x51a258): segment `centre` is the focus; within round(8 focus) segments of it
## bright, beyond 24 - round(8 (focus - 0.5)) dark, between them mid then dim. No strength: all dark.
static func make_ring_lut(centre: int, focus: float, strength: float) -> Array:
	var lut := [COLOR_BACK]
	var n1 := int(roundf(focus * SHIELD_FOCUS_STEPS))
	var n2 := SHIELD_HALF_RING - (int(roundf((focus - 0.5) * SHIELD_FOCUS_STEPS)) if focus > 0.5 else 0)
	var n3 := (n2 - n1) / 2 + n1
	for k in range(1, SHIELD_SEGMENTS + 1):
		var e := posmod(k - centre, SHIELD_SEGMENTS) + 1
		lut.append(COLOR_BACK if strength <= 0.0 else _make_ring_color(e, n1, n2, n3))
	return lut


static func _make_ring_color(e: int, n1: int, n2: int, n3: int) -> int:
	var within := func(n: int) -> bool: return e <= n or e > SHIELD_SEGMENTS - n
	if within.call(n1):
		return COLOR_BRIGHT
	if not within.call(n2):
		return COLOR_BACK
	return COLOR_MID if within.call(n3) else COLOR_DIM


func _make_ring_texture(m: Dictionary, lut: Array) -> Texture2D:
	var key := str(lut)
	if _ring_cache.has(key):
		return _ring_cache[key]
	var art := Assets.load_image("cockpit/dba/%s/0.png" % m.dba, display.pack)
	var ring := Assets.load_image("cockpit/dba/%s/0.png" % m.get("ring_dba", ""), display.pack)
	if art == null:
		return null
	if ring != null:
		var off: Array = m.get("ring_offset", [0, 0])
		for y in ring.get_height():
			for x in ring.get_width():
				var seg := ring.get_pixel(x, y).r8
				var tx := x + int(off[0])
				var ty := y + int(off[1])
				if seg > 0 and seg < lut.size() and tx < art.get_width() and ty < art.get_height():
					art.set_pixel(tx, ty, Color8(int(lut[seg]), 0, 0))
	_ring_cache[key] = canvas.assets.make_index_texture(art)
	return _ring_cache[key]


# ------------------------------------------------------------------ weapons

func _draw_weapons(m: Dictionary) -> void:
	var mod := meter_mod(m)
	var row_h := float(m.get("row_height", DEFAULT_ROW_HEIGHT))
	var pad := float(m.get("row_pad", 0))
	var x0 := float(m.rect[0])
	var y := _make_weapons_top(m, row_h, pad) + pad
	var gcw := float(m.get("group_column_width", 15))
	var fonts: Dictionary = m.get("fonts", {})
	for w in herc.weapons:
		var font := str(fonts.get("selected" if w.trigger else ("ready" if w.ready_to_fire() else "unready"), m.get("font", "")))
		var cx := x0 + gcw + float(m.get("name_width", 60)) + ROW_CIRCLE_GAP
		canvas.text(font, x0 + gcw, y, str(w.display_name), Rect2(x0 + gcw, y, cx - x0 - gcw - CIRCLE_RISE, row_h),
			CockpitCanvas.NO_TINT, mod)
		for k in int(m.get("groups", 3)):
			var tex := canvas.dba(str(m.dba) if w.group == k else str(m.get("dba_open", m.dba)), 0)
			canvas.blit(tex, cx + k * gcw, y + CIRCLE_RISE, CockpitCanvas.NO_CLIP, mod)
		if w.ammo >= 0:
			var s := str(w.ammo)
			canvas.text(font, float(m.rect[2]) - canvas.text_width(font, s), y, s, CockpitCanvas.NO_CLIP, CockpitCanvas.NO_TINT, mod)
		y += row_h


## The list grows with the weapon count: (rows + 1) row heights plus a pad (0x51fd94), placed by the meter's
## screen fraction (top = (canvas height - height) x fraction, 0x50c174).
func _make_weapons_top(m: Dictionary, row_h: float, pad: float) -> float:
	if not m.has("layout_fraction"):
		return float(m.rect[1])
	var h := row_h * float(herc.weapons.size() + 1) + pad
	return floorf((display.canvas_size.y - h) * float(m.layout_fraction[1]))


# ------------------------------------------------------------------ damage pictures and internals

func _draw_damage(m: Dictionary, view: TargetView) -> void:
	var mod := meter_mod(m)
	var x := float(m.rect[0])
	var y := float(m.rect[1])
	var lo: Array = m.get("label_offset", [0, 0])
	var font := str(m.get("font", ""))
	canvas.text(font, x + float(lo[0]), y + float(lo[1]), str(m.get("label", "")), CockpitCanvas.NO_CLIP, CockpitCanvas.NO_TINT, mod)
	var ao: Array = m.get("art_offset", [0, 0])
	var art := canvas.dba(str(m.dba), 0)
	canvas.blit(art, x + float(ao[0]), y + float(ao[1]), CockpitCanvas.NO_CLIP, mod)
	if view.has_target() and art != null:
		var sz := canvas.size_of(art)
		var c := Vector2(x + float(ao[0]), y + float(ao[1])) + sz * 0.5
		canvas.blit(view.get_texture(), c.x - MODEL_VIEW * 0.5, c.y - MODEL_VIEW * 0.5)


func _draw_internals(m: Dictionary) -> void:
	var mod := meter_mod(m)
	var font := str(m.get("font", ""))
	var x := float(m.rect[0])
	var y := float(m.rect[1])
	var step := canvas.font_height(font) + 2.0
	canvas.text(font, x, y, str(m.get("title", "")), CockpitCanvas.NO_CLIP, CockpitCanvas.NO_TINT, mod)
	for line in make_internal_lines():
		y += step
		canvas.text(font, x, y, line, CockpitCanvas.NO_CLIP, CockpitCanvas.NO_TINT, mod)


## "ENGINE: OK" ... (the remake's systems: the structure for the engine and the sensors, the beam capacitor for
## the reactor, the shields' charge), worded by damage level: intact OK, destroyed DESTROYED, else DAMAGED.
func make_internal_lines() -> Array:
	var shields := 1.0 if herc.shield_max <= 0.0 else (herc.shield_front + herc.shield_rear) / herc.shield_max
	var systems := [["ENGINE", herc.integrity], ["REACTOR", herc.capacitor / maxf(herc.capacitor_max, 1.0)],
		["SHIELDS", shields], ["SENSORS", herc.integrity]]
	var out := []
	for s in systems:
		out.append("%s: %s" % [s[0], _make_state(float(s[1]))])
	return out


static func _make_state(health: float) -> String:
	match DamageLevels.level_of(health):
		DamageLevels.INTACT:
			return INTERNAL_OK
		DamageLevels.DESTROYED:
			return INTERNAL_DESTROYED
	return INTERNAL_DAMAGED

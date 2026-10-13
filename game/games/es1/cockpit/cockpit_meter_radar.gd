class_name CockpitMeterRadar
extends CockpitMeterPainter
## Starsiege radar (HudMtrRadar, render 0x517874): RADAR_HIGH art (frame by mode) at the meter + art offset,
## contacts as 3x3 dots in the scope disc (layout "scope", the art's dark disc; heading up), coloured by team
## (0x517ed1: friends cyan 249, enemies red 242; the remake marks the target in the accent colour), the title
## "ACTIVE <range>m" centred at art + (91, -10) and the speed "<n>Kph" (0x518043). The range steps with
## cockpit_mode_4 (F4) like the Earthsiege scanner; the ranges are the remake's (L).

const RANGES_M := [500.0, 1000.0, 2000.0]
const DOT := 3.0
const SPEED_GAP := 2.0
const DEFAULT_FRIEND := 249
const DEFAULT_ENEMY := 242
const DEFAULT_TARGET := 248


func draw_meter(m: Dictionary) -> void:
	var mod := meter_mod(m)
	var r: Array = m.rect
	var off: Array = m.get("art_offset", [0, 0])
	var art := Vector2(float(r[0]) + float(off[0]), float(r[1]) + float(off[1]))
	var frames: Dictionary = m.get("frames", {})
	canvas.blit(canvas.dba(str(m.dba), int(frames.get("default", 0))), art.x, art.y, CockpitCanvas.NO_CLIP, mod)
	var range_m: float = RANGES_M[clampi(display.radar_range_i, 0, RANGES_M.size() - 1)]
	_draw_contacts(m, art, range_m)
	var font := str(m.get("font", ""))
	var title: Dictionary = m.get("title", {})
	if not title.is_empty():
		var c: Array = title.get("centre", [0, 0])
		var label: String = title.get("strings", ["ACTIVE"])[0]
		draw_text_centred(font, art.x + float(c[0]), art.y + float(c[1]), "%s %dm" % [label, int(range_m)], mod)
	if m.has("speed"):
		var s := "%dKph" % int(absf(herc.speed) * MPS_TO_KPH)
		canvas.text(font, float(r[0]), float(r[3]) - canvas.font_height(font) - SPEED_GAP, s, CockpitCanvas.NO_CLIP,
			CockpitCanvas.NO_TINT, mod)


## World point `at` on the heading-up scope as a share of its radius (x right, y down; HeadingFrame).
func make_scope_share(at: Vector3, range_m: float) -> Vector2:
	return HeadingFrame.make_radar_offset(herc.global_position, view_yaw(), at) / range_m


func _draw_contacts(m: Dictionary, art: Vector2, range_m: float) -> void:
	var sc: Array = m.get("scope", [0, 0, 1, 1])
	var scope := Rect2(art.x + float(sc[0]), art.y + float(sc[1]), float(sc[2]) - float(sc[0]), float(sc[3]) - float(sc[1]))
	var half := scope.size * 0.5
	var centre := scope.get_center()
	var colors: Dictionary = m.get("colors", {})
	RadarContacts.apply_range(herc, range_m)
	for v in vehicles():
		if v == herc or not v.alive or not RadarContacts.is_shown(herc, v):
			continue
		var p := make_scope_share(v.global_position, range_m)
		if p.length() > 1.0:
			continue
		var col_i := int(colors.get("team_0", DEFAULT_FRIEND)) if TargetInfo.is_friendly(herc, v) else int(colors.get("enemy", DEFAULT_ENEMY))
		if v == herc.target:
			col_i = int(colors.get("arc", DEFAULT_TARGET))
		var col := canvas.color(col_i)
		if MapTeams.shows_team_colors and v != herc.target and TargetInfo.is_hostile(herc, v):
			col = TargetInfo.make_iff_color(herc, v)   # more than two teams: each opposing team in its colour
		var q := (centre + p * half).round()
		canvas.fill(Rect2(q - Vector2.ONE, Vector2(DOT, DOT)), col)

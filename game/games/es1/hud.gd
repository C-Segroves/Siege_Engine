class_name HUD
extends Control
## In-cockpit heads-up display: crosshair, throttle/speed, armor, torso twist, compass with the waypoint, radar,
## target info (the view of soldiers on foot and of vehicles without a cockpit layout).

const MAX_MESSAGES := 5
const GREEN := Color(0.35, 1.0, 0.45)
const AMBER := Color(1.0, 0.75, 0.2)
const RED := Color(1.0, 0.3, 0.25)
const CYAN := Color(0.4, 0.9, 1.0)
const RADAR_RANGE := 1200.0         # metres
const RADAR_RADIUS := 110.0         # pixels
const AIM_DISTANCE := 300.0         # metres ahead of the torso for the crosshair
const BAR_HEIGHT := 200.0
const BAR_BOTTOM_MARGIN := 260.0
const MPS_TO_KPH := 3.6
const PITCH_LADDER_PX_PER_RAD := 120.0
## The speed readout sits above the THR label, clear of the CAP bar and the reverse (amber) extension.
const SPEED_READOUT_RISE := 28.0
## The target's model in its damage colours, untextured (TargetView + TargetFlatPaint), under its name and range.
const TARGET_VIEW_RECT := Rect2(20, 88, 160, 180)
const MESSAGE_WIDTH := 520
## Weapon rows the occupied-rect estimate allows for (the list grows upwards from the bottom).
const WEAPON_ROWS := 6
## Compass tape (HudCompass) across the top centre, above the torso twist bar.
const COMPASS_RECT := Rect2(-120, 6, 240, 22)
const COMPASS_FONT_SIZE := 11
## Room right of the tape for the waypoint's "WP n  d m".
const COMPASS_TEXT_WIDTH := 130.0

var herc: Herc
var camera: Camera3D
var messages: Array = []       # [text, time_left]
var font: Font
var target_view: TargetView


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font
	target_view = TargetView.new(Vector2i(TARGET_VIEW_RECT.size), TargetFlatPaint.new())
	add_child(target_view)


func message(text: String, time := 4.0) -> void:
	messages.append([text, time])
	if messages.size() > MAX_MESSAGES:
		messages.pop_front()


func _process(delta: float) -> void:
	size = get_viewport_rect().size
	for m in messages:
		m[1] -= delta
	messages = messages.filter(func(m): return m[1] > 0.0)
	target_view.apply_target(herc.target if herc != null and is_instance_valid(herc) and visible else null)
	target_view.advance(delta)
	queue_redraw()


func _draw() -> void:
	if herc == null:
		return
	var s := size
	var by := s.y - BAR_BOTTOM_MARGIN
	_draw_crosshair(s * 0.5)
	var on_foot := herc is Infantry   # a soldier has InfantryHud's energy / health bars instead of the vehicle's
	if not on_foot:
		_draw_throttle(30.0, by)
		_draw_armor_and_shields(s.x - 48.0, by)
	if herc is Flyer:
		_draw_flight(herc as Flyer, Vector2(s.x * 0.5, 40), Vector2(30.0 + 70.0, by))
	elif not on_foot:
		_draw_torso_twist(Vector2(s.x * 0.5, 40))
	HudCompass.draw(self, make_compass_rect(s), herc, HeadingFrame.make_current_waypoint(herc, herc.get_parent()),
		{"font": font, "font_size": COMPASS_FONT_SIZE, "color": GREEN, "marker_color": AMBER})
	_draw_radar(Vector2(s.x - 150, 150), RADAR_RADIUS)
	_draw_target()
	_draw_weapons(Vector2(s.x * 0.5 - 200, s.y - 30.0))   # on foot too: the carried weapons and their rounds
	_draw_messages(Vector2(s.x * 0.5 - 260, 90.0))


## Crosshair at the aim point (screen centre without a camera).
func _draw_crosshair(c: Vector2) -> void:
	var aim_pt := c
	if camera:
		var p := herc.aim_origin() + (-herc.aim_basis().z) * AIM_DISTANCE
		if not camera.is_position_behind(p):
			aim_pt = camera.unproject_position(p)
	draw_arc(aim_pt, 14, 0, TAU, 24, GREEN, 1.5)
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		draw_line(aim_pt + d * 6, aim_pt + d * 20, GREEN, 1.5)


## Throttle bar (reverse below it in amber), speed and the beam capacitor.
func _draw_throttle(bx: float, by: float) -> void:
	draw_rect(Rect2(bx, by, 18, BAR_HEIGHT), GREEN, false, 1.5)
	var tf := herc.throttle
	if tf >= 0:
		draw_rect(Rect2(bx + 2, by + BAR_HEIGHT - 196 * tf, 14, 196 * tf), GREEN)
	else:
		draw_rect(Rect2(bx + 2, by + BAR_HEIGHT, 14, 40 * -tf), AMBER)
	draw_string(font, Vector2(bx - 4, by - 8), "THR", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, GREEN)
	draw_string(font, Vector2(bx - 4, by - SPEED_READOUT_RISE), "%d KPH" % int(absf(herc.speed) * MPS_TO_KPH),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, GREEN)
	var cf := herc.capacitor / maxf(herc.capacitor_max, 1.0)
	draw_rect(Rect2(bx + 30, by + 120, 8, 80), AMBER, false, 1.0)
	draw_rect(Rect2(bx + 31, by + BAR_HEIGHT - 78 * cf, 6, 78 * cf), AMBER)
	draw_string(font, Vector2(bx + 24, by + 114), "CAP", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AMBER)


## Armor bar (green / amber / red by integrity) and the front / rear shield bars.
func _draw_armor_and_shields(ax: float, by: float) -> void:
	var af := clampf(herc.integrity, 0.0, 1.0)
	var acol := GREEN if af > 0.5 else (AMBER if af > 0.25 else RED)
	draw_rect(Rect2(ax, by, 18, BAR_HEIGHT), acol, false, 1.5)
	draw_rect(Rect2(ax + 2, by + BAR_HEIGHT - 196 * af, 14, 196 * af), acol)
	draw_string(font, Vector2(ax - 18, by - 8), "ARMOR", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, acol)
	var half := maxf(herc.shield_max * 0.5, 1.0)
	var sf := herc.shield_front / half
	var sr := herc.shield_rear / half
	draw_rect(Rect2(ax - 30, by, 8, 98), CYAN, false, 1.0)
	draw_rect(Rect2(ax - 29, by + 98 - 96 * sf, 6, 96 * sf), CYAN)
	draw_rect(Rect2(ax - 30, by + 102, 8, 98), CYAN, false, 1.0)
	draw_rect(Rect2(ax - 29, by + BAR_HEIGHT - 96 * sr, 6, 96 * sr), CYAN)
	draw_string(font, Vector2(ax - 44, by + 216), "SHLD F/R", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, CYAN)


func _draw_torso_twist(tw: Vector2) -> void:
	draw_line(tw - Vector2(120, 0), tw + Vector2(120, 0), GREEN, 1.0)
	var tx := -herc.torso_yaw / herc.torso_limit * 120.0
	draw_line(tw + Vector2(tx, -8), tw + Vector2(tx, 8), AMBER, 3.0)
	draw_line(tw + Vector2(0, -5), tw + Vector2(0, 5), GREEN, 1.0)


## Flyers: bank / pitch ladder in place of the torso twist, altitude above the ground and vertical
## speed next to the throttle (red above the ceiling).
func _draw_flight(fl: Flyer, horizon: Vector2, readout: Vector2) -> void:
	var tilt := Vector2(cos(fl.torso_yaw), sin(fl.torso_yaw)) * 120.0
	var lift := Vector2(0, fl.pitch * PITCH_LADDER_PX_PER_RAD)
	draw_line(horizon - tilt + lift, horizon + tilt + lift, GREEN, 1.5)
	draw_line(horizon + Vector2(-8, 0), horizon + Vector2(8, 0), AMBER, 2.0)
	var alt := fl.make_altitude()
	var col := RED if alt > fl.flight.make_ceiling() else GREEN
	draw_string(font, readout, "ALT %d m" % int(alt), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)
	draw_string(font, readout + Vector2(0, 20), "V/S %+.1f m/s" % fl.velocity.y, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, GREEN)
	if fl.flight.landed:
		draw_string(font, readout + Vector2(0, 40), "LANDED", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, AMBER)


func _draw_weapons(at: Vector2) -> void:
	var wy := at.y
	for w in herc.weapons:
		var ammo_txt: String = "" if w.ammo < 0 else " %d" % w.ammo
		draw_string(font, Vector2(at.x, wy), "%s%s" % [w.display_name, ammo_txt], HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
			GREEN if w.ready_to_fire() else AMBER)
		wy -= 18


## The newest message only: the chat panel (BattleChat) keeps the whole history.
func _draw_messages(at: Vector2) -> void:
	if not messages.is_empty():
		draw_string(font, at, messages[-1][0], HORIZONTAL_ALIGNMENT_LEFT, MESSAGE_WIDTH, 18, AMBER)


## The screen rects this HUD draws into on a window of size `s` (the chat panel's automatic placement avoids
## them, ChatPlacement): target box and picture, radar, throttle and flight readouts, armour and shields, the
## weapon list, the message line and the crosshair.
static func make_occupied_rects(s: Vector2) -> Array:
	var by := s.y - BAR_BOTTOM_MARGIN
	return [Rect2(16, 20, 172, TARGET_VIEW_RECT.end.y - 16), Rect2(s.x - 150 - RADAR_RADIUS, 150 - RADAR_RADIUS,
		RADAR_RADIUS * 2.0, RADAR_RADIUS * 2.0), Rect2(20, by - SPEED_READOUT_RISE - 18, 250, BAR_HEIGHT + 90),
		Rect2(s.x - 100, by - 24, 100, BAR_HEIGHT + 48), Rect2(s.x * 0.5 - 200, s.y - 30 - 18 * WEAPON_ROWS, 360, 18 * WEAPON_ROWS + 8),
		Rect2(s.x * 0.5 - 260, 70, MESSAGE_WIDTH, 26), Rect2(s.x * 0.5 - 130, 0, 260 + COMPASS_TEXT_WIDTH, 60), Rect2(s.x * 0.5 - 24, s.y * 0.5 - 24, 48, 48)]


## The compass band on a window of size `s`.
static func make_compass_rect(s: Vector2) -> Rect2:
	return Rect2(COMPASS_RECT.position + Vector2(s.x * 0.5, 0.0), COMPASS_RECT.size)


## Offset (pixels from the radar centre, heading up) of world point `at` on a radar of radius `r` (HeadingFrame).
func make_radar_point(at: Vector3, r: float) -> Vector2:
	return HeadingFrame.make_radar_offset(herc.global_position, HeadingFrame.make_heading(herc), at) / RADAR_RANGE * r


func _draw_radar(center: Vector2, r: float) -> void:
	draw_circle(center, r, Color(0, 0.15, 0.05, 0.55))
	draw_arc(center, r, 0, TAU, 48, GREEN, 1.5)
	draw_arc(center, r * 0.5, 0, TAU, 32, Color(GREEN, 0.4), 1.0)
	# view cone
	for a in [-0.5, 0.5]:
		draw_line(center, center + Vector2(sin(a), -cos(a)) * r, Color(GREEN, 0.3), 1.0)
	RadarContacts.apply_range(herc, RADAR_RANGE)
	for v in herc.get_tree().get_nodes_in_group("vehicles"):
		if v == herc or not v.alive or not RadarContacts.is_shown(herc, v):
			continue
		var p := make_radar_point(v.global_position, r)
		if p.length() > r:
			continue
		var col := TargetInfo.make_iff_color(herc, v)
		if v == herc.target:
			draw_rect(Rect2(center + p - Vector2(5, 5), Vector2(10, 10)), AMBER, false, 1.5)
		draw_circle(center + p, 3.5, col)
	for nav in herc.get_tree().get_nodes_in_group("nav_points"):
		var p := make_radar_point(nav.global_position, r)
		if p.length() > r:
			p = p.normalized() * r
		draw_string(font, center + p - Vector2(4, -5), str(nav.get_meta("label", "N")), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AMBER)


## Target box, name with its friend-or-foe word, range and health, in its friend-or-foe colour (A5).
func _draw_target() -> void:
	var t: Node3D = herc.target
	if not TargetInfo.is_live(t) or camera == null:
		return
	var col := TargetInfo.make_iff_color(herc, t)
	var p: Vector3 = Targeting.make_centre(t)
	var d := herc.global_position.distance_to(t.global_position)
	if not camera.is_position_behind(p):
		var sp := camera.unproject_position(p)
		var box := clampf(4000.0 / maxf(d, 1.0), 14.0, 80.0)
		draw_rect(Rect2(sp - Vector2(box, box), Vector2(box, box) * 2), col, false, 1.5)
	var title := "%s: %s" % [TargetInfo.make_iff_text(herc, t), TargetInfo.make_name(t)]
	draw_string(font, Vector2(20, 40), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)
	draw_string(font, Vector2(20, 60), "RANGE: %d m" % int(d), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)
	draw_rect(Rect2(20, 70, 160, 10), col, false, 1.0)
	draw_rect(Rect2(21, 71, 158 * TargetInfo.make_integrity(t), 8), col)
	if target_view.has_target():
		draw_texture(target_view.get_texture(), TARGET_VIEW_RECT.position)
		draw_rect(TARGET_VIEW_RECT, Color(AMBER, 0.5), false, 1.0)

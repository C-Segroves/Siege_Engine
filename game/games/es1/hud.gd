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
const BAR_HEIGHT := 160.0
const BAR_WIDTH := 18.0
## The reverse-throttle extension under the throttle bar.
const REVERSE_EXTENSION := 40.0
const CAP_BAR_HEIGHT := 80.0
const MPS_TO_KPH := 3.6
const PITCH_LADDER_PX_PER_RAD := 120.0
## The speed readout sits above the THR label, clear of the CAP bar and the reverse (amber) extension.
const SPEED_READOUT_RISE := 28.0
const SPEED_TEXT_ASCENT := 14.0
## The target panel (zone TARGET): name and friend-or-foe word, range, health bar, then the target's model in its
## damage colours, untextured (TargetView + TargetFlatPaint). Rows are offsets inside the panel.
const TARGET_VIEW_SIZE := Vector2i(160, 118)
const TARGET_TITLE_BASELINE := 16.0
const TARGET_RANGE_BASELINE := 36.0
const TARGET_BAR_TOP := 42.0
const TARGET_BAR_SIZE := Vector2(160, 10)
const TARGET_VIEW_TOP := 56.0
const TARGET_FONT_SIZE := 16
const TARGET_PANEL_SIZE := Vector2(172, TARGET_VIEW_TOP + TARGET_VIEW_SIZE.y)
const MESSAGE_WIDTH := 480
const MESSAGE_HEIGHT := 26.0
const MESSAGE_BASELINE := 18.0
## Weapon rows the weapon list shows (it grows upwards from the bottom of its zone).
const WEAPON_ROWS := 5
const WEAPON_ROW_HEIGHT := 18.0
const WEAPON_LIST_WIDTH := 360.0
## Compass tape (HudCompass) across the top centre, above the torso twist bar.
const COMPASS_SIZE := Vector2(240, 22)
const TORSO_BAR_HALF_WIDTH := 120.0
const TORSO_BAR_HEIGHT := 48.0
## How far the flyer's horizon line may leave the torso bar's middle.
const HORIZON_REACH := 20.0
const RADAR_BLOCK := Vector2(RADAR_RADIUS * 2.0, RADAR_RADIUS * 2.0)
const THROTTLE_BLOCK := Vector2(250, SPEED_TEXT_ASCENT + SPEED_READOUT_RISE + BAR_HEIGHT + REVERSE_EXTENSION)
## Armour block: the ARMOR label above its bar, the shield label under the shield bars.
const ARMOUR_LABEL_RISE := 22.0
const ARMOUR_BLOCK := Vector2(96, ARMOUR_LABEL_RISE + BAR_HEIGHT + 22.0)
const ARMOUR_BAR_LEFT := 44.0
const COMPASS_FONT_SIZE := 11
## Room right of the tape for the waypoint's "WP n  d m".
const COMPASS_TEXT_WIDTH := 130.0

var herc: Herc
var camera: Camera3D
var messages: Array = []       # [text, time_left]
var font: Font
var target_view: TargetView


func _ready() -> void:
	ServerProfile.apply_client_only(self)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font
	target_view = TargetView.new(TARGET_VIEW_SIZE, TargetFlatPaint.new())
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
	_declare_elements()
	queue_redraw()


## Tells the layout which panels this HUD shows now and how big they are.
func _declare_elements() -> void:
	var layout := HudLayout.of(self)
	var shown := herc != null and is_instance_valid(herc) and visible
	var vehicle := shown and not herc is Infantry
	layout.declare(&"compass", Vector2(COMPASS_SIZE.x + COMPASS_TEXT_WIDTH, COMPASS_SIZE.y) if shown else Vector2.ZERO)
	layout.declare(&"torso_bar", Vector2(TORSO_BAR_HALF_WIDTH * 2.0, TORSO_BAR_HEIGHT) if vehicle else Vector2.ZERO)
	layout.declare(&"message_line", Vector2(MESSAGE_WIDTH, MESSAGE_HEIGHT) if shown and not messages.is_empty() else Vector2.ZERO)
	layout.declare(&"radar", RADAR_BLOCK if shown else Vector2.ZERO)
	layout.declare(&"throttle_block", THROTTLE_BLOCK if vehicle else Vector2.ZERO)
	layout.declare(&"armour_block", ARMOUR_BLOCK if vehicle else Vector2.ZERO)
	layout.declare(&"target_panel", TARGET_PANEL_SIZE if shown and TargetInfo.is_live(herc.target) else Vector2.ZERO)
	var rows := mini(herc.weapons.size(), WEAPON_ROWS) if shown else 0
	layout.declare(&"weapon_list", Vector2(WEAPON_LIST_WIDTH, WEAPON_ROW_HEIGHT * rows + 4.0) if rows > 0 else Vector2.ZERO)


func _draw() -> void:
	if herc == null:
		return
	var layout := HudLayout.of(self)
	if not (herc is Infantry and InfantryHud.is_scope_shown(herc.get_parent(), herc)):
		_draw_crosshair(size * 0.5)   # the zoomed Laser Rifle draws its own reticle (InfantryHud); the crosshair follows the aim: no zone
	if layout.is_shown(&"throttle_block"):
		_draw_throttle(layout.rect_of(&"throttle_block"))
	if layout.is_shown(&"armour_block"):
		_draw_armor_and_shields(layout.rect_of(&"armour_block"))
	if layout.is_shown(&"torso_bar"):
		_draw_torso_bar(layout.rect_of(&"torso_bar"))
	_draw_compass(layout.rect_of(&"compass"))
	_draw_radar(layout.rect_of(&"radar").get_center(), RADAR_RADIUS)
	_draw_target(layout.rect_of(&"target_panel"))
	_draw_weapons(layout.rect_of(&"weapon_list"))
	_draw_messages(layout.rect_of(&"message_line"))


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


## Throttle bar (reverse below it in amber), speed and the beam capacitor, inside `block` (THROTTLE_BLOCK).
func _draw_throttle(block: Rect2) -> void:
	var bx := block.position.x + 4.0
	var by := block.position.y + SPEED_TEXT_ASCENT + SPEED_READOUT_RISE
	var fill := BAR_HEIGHT - 4.0
	draw_rect(Rect2(bx, by, BAR_WIDTH, BAR_HEIGHT), GREEN, false, 1.5)
	var tf := herc.throttle
	if tf >= 0:
		draw_rect(Rect2(bx + 2, by + BAR_HEIGHT - fill * tf, BAR_WIDTH - 4.0, fill * tf), GREEN)
	else:
		draw_rect(Rect2(bx + 2, by + BAR_HEIGHT, BAR_WIDTH - 4.0, REVERSE_EXTENSION * -tf), AMBER)
	draw_string(font, Vector2(bx - 4, by - 8), "THR", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, GREEN)
	draw_string(font, Vector2(bx - 4, by - SPEED_READOUT_RISE), "%d KPH" % int(absf(herc.speed) * MPS_TO_KPH),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, GREEN)
	var cf := herc.capacitor / maxf(herc.capacitor_max, 1.0)
	draw_rect(Rect2(bx + 30, by + BAR_HEIGHT - CAP_BAR_HEIGHT, 8, CAP_BAR_HEIGHT), AMBER, false, 1.0)
	draw_rect(Rect2(bx + 31, by + BAR_HEIGHT - (CAP_BAR_HEIGHT - 2.0) * cf, 6, (CAP_BAR_HEIGHT - 2.0) * cf), AMBER)
	draw_string(font, Vector2(bx + 24, by + BAR_HEIGHT - CAP_BAR_HEIGHT - 6.0), "CAP", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AMBER)
	if herc is Flyer:
		_draw_flight_readout(herc as Flyer, Vector2(bx + 70.0, by))


## Armor bar (green / amber / red by integrity) and the front / rear shield bars, inside `block` (ARMOUR_BLOCK).
func _draw_armor_and_shields(block: Rect2) -> void:
	var ax := block.position.x + ARMOUR_BAR_LEFT
	var by := block.position.y + ARMOUR_LABEL_RISE
	var fill := BAR_HEIGHT - 4.0
	var af := clampf(herc.integrity, 0.0, 1.0)
	var acol := GREEN if af > 0.5 else (AMBER if af > 0.25 else RED)
	draw_rect(Rect2(ax, by, BAR_WIDTH, BAR_HEIGHT), acol, false, 1.5)
	draw_rect(Rect2(ax + 2, by + BAR_HEIGHT - fill * af, BAR_WIDTH - 4.0, fill * af), acol)
	draw_string(font, Vector2(ax - 18, by - 8), "ARMOR", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, acol)
	var half := maxf(herc.shield_max * 0.5, 1.0)
	var sf := clampf(herc.shield_front / half, 0.0, 1.0)
	var sr := clampf(herc.shield_rear / half, 0.0, 1.0)
	var bar := BAR_HEIGHT * 0.5 - 2.0
	draw_rect(Rect2(ax - 30, by, 8, bar), CYAN, false, 1.0)
	draw_rect(Rect2(ax - 29, by + bar - (bar - 2.0) * sf, 6, (bar - 2.0) * sf), CYAN)
	draw_rect(Rect2(ax - 30, by + bar + 4.0, 8, bar), CYAN, false, 1.0)
	draw_rect(Rect2(ax - 29, by + BAR_HEIGHT - (bar - 2.0) * sr, 6, (bar - 2.0) * sr), CYAN)
	draw_string(font, Vector2(ax - 44, by + BAR_HEIGHT + 16.0), "SHLD F/R", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, CYAN)


## The torso twist scale of a Herc, or a flyer's bank / pitch horizon, in `bar` (the TORSO_BAR element).
func _draw_torso_bar(bar: Rect2) -> void:
	var tw := bar.get_center()
	if herc is Flyer:
		_draw_horizon(herc as Flyer, tw)
		return
	draw_line(tw - Vector2(TORSO_BAR_HALF_WIDTH, 0), tw + Vector2(TORSO_BAR_HALF_WIDTH, 0), GREEN, 1.0)
	var tx := -herc.torso_yaw / herc.torso_limit * TORSO_BAR_HALF_WIDTH
	draw_line(tw + Vector2(tx, -8), tw + Vector2(tx, 8), AMBER, 3.0)
	draw_line(tw + Vector2(0, -5), tw + Vector2(0, 5), GREEN, 1.0)


func _draw_compass(band: Rect2) -> void:
	HudCompass.draw(self, Rect2(band.position, COMPASS_SIZE), herc, HeadingFrame.make_current_waypoint(herc, herc.get_parent()),
		{"font": font, "font_size": COMPASS_FONT_SIZE, "color": GREEN, "marker_color": AMBER})


## Flyers: the bank / pitch horizon in place of the torso twist (kept inside the torso bar).
func _draw_horizon(fl: Flyer, horizon: Vector2) -> void:
	var tilt := Vector2(cos(fl.torso_yaw), sin(fl.torso_yaw)) * TORSO_BAR_HALF_WIDTH
	var lift := Vector2(0, clampf(fl.pitch * PITCH_LADDER_PX_PER_RAD, -HORIZON_REACH, HORIZON_REACH))
	tilt.y = clampf(tilt.y, -HORIZON_REACH, HORIZON_REACH)
	draw_line(horizon - tilt + lift, horizon + tilt + lift, GREEN, 1.5)
	draw_line(horizon + Vector2(-8, 0), horizon + Vector2(8, 0), AMBER, 2.0)


## Altitude above the ground and vertical speed next to the throttle (red above the ceiling).
func _draw_flight_readout(fl: Flyer, readout: Vector2) -> void:
	var alt := fl.make_altitude()
	var col := RED if alt > fl.flight.make_ceiling() else GREEN
	draw_string(font, readout + Vector2(0, 12), "ALT %d m" % int(alt), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)
	draw_string(font, readout + Vector2(0, 32), "V/S %+.1f m/s" % fl.velocity.y, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, GREEN)
	if fl.flight.landed:
		draw_string(font, readout + Vector2(0, 52), "LANDED", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, AMBER)


## The carried weapons and their rounds, bottom row first, in `list` (the WEAPON_LIST element).
func _draw_weapons(list: Rect2) -> void:
	if list.size == Vector2.ZERO:
		return
	var wy := list.end.y - 4.0
	for i in mini(herc.weapons.size(), WEAPON_ROWS):
		var w: Weapon = herc.weapons[i]
		var ammo_txt: String = "" if w.ammo < 0 else " %d" % w.ammo
		draw_string(font, Vector2(list.position.x, wy), "%s%s" % [w.display_name, ammo_txt], HORIZONTAL_ALIGNMENT_LEFT,
			WEAPON_LIST_WIDTH, 14, GREEN if w.ready_to_fire() else AMBER)
		wy -= WEAPON_ROW_HEIGHT


## The newest message only: the chat panel (BattleChat) keeps the whole history.
func _draw_messages(line: Rect2) -> void:
	if line.size != Vector2.ZERO and not messages.is_empty():
		draw_string(font, line.position + Vector2(0, MESSAGE_BASELINE), messages[-1][0], HORIZONTAL_ALIGNMENT_LEFT, MESSAGE_WIDTH, 18, AMBER)


## The screen rects this HUD draws into on a window of size `s` (the chat panel's automatic placement avoids
## them, ChatPlacement): every element of the plain HUD at its largest size, and the crosshair.
static func make_occupied_rects(s: Vector2) -> Array:
	return HudLayout.make_reserved_rects(s, HudLayout.PLAIN_HUD_IDS) + [make_crosshair_rect(s)]


## The crosshair's rect (screen centre) on a window of size `s`.
static func make_crosshair_rect(s: Vector2) -> Rect2:
	return Rect2(s * 0.5 - Vector2(24, 24), Vector2(48, 48))


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
	for v in RadarContacts.make_units(herc.get_tree()) + SensorTowers.make_radar_structures(herc):
		if v == herc or not v.alive or not RadarContacts.is_shown(herc, v):
			continue
		var p := make_radar_point(v.global_position, r)
		if p.length() > r:
			continue
		var col := RadarColors.make_unit_color(herc, v)
		if v == herc.target:
			draw_rect(Rect2(center + p - Vector2(5, 5), Vector2(10, 10)), AMBER, false, 1.5)
		if TeamRelations.is_allied(herc.team, v.team):
			UnitSymbols.draw_arrow(self, center + p, UnitSymbols.make_facing(v, HeadingFrame.make_heading(herc)), col, 0.8)
		else:
			UnitSymbols.draw_square(self, center + p, col, 0.75)
	UnitSymbols.draw_arrow(self, center, Vector2.UP, GREEN, 0.9)   # the viewer: heading up
	for nav in herc.get_tree().get_nodes_in_group("nav_points"):
		var p := make_radar_point(nav.global_position, r)
		if p.length() > r:
			p = p.normalized() * r
		draw_string(font, center + p - Vector2(4, -5), str(nav.get_meta("label", "N")), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, RadarColors.OTHER)

	var ex = herc.get_parent().get("extraction")
	if ex is ExtractionDirector:
		var marks := []
		for i in ex.zones.size():
			marks.append({"pos": ex.zones[i], "label": "EXFIL %s" % ExtractionTransports.make_zone_name(i), "color": RadarColors.OTHER})
		for m in ex.tasks.make_markers():
			marks.append({"pos": m.pos, "label": str(m.label), "color": RadarColors.OTHER})
		for m in marks:
			var p := make_radar_point(m.pos, r)
			if p.length() > r:
				p = p.normalized() * r
			UnitSymbols.draw_labeled_marker(self, center + p, str(m.label), m.color, font, 11)


## The target panel in `panel` (the TARGET_PANEL element, zone TARGET) and the box around the target in the world:
## name with its friend-or-foe word, range and health in its friend-or-foe colour (A5), then its model.
func _draw_target(panel: Rect2) -> void:
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
	if panel.size == Vector2.ZERO:
		return
	var title := "%s: %s" % [TargetInfo.make_iff_text(herc, t), TargetInfo.make_name(t)]
	draw_string(font, panel.position + Vector2(0, TARGET_TITLE_BASELINE), title, HORIZONTAL_ALIGNMENT_LEFT, panel.size.x, TARGET_FONT_SIZE, col)
	draw_string(font, panel.position + Vector2(0, TARGET_RANGE_BASELINE), "RANGE: %d m" % int(d), HORIZONTAL_ALIGNMENT_LEFT, -1, TARGET_FONT_SIZE, col)
	var bar := Rect2(panel.position + Vector2(0, TARGET_BAR_TOP), TARGET_BAR_SIZE)
	draw_rect(bar, col, false, 1.0)
	draw_rect(Rect2(bar.position + Vector2.ONE, Vector2((bar.size.x - 2.0) * TargetInfo.make_integrity(t), bar.size.y - 2.0)), col)
	if target_view.has_target():
		var view := Rect2(panel.position + Vector2(0, TARGET_VIEW_TOP), Vector2(TARGET_VIEW_SIZE))
		draw_texture(target_view.get_texture(), view.position)
		draw_rect(view, Color(AMBER, 0.5), false, 1.0)

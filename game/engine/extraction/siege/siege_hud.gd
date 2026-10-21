class_name SiegeHud
extends Control
## The siege's banner for the local player (every peer, from the host's state): the countdown to the Cybrids' arrival,
## then the wave number, the safe area and how far its wall is, the next exfil to close and the final stand. When the
## local player stands outside the safe area a red warning flashes.

const WARN_COLOR := Color(1.0, 0.3, 0.25)
const TEXT_COLOR := Color(1.0, 0.85, 0.8)
const DIM_COLOR := Color(1.0, 0.7, 0.6, 0.85)
const TITLE_SIZE := 30
const LINE_SIZE := 18
const WARNING_SIZE := 38
const TOP := 74.0
const LINE := 24.0
const FLASH_HZ := 2.5

var siege: CybridSiege
var font: Font


func _init(p_siege: CybridSiege) -> void:
	siege = p_siege
	name = "SiegeHud"
	ServerProfile.apply_client_only(self)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	size = get_viewport_rect().size
	queue_redraw()


## [[text, colour], ...] of the banner (empty before the warning); tests read it.
func make_lines() -> Array:
	var s := siege.state
	match int(s.get("phase", SiegePhase.ARMED)):
		SiegePhase.WARNING:
			return [["CYBRID SIEGE IN %s" % make_clock_text(float(s.get("t", 0.0))), WARN_COLOR]]
		SiegePhase.SIEGE:
			return _make_siege_lines(s)
		SiegePhase.ENDED:
			return [["THE BASIN IS LOST", WARN_COLOR]]
	return []


func _make_siege_lines(s: Dictionary) -> Array:
	var lines := [["CYBRID SIEGE   wave %d   %d Cybrids" % [int(s.get("wave", 0)), int(s.get("units", 0))], WARN_COLOR],
		["Safe area %d m wide%s   final stand in %s" % [int(float(s.get("r", 0.0)) * 2.0), _make_edge_text(s), make_clock_text(float(s.get("final_left", 0.0)))], TEXT_COLOR]]
	if float(s.get("next_close", -1.0)) >= 0.0:
		lines.append(["Next exfil closes in %s" % make_clock_text(float(s.next_close)), DIM_COLOR])
	elif int(s.get("last_zone", -1)) >= 0:
		lines.append(["Last exfil %s closes in %s" % [ExtractionTransports.make_zone_name(int(s.last_zone)), make_clock_text(float(s.get("last_left", 0.0)))], WARN_COLOR])
	return lines


## "   wall 410 m away" for the local player inside the circle, "" otherwise.
func _make_edge_text(s: Dictionary) -> String:
	var over := make_local_overshoot()
	return "" if over > 0.0 else "   wall %d m away" % int(-over)


## Metres the local player stands outside the circle (negative: inside by that much); 0 without a player.
func make_local_overshoot() -> float:
	var p := siege.director.battle.player
	if p == null or not is_instance_valid(p) or int(siege.state.get("phase", 0)) != SiegePhase.SIEGE:
		return 0.0
	var centre := Vector2(float(siege.state.get("cx", 0.0)), float(siege.state.get("cz", 0.0)))
	return Vector2(p.global_position.x, p.global_position.z).distance_to(centre) - float(siege.state.get("r", 0.0))


static func make_clock_text(seconds: float) -> String:
	return "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]


func _draw() -> void:
	var lines := make_lines()
	for i in lines.size():
		_draw_centered(str(lines[i][0]), TOP + LINE * i + (TITLE_SIZE if i > 0 else 0), TITLE_SIZE if i == 0 else LINE_SIZE, lines[i][1])
	if make_local_overshoot() > 0.0 and fmod(Time.get_ticks_msec() / 1000.0 * FLASH_HZ, 1.0) < 0.6:
		_draw_centered("OUTSIDE THE SAFE AREA", size.y * 0.3, WARNING_SIZE, WARN_COLOR)


func _draw_centered(text: String, y: float, font_size: int, color: Color) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string_outline(font, Vector2((size.x - w) * 0.5, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(0, 0, 0, 0.8))
	draw_string(font, Vector2((size.x - w) * 0.5, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

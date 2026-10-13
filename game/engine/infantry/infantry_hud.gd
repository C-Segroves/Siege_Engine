class_name InfantryHud
extends Control
## The soldier's instruments over the battle HUD: energy (jetpack and energy weapons), health, the weapon in
## hand with its ammunition, the kit (grenades, mines, repair kits, the pack and whether it is on), and the
## boarding hint of the OccupancyDirector ("E: enter the Raptor",
## "Light armor required", "E: get out of the Raptor") - the hint shows in vehicles too: in the cockpit's own
## message area while a cockpit / HUD shows (CockpitDisplay.hint), so it never covers that HUD's windows.

const ENERGY_COLOR := Color(0.35, 0.75, 1.0)
const HEALTH_COLOR := Color(0.35, 1.0, 0.45)
const LOW_COLOR := Color(1.0, 0.3, 0.25)
const TEXT_COLOR := Color(0.9, 1.0, 0.9)
const HINT_COLOR := Color(1.0, 0.85, 0.35)
const BAR_SIZE := Vector2(220, 12)
const BAR_GAP := 22.0
const MARGIN := 24.0
const FONT_SIZE := 16
const HINT_FONT_SIZE := 20
const HINT_RISE := 160.0
const LOW_FRACTION := 0.25

var director: OccupancyDirector
var font: Font
## The hint shown this frame (tests read it).
var hint := ""


func _init(p_director: OccupancyDirector) -> void:
	director = p_director
	name = "InfantryHud"


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	size = get_viewport_rect().size
	hint = director.make_local_hint() if director.battle.player else ""
	var cockpit := _live_cockpit()
	if cockpit:
		cockpit.hint = hint
	queue_redraw()


## The battle's cockpit display, if it exists (null for soldiers and vehicles on the plain HUD).
func _live_cockpit() -> CockpitDisplay:
	var overlay = director.battle.get("overlay")
	if overlay == null or not is_instance_valid(overlay.cockpit):
		return null
	return overlay.cockpit


## True when the hint is drawn here: no cockpit is showing it in its message area.
func is_drawing_hint() -> bool:
	var cockpit := _live_cockpit()
	return hint != "" and not (cockpit and cockpit.visible)


func _draw() -> void:
	var soldier := director.battle.player as Infantry
	if soldier and soldier.alive:
		_draw_soldier(soldier)
	if is_drawing_hint():
		var w := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, HINT_FONT_SIZE).x
		draw_string(font, Vector2((size.x - w) * 0.5, size.y - HINT_RISE), hint, HORIZONTAL_ALIGNMENT_LEFT, -1,
			HINT_FONT_SIZE, HINT_COLOR)


func _draw_soldier(soldier: Infantry) -> void:
	var origin := Vector2(size.x * 0.5 + MARGIN, size.y - MARGIN - BAR_GAP * 4.0)   # right of the HUD's weapon list
	_draw_bar(origin, "ENERGY", soldier.capacitor / maxf(soldier.capacitor_max, 1.0), ENERGY_COLOR)
	_draw_bar(origin + Vector2(0, BAR_GAP), "HEALTH", soldier.integrity, HEALTH_COLOR)
	var w := soldier.current_weapon()
	var text := "%s  %s" % [str(soldier.armor.get("name", "")), make_weapon_text(w)]
	draw_string(font, origin + Vector2(0, BAR_GAP * 2.0 + FONT_SIZE), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
	draw_string(font, origin + Vector2(0, BAR_GAP * 3.0 + FONT_SIZE), make_kit_text(soldier), HORIZONTAL_ALIGNMENT_LEFT,
		-1, FONT_SIZE - 2, TEXT_COLOR)


## The screen rects this HUD draws into on a window of size `s` (the chat panel's automatic placement avoids
## them): the soldier's bars and texts and the hint line.
static func make_occupied_rects(s: Vector2) -> Array:
	var origin := Vector2(s.x * 0.5 + MARGIN, s.y - MARGIN - BAR_GAP * 4.0)
	return [Rect2(origin - Vector2(8, 8), Vector2(BAR_SIZE.x + 160, BAR_GAP * 4.0 + MARGIN)),
		Rect2(s.x * 0.2, s.y - HINT_RISE - HINT_FONT_SIZE - 6, s.x * 0.6, HINT_FONT_SIZE + 14)]


## "Grenade 5  Mine 3  Repair Kit 1  Shield Pack ON".
static func make_kit_text(soldier: Infantry) -> String:
	var parts := []
	for id in soldier.kit.counts:
		parts.append("%s %d" % [InfantryGear.item(id).get("name", id), soldier.kit.count(id)])
	if soldier.kit.pack_id != "":
		var on := " ON" if soldier.kit.pack_active else ""
		parts.append("%s%s" % [InfantryGear.pack(soldier.kit.pack_id).get("name", soldier.kit.pack_id), on])
	return "  ".join(parts)


## "Disc Launcher 12/15", "Blaster" (energy) or "unarmed".
static func make_weapon_text(w: Weapon) -> String:
	if w == null:
		return "unarmed"
	return w.display_name if w.ammo_max < 0 else "%s %d/%d" % [w.display_name, w.ammo, w.ammo_max]


func _draw_bar(at: Vector2, label: String, fraction: float, color: Color) -> void:
	var f := clampf(fraction, 0.0, 1.0)
	var c := color if f > LOW_FRACTION else LOW_COLOR
	draw_rect(Rect2(at, BAR_SIZE), c, false, 1.5)
	draw_rect(Rect2(at + Vector2(2, 2), Vector2((BAR_SIZE.x - 4) * f, BAR_SIZE.y - 4)), c)
	draw_string(font, at + Vector2(BAR_SIZE.x + 8, BAR_SIZE.y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 4, c)

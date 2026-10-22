class_name InfantryHud
extends Control
## The soldier's instruments over the battle HUD: energy (jetpack and energy weapons), health, the weapon in
## hand with its ammunition, the kit (grenades, mines, repair kits, the pack and whether it is on, each with the key
## that uses it), the line that says what a pack or kit key just did (InfantryGearDirector.notice_text), and the
## boarding hint of the OccupancyDirector ("E: enter the Raptor",
## "Light armor required", "E: get out of the Raptor") - the hint shows in vehicles too: in the cockpit's own
## message area while a cockpit / HUD shows (CockpitDisplay.hint), so it never covers that HUD's windows.
## Every piece sits in the bottom-centre zone of HudLayout (soldier panel, notice, hint); the scope reticle and
## the heal wash are screen-wide effects of the layout's FULL zone.

const ENERGY_COLOR := Color(0.35, 0.75, 1.0)
const HEALTH_COLOR := Color(0.35, 1.0, 0.45)
const LOW_COLOR := Color(1.0, 0.3, 0.25)
const TEXT_COLOR := Color(0.9, 1.0, 0.9)
const HINT_COLOR := Color(1.0, 0.85, 0.35)
const BAR_SIZE := Vector2(220, 12)
const BAR_GAP := 22.0
const FONT_SIZE := 16
const HINT_FONT_SIZE := 20
const LOW_FRACTION := 0.25
const OK_COLOR := Color(0.45, 1.0, 0.55)
const WARN_COLOR := Color(1.0, 0.8, 0.3)
const NOTICE_FONT_SIZE := 22
const NOTICE_FADE_S := 0.5
const PANEL_WIDTH := 480.0
const NOTICE_HEIGHT := 28.0
const NOTICE_BASELINE := 22.0
const HINT_MAX_LINES := 2
## Panel rows: two bars, then the armour and weapon line and the kit line.
const PANEL_HEIGHT := BAR_GAP * 4.0 + 4.0
const HEAL_FLASH := Color(0.3, 1.0, 0.45, 0.14)
## Item kind -> the action that uses it; the pack's is PACK_ACTION.
const KIT_ACTIONS := {"grenade": "grenade_throw", "concussion": "grenade_throw", "mine": "mine_drop", "repair_kit": "repair_kit_use"}
const PACK_ACTION := "pack_use"
const SCOPE_COLOR := Color(1.0, 0.25, 0.25)
const SCOPE_CROSS_GAP := 8.0
const SCOPE_CROSS_REACH := 0.2   # of the window height
const SCOPE_TICKS := 4
const SCOPE_TICK_HALF := 4.0

var director: OccupancyDirector
var font: Font
## The hint shown this frame (tests read it).
var hint := ""


func _init(p_director: OccupancyDirector) -> void:
	director = p_director
	name = "InfantryHud"
	ServerProfile.apply_client_only(self)


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
	_declare_elements()
	queue_redraw()


## Tells the layout which instruments are up now and how big they are.
func _declare_elements() -> void:
	var layout := HudLayout.of(self)
	var soldier := director.battle.player as Infantry
	var alive := soldier != null and soldier.alive
	layout.declare(&"soldier_panel", Vector2(PANEL_WIDTH, PANEL_HEIGHT) if alive else Vector2.ZERO)
	layout.declare(&"notice_line", Vector2(PANEL_WIDTH, NOTICE_HEIGHT) if alive and _gear().is_notice_shown() else Vector2.ZERO)
	layout.declare(&"hint_lines", make_hint_size() if is_drawing_hint() else Vector2.ZERO)
	layout.declare(&"heal_flash", Vector2.ONE if alive and _heal_flash_left() > 0.0 else Vector2.ZERO)
	layout.declare(&"scope_overlay", Vector2.ONE if alive and _is_scope_up(soldier) else Vector2.ZERO)


## The hint's wrapped size, limited to the hint zone's largest.
func make_hint_size() -> Vector2:
	var most: Vector2 = HudLayout.ELEMENTS[&"hint_lines"].max
	var wrapped := font.get_multiline_string_size(hint, HORIZONTAL_ALIGNMENT_CENTER, PANEL_WIDTH, HINT_FONT_SIZE)
	return Vector2(PANEL_WIDTH, minf(wrapped.y, most.y))


func _is_scope_up(soldier: Infantry) -> bool:
	return soldier.scope.make_preview_rect(get_viewport_rect().size).size != Vector2.ZERO or is_scope_shown(director.battle, soldier)


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
	var layout := HudLayout.of(self)
	var soldier := director.battle.player as Infantry
	if soldier and soldier.alive:
		_draw_heal_flash(layout.rect_of(&"heal_flash"))
		_draw_soldier(soldier, layout.rect_of(&"soldier_panel"))
		_draw_scope(soldier, layout.rect_of(&"scope_overlay"))
		_draw_notice(layout.rect_of(&"notice_line"))
	if is_drawing_hint():
		var line := layout.rect_of(&"hint_lines")
		draw_multiline_string(font, line.position + Vector2(0, font.get_ascent(HINT_FONT_SIZE)), hint, HORIZONTAL_ALIGNMENT_CENTER,
			line.size.x, HINT_FONT_SIZE, HINT_MAX_LINES, HINT_COLOR)


func _heal_flash_left() -> float:
	return float(_gear().heal_flash_until_ms - Time.get_ticks_msec()) / 1000.0


## The green wash of a repair kit just used (it fades with the notice), over `screen`.
func _draw_heal_flash(screen: Rect2) -> void:
	var left := _heal_flash_left()
	if left > 0.0 and screen.has_area():
		var c := HEAL_FLASH
		c.a *= clampf(left / NOTICE_FADE_S, 0.0, 1.0)
		draw_rect(screen, c)


## "Shield Pack ON" or "No Repair Kit left": the answer to a pack_use / repair_kit_use press, centred in `line`.
func _draw_notice(line: Rect2) -> void:
	var gear := _gear()
	if not gear.is_notice_shown() or not line.has_area():
		return
	var left := float(gear.notice_until_ms - Time.get_ticks_msec()) / 1000.0
	var c := OK_COLOR if gear.notice_ok else WARN_COLOR
	c.a = clampf(left / NOTICE_FADE_S, 0.0, 1.0)
	var w := font.get_string_size(gear.notice_text, HORIZONTAL_ALIGNMENT_LEFT, -1, NOTICE_FONT_SIZE).x
	draw_string(font, line.position + Vector2((line.size.x - w) * 0.5, NOTICE_BASELINE), gear.notice_text, HORIZONTAL_ALIGNMENT_LEFT,
		line.size.x, NOTICE_FONT_SIZE, c)


func _gear() -> InfantryGearDirector:
	return director.battle.infantry.gear


func _draw_soldier(soldier: Infantry, panel: Rect2) -> void:
	var origin := panel.position
	_draw_bar(origin, "ENERGY", soldier.capacitor / maxf(soldier.capacitor_max, 1.0), ENERGY_COLOR)
	_draw_bar(origin + Vector2(0, BAR_GAP), "HEALTH", soldier.integrity, HEALTH_COLOR)
	var w := soldier.current_weapon()
	var text := "%s  %s" % [str(soldier.armor.get("name", "")), make_weapon_text(w)]
	draw_string(font, origin + Vector2(0, BAR_GAP * 2.0 + FONT_SIZE), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
	draw_string(font, origin + Vector2(0, BAR_GAP * 3.0 + FONT_SIZE), make_kit_text(soldier), HORIZONTAL_ALIGNMENT_LEFT,
		-1, FONT_SIZE - 2, TEXT_COLOR)


## True while the first-person view is the rifle scope's (zoomed and not in the chase view).
static func is_scope_shown(battle: Node, soldier: Infantry) -> bool:
	return soldier.scope.zoomed and RifleScope.is_scope_weapon(soldier.current_weapon()) and not battle.cameras.is_chasing()


## The Laser Rifle scope: the ZoomHud box of a magnification just stepped (not zoomed), or the zoomed view's reticle
## (a fine cross with range ticks at the aim point) and its magnification and range readout.
func _draw_scope(soldier: Infantry, screen: Rect2) -> void:
	if not screen.has_area():
		return
	var scope := soldier.scope
	var box := scope.make_preview_rect(screen.size)
	if box.size != Vector2.ZERO:
		draw_rect(box, RifleScope.PREVIEW_FILL)
		draw_rect(box, RifleScope.PREVIEW_BORDER, false, 1.0)
		return
	if not is_scope_shown(director.battle, soldier):
		return
	var cam: Camera3D = director.battle.cameras.cockpit_cam
	var c := screen.size * 0.5
	if is_instance_valid(cam):
		var p := soldier.aim_origin() + (-soldier.aim_basis().z) * RifleScope.REACH_M
		if not cam.is_position_behind(p):
			c = cam.unproject_position(p)
	var reach := size.y * SCOPE_CROSS_REACH
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		draw_line(c + d * SCOPE_CROSS_GAP, c + d * reach, SCOPE_COLOR, 1.5)
	for i in range(1, SCOPE_TICKS + 1):
		var at := SCOPE_CROSS_GAP + (reach - SCOPE_CROSS_GAP) * float(i) / float(SCOPE_TICKS + 1)
		for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
			var perp := Vector2(d.y, d.x)
			draw_line(c + d * at - perp * SCOPE_TICK_HALF, c + d * at + perp * SCOPE_TICK_HALF, SCOPE_COLOR, 1.0)
	draw_circle(c, 1.5, SCOPE_COLOR)
	var text := "ZOOM %dX  RANGE %d M" % [int(scope.magnification()), int(RifleScope.REACH_M)]
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	draw_string(font, Vector2(c.x - w * 0.5, c.y + reach + FONT_SIZE + 6.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, SCOPE_COLOR)


## The screen rects this HUD draws into on a window of size `s` (the chat panel's automatic placement avoids
## them): the soldier's bars and texts, the weapon list, the notice and the hint line at their largest.
static func make_occupied_rects(s: Vector2) -> Array:
	return HudLayout.make_reserved_rects(s, HudLayout.SOLDIER_HUD_IDS)


## "[G] Grenade 5  [B] Mine 3  [H] Repair Kit 1  [R] Shield Pack ON": each item with the key that uses it.
static func make_kit_text(soldier: Infantry) -> String:
	var parts := []
	for id in soldier.kit.counts:
		var record := InfantryGear.item(id)
		parts.append("%s%s %d" % [_make_key_prefix(KIT_ACTIONS.get(str(record.get("kind", "")), "")), record.get("name", id), soldier.kit.count(id)])
	if soldier.kit.pack_id != "":
		var on := " ON" if soldier.kit.pack_active else ""
		parts.append("%s%s%s" % [_make_key_prefix(PACK_ACTION), InfantryGear.pack(soldier.kit.pack_id).get("name", soldier.kit.pack_id), on])
	return "  ".join(parts)


## "[R] " for the first control bound to `action`, "" for none.
static func _make_key_prefix(action: String) -> String:
	if action == "" or not InputMap.has_action(action):
		return ""
	return "[%s] " % BindingText.make_action_bindings(action).get_slice(BindingText.SEPARATOR, 0)


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

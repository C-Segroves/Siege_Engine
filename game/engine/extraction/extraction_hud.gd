class_name ExtractionHud
extends Control
## The raid's instruments over the battle HUD (ExtractionDirector; every peer, for its local player):
##   top left    money, load (kg and slots), the exfil calls (zone, state, time, distance), the raid keys
##               (the raid_status element of HudLayout: it stacks in its own zone, clear of the target panel)
##   hint        "X: loot Supply cache (5)" when a container is within reach (InfantryHud's hint line)
##   world       markers on the caches near the player and on every extraction zone (they follow the world)
##   banner      EXTRACTED / KILLED IN ACTION when the local player's raid is over (the centre banner element)

const TEXT_COLOR := Color(0.9, 1.0, 0.9)
const DIM_COLOR := Color(0.7, 0.8, 0.7, 0.85)
const MONEY_COLOR := Color(1.0, 0.85, 0.35)
const ZONE_COLOR := Color(0.4, 1.0, 0.6)
const TASK_COLOR := Color(1.0, 0.95, 0.3)
const CACHE_COLOR := Color(1.0, 0.8, 0.3)
const CALLIN_COLOR := Color(1.0, 0.6, 0.25)
const CONTACT_COLOR := Color(1.0, 0.3, 0.3)
const BAG_COLOR := Color(1.0, 0.45, 0.3)
const BANNER_COLOR := Color(1.0, 0.85, 0.35)
const DEAD_COLOR := Color(1.0, 0.35, 0.3)
const LINE := 20.0
const BASELINE := 15.0
## Status lines that fit the raid_status element; the raid keys line always stays.
const MAX_STATUS_LINES := 9
const BANNER_ROW_PAD := 8.0
const FONT_SIZE := 16
const HINT_FONT_SIZE := 20
const BANNER_FONT_SIZE := 40
const MARKER_SIZE := 6.0
const CACHE_MARKER_RANGE := 90.0
const STATE_TEXTS := {"called": "inbound in", "flying": "transport on approach", "landed": "LANDED - board it",
	"open": "OPEN - hold inside", "departing": "lifting off", "closed": "CLOSED"}

var director: ExtractionDirector
var font: Font
## The loot hint of this frame (tests read it); the interact hint line of InfantryHud draws it (the nearest interact
## offer, ExtractionDirector.make_loot_offer).
var hint := ""


func _init(p_director: ExtractionDirector) -> void:
	director = p_director
	name = "ExtractionHud"
	ServerProfile.apply_client_only(self)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	size = get_viewport_rect().size
	hint = make_pickup_hint()
	_declare_elements()
	queue_redraw()


## Tells the layout how big the status block and the banner are now.
func _declare_elements() -> void:
	var layout := HudLayout.of(self)
	var lines := make_status_lines()
	var widest := 0.0
	for line in lines:
		widest = maxf(widest, font.get_string_size(str(line[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x)
	layout.declare(&"raid_status", Vector2(widest, LINE * lines.size()) if not lines.is_empty() else Vector2.ZERO)
	layout.declare(&"centre_banner", make_banner_size())


func _local_soldier() -> Infantry:
	return director.battle.player as Infantry


## "E: loot Supply cache (5 items)" for the container within reach of the local soldier ("" when none).
func make_pickup_hint() -> String:
	var s := _local_soldier()
	if s == null or not s.alive or s.stowed or director.my_status != ExtractionDirector.STATUS_IN_RAID:
		return ""
	var c := director.find_container_near(s.global_position)
	if c == null:
		return ""
	return "%s: %s
%s%s" % [InfantryInteraction.make_key_text(), make_loot_text(c), director.my_inventory.make_capacity_text(),
		make_unfit_text(c)]


## "  -  will not fit: Chaingun, Ammo" (the container's items that no longer fit this inventory); "" when all fit.
func make_unfit_text(c: LootContainer) -> String:
	var names := []
	for st in c.stacks:
		if director.my_inventory.is_full_for(str(st[0])):
			names.append(ExtractionItems.make_name(str(st[0])))
	return "" if names.is_empty() else "  -  will not fit: %s" % ", ".join(names)


## "loot Supply cache (5 items, $120)".
static func make_loot_text(c: LootContainer) -> String:
	var money := ", %s" % ExtractionRules.make_money_text(c.money) if c.money > 0 else ""
	return "loot %s (%d items%s)" % [c.make_title(), c.make_item_count(), money]


func _draw() -> void:
	_draw_markers()
	var block := HudLayout.of(self).rect_of(&"raid_status")
	var at := block.position + Vector2(0, BASELINE)
	for line in make_status_lines():
		draw_string(font, at, str(line[0]), HORIZONTAL_ALIGNMENT_LEFT, block.size.x, FONT_SIZE, line[1])
		at.y += LINE
	_draw_banner(HudLayout.of(self).rect_of(&"centre_banner"))


## [[text, colour], ...] for the top-left block, at most MAX_STATUS_LINES (the call-in lines give way first).
func make_status_lines() -> Array:
	var inv := director.my_inventory
	var lines := [["RAID   %s   load %.1f / %.0f kg   slots %d / %d" % [ExtractionRules.make_money_text(inv.money),
		inv.make_used_kg(), inv.max_kg, inv.make_used_slots(), inv.max_slots], MONEY_COLOR]]
	for e in director.exfil_states:
		lines.append([make_exfil_text(e), ZONE_COLOR])
	for text in director.callins.make_hud_lines():
		lines.append([text, CALLIN_COLOR])
	if director.my_status == ExtractionDirector.STATUS_IN_RAID:
		lines.append(["%s loot   %s inventory   %s call exfil   %s call-ins" % [InfantryInteraction.make_key_text(),
			OccupancyHint.make_key_text("inventory_toggle"), OccupancyHint.make_key_text("exfil_call"),
			OccupancyHint.make_key_text("callin_menu")], DIM_COLOR])
	return _make_trimmed(lines)


## `lines` cut to MAX_STATUS_LINES by dropping the lines just before the last (the raid keys).
static func _make_trimmed(lines: Array) -> Array:
	while lines.size() > MAX_STATUS_LINES:
		lines.remove_at(lines.size() - 2)
	return lines


## "Exfil B: LANDED - board it 0:31  (240 m)".
func make_exfil_text(e: Dictionary) -> String:
	var zone := int(e.get("zone", 0))
	var text := "Exfil %s: %s" % [ExtractionTransports.make_zone_name(zone), STATE_TEXTS.get(str(e.state), str(e.state))]
	if str(e.state) in ["called", "landed", "open"]:
		text += " %d:%02d" % [int(e.seconds) / 60, int(e.seconds) % 60]
	var s := director.battle.player
	if s and zone < director.zones.size():
		text += "  (%d m)" % int(s.global_position.distance_to(director.zones[zone]))
	return text


## [[text, font size, colour], ...] of the banner when the raid is over: EXTRACTED / KILLED IN ACTION, what was kept, what was lost.
func make_banner_lines() -> Array:
	match director.my_status:
		ExtractionDirector.STATUS_EXTRACTED:
			return [["EXTRACTED - your haul is in your stash", BANNER_FONT_SIZE, BANNER_COLOR]]
		ExtractionDirector.STATUS_DEAD:
			return _make_dead_lines()
	return []


func _make_dead_lines() -> Array:
	var lines := [["KILLED IN ACTION - your gear is lost", BANNER_FONT_SIZE, DEAD_COLOR]]
	if not director.my_kept.is_empty():
		lines.append(["Insured and kept: %s" % ExtractionItems.make_stack_text(str(director.my_kept[0][0]), int(director.my_kept[0][1])),
			HINT_FONT_SIZE, BANNER_COLOR])
	if not director.my_lost.is_empty():
		lines.append(["Lost with you: %s  (buy back %d cr each)" % [", ".join(PackedStringArray(director.my_lost.map(RaidOperator.make_unlock_text))),
			EconomyRules.rebuy_price()], HINT_FONT_SIZE, DEAD_COLOR])
	return lines


## The banner's size: its widest line (limited to the zone) and a row per line.
func make_banner_size() -> Vector2:
	var lines := make_banner_lines()
	var most: Vector2 = HudLayout.ELEMENTS[&"centre_banner"].max
	var size_now := Vector2.ZERO
	for line in lines:
		size_now.x = maxf(size_now.x, font.get_string_size(str(line[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, int(line[1])).x)
		size_now.y += int(line[1]) + BANNER_ROW_PAD
	return Vector2(minf(size_now.x, most.x), minf(size_now.y, most.y))


func _draw_banner(banner: Rect2) -> void:
	var y := banner.position.y
	for line in make_banner_lines():
		y += int(line[1]) + BANNER_ROW_PAD * 0.5
		_draw_centered(str(line[0]), banner, y, int(line[1]), line[2])
		y += BANNER_ROW_PAD * 0.5


func _draw_centered(text: String, banner: Rect2, y: float, font_size: int, color: Color) -> void:
	var w := minf(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x, banner.size.x)
	var at := Vector2(banner.position.x + (banner.size.x - w) * 0.5, y)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, banner.size.x, font_size, 4, Color(0, 0, 0, 0.8))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, banner.size.x, font_size, color)


func _draw_markers() -> void:
	var cam := get_viewport().get_camera_3d()
	var s := director.battle.player
	if cam == null or s == null:
		return
	for i in director.zones.size():
		var closed := director.is_zone_closed(i)
		_draw_marker(cam, director.zones[i] + Vector3.UP * 2.0, "EXFIL %s%s" % [ExtractionTransports.make_zone_name(i), " CLOSED" if closed else ""], CONTACT_COLOR if closed else ZONE_COLOR, s)
	for m in director.tasks.make_markers():
		_draw_marker(cam, m.pos + Vector3.UP * 3.0, "TASK: %s" % str(m.label).to_upper(), TASK_COLOR, s)
	for m in director.callins.make_markers():
		_draw_marker(cam, m.pos + Vector3.UP * 3.0, str(m.label), CONTACT_COLOR if bool(m.contact) else CALLIN_COLOR, s)
	for c in director.containers.values():
		var lc := c as LootContainer
		if lc.position.distance_to(s.global_position) < CACHE_MARKER_RANGE:
			_draw_marker(cam, lc.position + Vector3.UP * 1.2, lc.make_title(), BAG_COLOR if lc.kind == "bag" else CACHE_COLOR, s)


func _draw_marker(cam: Camera3D, p: Vector3, label: String, color: Color, s: Herc) -> void:
	if cam.is_position_behind(p):
		return
	var at := cam.unproject_position(p)
	draw_rect(Rect2(at - Vector2.ONE * MARKER_SIZE * 0.5, Vector2.ONE * MARKER_SIZE), color, false, 2.0)
	var text := "%s %d m" % [label, int(p.distance_to(s.global_position))]
	draw_string(font, at + Vector2(MARKER_SIZE, -MARKER_SIZE), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 3, color)

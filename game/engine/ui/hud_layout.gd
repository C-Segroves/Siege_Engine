class_name HudLayout
extends RefCounted
## Where every piece of the shared overlay HUD goes (docs/CODING_STANDARDS.md section 3). The screen is split into
## ZONES (anchored regions, fractions of the screen so they scale with the canvas); each HUD element is a row of
## ELEMENTS (its zone, its place in the zone's stack and its largest size) and declares its current size every
## frame (`declare`); the layout stacks the declared elements of a zone along the zone's edge, so two elements
## can never overlap and an element never places itself at fixed coordinates:
##
##   top left      raid status (money, load, exfil calls, call-ins, raid keys)
##   target        the target panel (name, range, health bar, target view), under the top-left stack
##   top centre    compass, torso twist / horizon, newest message, siege banner
##   centre        the big centre banners (EXTRACTED, DOWNED, reviving, outside the safe area)
##   top right     radar, then the objectives panel
##   bottom left   throttle, speed and flight readouts (vehicles)
##   bottom right  armour and shields (vehicles)
##   bottom centre soldier bars, weapon list, pack / kit notice, interact / boarding hint (stacks upwards)
##   full          screen-wide effects (scope reticle, heal flash, downed veil): backdrops, never stacked
##
## Not placed here, by design: the crosshair and world markers (they follow the world), the cockpit painters of
## each game (their own 320x200 art), and the modal panels (inventory, call-in menu, station shop, battle menu).
## The chat panel and the missile cam window float: they search for a spot clear of `make_rects`.

enum Zone { TOP_LEFT, TARGET, TOP_CENTRE, CENTRE, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT, BOTTOM_CENTRE, FULL }

const MARGIN := 16.0
const GAP := 6.0
const META_KEY := &"hud_layout"
## A declaration older than this many frames is forgotten (the element stopped declaring: it is hidden).
const STALE_FRAMES := 2
## Zone rects as fractions of the screen: [left, top, right, bottom]; a left / top of -1 is MARGIN pixels.
const ZONE_FRACTIONS := {
	Zone.TOP_LEFT: [-1.0, -1.0, 0.30, 0.29],
	Zone.TARGET: [-1.0, 0.30, 0.30, 0.595],
	Zone.TOP_CENTRE: [0.31, -1.0, 0.69, 0.35],
	Zone.CENTRE: [0.31, 0.36, 0.69, 0.515],
	Zone.TOP_RIGHT: [0.70, -1.0, -1.0, 0.595],
	Zone.BOTTOM_LEFT: [-1.0, 0.60, 0.30, -1.0],
	Zone.BOTTOM_RIGHT: [0.70, 0.60, -1.0, -1.0],
	Zone.BOTTOM_CENTRE: [0.31, 0.52, 0.69, -1.0],
}
const ALIGN_LEFT := [Zone.TOP_LEFT, Zone.TARGET, Zone.BOTTOM_LEFT]
const ALIGN_RIGHT := [Zone.TOP_RIGHT, Zone.BOTTOM_RIGHT]
const STACK_UP := [Zone.BOTTOM_LEFT, Zone.BOTTOM_RIGHT, Zone.BOTTOM_CENTRE]

## id -> {zone, order (stack position from the zone's anchor edge), max (the largest size it ever declares), group
## (optional: of the elements of one group only the first by order shows; they are alternatives, such as the
## centre banners)}.
const ELEMENTS := {
	&"raid_status": {"zone": Zone.TOP_LEFT, "order": 0, "max": Vector2(364, 180)},
	&"target_panel": {"zone": Zone.TARGET, "order": 0, "max": Vector2(172, 174)},
	&"compass": {"zone": Zone.TOP_CENTRE, "order": 0, "max": Vector2(370, 24)},
	&"torso_bar": {"zone": Zone.TOP_CENTRE, "order": 1, "max": Vector2(240, 48)},
	&"message_line": {"zone": Zone.TOP_CENTRE, "order": 2, "max": Vector2(480, 26)},
	&"siege_banner": {"zone": Zone.TOP_CENTRE, "order": 3, "max": Vector2(480, 116)},
	&"centre_banner": {"zone": Zone.CENTRE, "order": 0, "group": &"centre", "max": Vector2(640, 108)},
	&"revive_banner": {"zone": Zone.CENTRE, "order": 1, "group": &"centre", "max": Vector2(460, 96)},
	&"siege_warning": {"zone": Zone.CENTRE, "order": 2, "group": &"centre", "max": Vector2(480, 46)},
	&"radar": {"zone": Zone.TOP_RIGHT, "order": 0, "max": Vector2(220, 220)},
	&"objectives": {"zone": Zone.TOP_RIGHT, "order": 1, "max": Vector2(320, 170)},
	&"throttle_block": {"zone": Zone.BOTTOM_LEFT, "order": 0, "max": Vector2(250, 242)},
	&"armour_block": {"zone": Zone.BOTTOM_RIGHT, "order": 0, "max": Vector2(96, 204)},
	&"soldier_panel": {"zone": Zone.BOTTOM_CENTRE, "order": 0, "max": Vector2(480, 92)},
	&"weapon_list": {"zone": Zone.BOTTOM_CENTRE, "order": 1, "max": Vector2(360, 94)},
	&"notice_line": {"zone": Zone.BOTTOM_CENTRE, "order": 2, "max": Vector2(480, 28)},
	&"hint_lines": {"zone": Zone.BOTTOM_CENTRE, "order": 3, "max": Vector2(480, 52)},
	&"scope_overlay": {"zone": Zone.FULL, "order": 0, "max": Vector2.ZERO},
	&"heal_flash": {"zone": Zone.FULL, "order": 1, "max": Vector2.ZERO},
	&"downed_veil": {"zone": Zone.FULL, "order": 2, "max": Vector2.ZERO},
}

## The elements of the plain HUD (HUD and InfantryHud), for the static reserved rects of floating panels.
const PLAIN_HUD_IDS := [&"target_panel", &"compass", &"torso_bar", &"message_line", &"radar", &"throttle_block",
	&"armour_block", &"soldier_panel", &"weapon_list", &"notice_line", &"hint_lines"]
## The bottom-centre part of it (the soldier's).
const SOLDIER_HUD_IDS := [&"soldier_panel", &"weapon_list", &"notice_line", &"hint_lines"]

## The screen the zones are cut from (canvas units).
var screen := Vector2(1280, 720)
var _declared := {}     # id -> {"size": Vector2, "frame": int}


## The layout of `node`'s viewport (one per window; created on first use); its screen follows the viewport.
static func of(node: Node) -> HudLayout:
	var viewport := node.get_viewport()
	if not viewport.has_meta(META_KEY):
		viewport.set_meta(META_KEY, HudLayout.new())
	var layout: HudLayout = viewport.get_meta(META_KEY)
	layout.screen = viewport.get_visible_rect().size
	return layout


## The zone's rect on a screen of size `s`.
static func make_zone_rect(zone: Zone, s: Vector2) -> Rect2:
	if zone == Zone.FULL:
		return Rect2(Vector2.ZERO, s)
	var f: Array = ZONE_FRACTIONS[zone]
	var left := MARGIN if float(f[0]) < 0.0 else float(f[0]) * s.x
	var top := MARGIN if float(f[1]) < 0.0 else float(f[1]) * s.y
	var right := s.x - MARGIN if float(f[2]) < 0.0 else float(f[2]) * s.x
	var bottom := s.y - MARGIN if float(f[3]) < 0.0 else float(f[3]) * s.y
	return Rect2(left, top, right - left, bottom - top)


## Shows element `id` at `size` this frame (a ZERO size: nothing to show).
func declare(id: StringName, size: Vector2) -> void:
	if not ELEMENTS.has(id):
		push_error("HudLayout.declare: unknown element '%s'" % id)
		return
	_declared[id] = {"size": size, "frame": Engine.get_process_frames()}


## Stops showing `id` now.
func withdraw(id: StringName) -> void:
	_declared.erase(id)


## True while `id` has a size declared recently.
func is_shown(id: StringName) -> bool:
	return make_rects().has(id)


func _is_declared(id: StringName) -> bool:
	return _declared.has(id) and _is_live(_declared[id]) and (_declared[id].size as Vector2) != Vector2.ZERO


## The screen rect of element `id` (an empty Rect2 when it is not shown): its declared size, stacked in its zone.
func rect_of(id: StringName) -> Rect2:
	return make_rects().get(id, Rect2())


## id -> screen rect of every shown element. A zone-filling element (FULL) gets the whole screen.
func make_rects() -> Dictionary:
	var out := {}
	for zone in Zone.values():
		out.merge(_make_zone_rects(zone))
	return out


## The rects of every shown element but the screen-wide effects (what floating panels keep clear of).
func make_occupied_rects() -> Array:
	var out := []
	var rects := make_rects()
	for id in rects:
		if ELEMENTS[id].zone != Zone.FULL:
			out.append(rects[id])
	return out


func _is_live(entry: Dictionary) -> bool:
	return Engine.get_process_frames() - int(entry.frame) <= STALE_FRAMES


func _make_zone_rects(zone: Zone) -> Dictionary:
	var out := {}
	var ids := []
	for id in ELEMENTS:
		if ELEMENTS[id].zone == zone and _is_declared(id):
			ids.append(id)
	ids.sort_custom(func(a, b): return int(ELEMENTS[a].order) < int(ELEMENTS[b].order))
	ids = _make_group_winners(ids)
	if zone == Zone.FULL:
		for id in ids:
			out[id] = Rect2(Vector2.ZERO, screen)
		return out
	var area := make_zone_rect(zone, screen)
	var up := STACK_UP.has(zone)
	var cursor := area.end.y if up else area.position.y
	for id in ids:
		var sz := _make_fitted_size(_declared[id].size, area)
		var y := cursor - sz.y if up else cursor
		out[id] = Rect2(Vector2(_make_aligned_x(zone, area, sz.x), y), sz)
		cursor = y - GAP if up else y + sz.y + GAP
	return out


## `ids` (sorted by order) without the elements that lose to an earlier one of their group.
static func _make_group_winners(ids: Array) -> Array:
	var groups := {}
	var out := []
	for id in ids:
		var group = ELEMENTS[id].get("group", null)
		if group != null:
			if groups.has(group):
				continue
			groups[group] = true
		out.append(id)
	return out


## `want` limited to the zone's width.
static func _make_fitted_size(want: Vector2, area: Rect2) -> Vector2:
	return Vector2(minf(want.x, area.size.x), want.y)


static func _make_aligned_x(zone: Zone, area: Rect2, width: float) -> float:
	if ALIGN_LEFT.has(zone):
		return area.position.x
	if ALIGN_RIGHT.has(zone):
		return area.end.x - width
	return area.position.x + (area.size.x - width) * 0.5


## A layout on a screen of size `s` with every element in `ids` (all stacked elements when empty) declared at its
## largest size: what a screen could ever show.
static func make_reserved(s: Vector2, ids := []) -> HudLayout:
	var layout := HudLayout.new()
	layout.screen = s
	for id in (ids if not ids.is_empty() else ELEMENTS.keys()):
		layout.declare(id, ELEMENTS[id].max)
	return layout


## The screen rects the elements `ids` reserve on a screen of size `s` (static counterpart of make_occupied_rects).
static func make_reserved_rects(s: Vector2, ids: Array) -> Array:
	return make_reserved(s, ids).make_occupied_rects()

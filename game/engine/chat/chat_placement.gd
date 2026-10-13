class_name ChatPlacement
## Where the chat panel goes on the screen (ChatSettings.position): a corner, the player's own dragged spot, or
## "auto": the first spot clear of every window of the HUD in use (the cockpit's instruments and its own message
## window, the plain HUD's meters, the soldier's bars: `occupied`, screen rects), searched from the bottom-left
## corner upwards and then rightwards, like the free message band of CockpitMessageArea.make_free_rect; when
## no spot fits the panel's width, narrower panels are tried down to AUTO_MIN_WIDTH (the Earthsiege panel
## cockpits leave only the side windows free).

const MARGIN := 16.0
const SEARCH_STEP := 16.0
const AUTO_MIN_WIDTH := 240.0
const WIDTH_STEP := 20.0


## The panel's screen rect for preset `position` (ChatSettings.PRESETS); only "auto" may narrow it.
static func make_rect(position: String, panel_size: Vector2, screen: Vector2, occupied: Array,
		custom_pos := Vector2.ZERO) -> Rect2:
	if position == ChatSettings.AUTO:
		return make_free_rect(occupied, panel_size, screen)
	return Rect2(make_position(position, panel_size, screen, occupied, custom_pos), panel_size)


## The first spot (searched like make_free_position) where a panel at least AUTO_MIN_WIDTH wide is clear of
## `occupied`, with the widest panel that fits there (up to `panel_size`); the full-size panel in the
## bottom-left corner when no spot is clear.
static func make_free_rect(occupied: Array, panel_size: Vector2, screen: Vector2) -> Rect2:
	var narrowest := Vector2(minf(AUTO_MIN_WIDTH, panel_size.x), panel_size.y)
	var x := MARGIN
	while x + narrowest.x <= screen.x - MARGIN:
		var y := screen.y - panel_size.y - MARGIN
		while y >= MARGIN:
			if is_clear(Rect2(Vector2(x, y), narrowest), occupied):
				return Rect2(Vector2(x, y), _make_widest(occupied, Vector2(x, y), panel_size, screen))
			y -= SEARCH_STEP
		x += SEARCH_STEP
	return Rect2(Vector2(MARGIN, screen.y - panel_size.y - MARGIN), panel_size)


## The widest panel size (panel_size.x down to AUTO_MIN_WIDTH, on the screen) clear of `occupied` at `at`.
static func _make_widest(occupied: Array, at: Vector2, panel_size: Vector2, screen: Vector2) -> Vector2:
	var w := minf(panel_size.x, screen.x - MARGIN - at.x)
	while w > AUTO_MIN_WIDTH and not is_clear(Rect2(at, Vector2(w, panel_size.y)), occupied):
		w -= WIDTH_STEP
	return Vector2(maxf(w, minf(AUTO_MIN_WIDTH, panel_size.x)), panel_size.y)


## The panel's top-left corner for preset `position` (ChatSettings.PRESETS).
static func make_position(position: String, panel_size: Vector2, screen: Vector2, occupied: Array,
		custom_pos := Vector2.ZERO) -> Vector2:
	match position:
		"top_left":
			return Vector2(MARGIN, MARGIN)
		"top_right":
			return Vector2(screen.x - panel_size.x - MARGIN, MARGIN)
		"bottom_left":
			return Vector2(MARGIN, screen.y - panel_size.y - MARGIN)
		"bottom_right":
			return screen - panel_size - Vector2(MARGIN, MARGIN)
		ChatSettings.CUSTOM:
			return make_clamped(custom_pos * screen, panel_size, screen)
	return make_free_position(occupied, panel_size, screen)


## The first spot for a panel of `panel_size` clear of every rect of `occupied`, from the bottom-left corner up,
## column by column to the right; the bottom-left corner when no spot is clear.
static func make_free_position(occupied: Array, panel_size: Vector2, screen: Vector2) -> Vector2:
	var x := MARGIN
	while x + panel_size.x <= screen.x - MARGIN:
		var y := screen.y - panel_size.y - MARGIN
		while y >= MARGIN:
			if is_clear(Rect2(Vector2(x, y), panel_size), occupied):
				return Vector2(x, y)
			y -= SEARCH_STEP
		x += SEARCH_STEP
	return Vector2(MARGIN, screen.y - panel_size.y - MARGIN)


static func is_clear(r: Rect2, occupied: Array) -> bool:
	for o in occupied:
		if r.intersects(o as Rect2):
			return false
	return true


## `pos` moved so a panel of `panel_size` stays on a screen of size `screen`.
static func make_clamped(pos: Vector2, panel_size: Vector2, screen: Vector2) -> Vector2:
	return Vector2(clampf(pos.x, 0.0, maxf(screen.x - panel_size.x, 0.0)), clampf(pos.y, 0.0, maxf(screen.y - panel_size.y, 0.0)))


## Canvas rects (a cockpit's virtual canvas `canvas_size`, stretched over the window) as screen rects.
static func make_screen_rects(rects: Array, canvas_size: Vector2, screen: Vector2) -> Array:
	var k := screen / canvas_size
	return rects.map(func(r: Rect2) -> Rect2: return Rect2(r.position * k, r.size * k))

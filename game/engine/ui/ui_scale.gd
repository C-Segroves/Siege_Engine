class_name UiScale
extends RefCounted
## The global UI scale (playtest: "when I go full screen I can hardly read what things are"). Every 2D screen and HUD
## is laid out for a BASE_SIZE canvas: the root window stretches it (canvas_items, aspect expand) to the real window,
## so a 1920x1080 or 2560x1440 window shows the same UI, larger. The Options > Display "UI scale" multiplies on top
## (Auto = 100%, 75-200%). 3D is never scaled; cockpit art keeps its own 320x200 scaling inside the canvas.

const KEY := "ui_scale"
const AUTO := 0
const PERCENTS := [75, 100, 125, 150, 175, 200]
const BASE_SIZE := Vector2i(1280, 720)


## Stored percent: AUTO (0) or one of PERCENTS.
static func percent() -> int:
	var p := int(Assets.settings.get(KEY, AUTO))
	return p if p == AUTO else clampi(p, int(PERCENTS[0]), int(PERCENTS[-1]))


static func apply_percent(p: int) -> void:
	Assets.settings[KEY] = p
	Assets.save_settings()
	apply(Engine.get_main_loop().root)


## Content scale factor for stored percent `p` (Auto = 1.0).
static func make_factor(p: int) -> float:
	return 1.0 if p == AUTO else float(p) / 100.0


## Sets `window`'s stretch to the base canvas and the stored factor.
static func apply(window: Window) -> void:
	window.content_scale_size = BASE_SIZE
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	window.content_scale_factor = make_factor(percent())


## The UI scale on screen: real pixels per canvas unit of `window`.
static func make_on_screen_scale(window: Window) -> float:
	return minf(float(window.size.x) / BASE_SIZE.x, float(window.size.y) / BASE_SIZE.y) * window.content_scale_factor

class_name DisplaySettings
## Remake display settings, kept in user://settings.json (Assets.settings): "CRT gamma" for the original 8-bit
## screens (Earthsiege shell, cockpit overlays), whether the mission objectives panel and the missile camera
## window show.
##
## The original palettes are 6-bit VGA DAC values. A 1990s CRT showed them brighter in the mid
## tones than an sRGB LCD shows the same values, so the remake lifts palette colours by
## c^(1 / gamma) before display. 1.0 = raw DAC values (exact); the default 1.2 is slightly brighter.
## Not an original setting: the original had no brightness control (docs/formats/shell.md section 1).

const GAMMA_KEY := "crt_gamma"
const DEFAULT_GAMMA := 1.2
const MIN_GAMMA := 1.0
const MAX_GAMMA := 2.0
## The in-battle mission objectives panel (ObjectivesPanel; objectives_toggle switches it too).
const OBJECTIVES_KEY := "objectives_panel"
## The remake's missile camera window (MissileCamWindow; missile_cam_toggle switches it too). The Earthsiege
## cockpits' own MISSILE CAM page (MFD F6) is always there.
const MISSILE_CAM_KEY := "missile_cam_window"


static func objectives_panel_on() -> bool:
	return bool(Assets.settings.get(OBJECTIVES_KEY, true))


static func apply_objectives_panel(on: bool) -> void:
	Assets.settings[OBJECTIVES_KEY] = on
	Assets.save_settings()


static func missile_cam_window_on() -> bool:
	return bool(Assets.settings.get(MISSILE_CAM_KEY, true))


static func apply_missile_cam_window(on: bool) -> void:
	Assets.settings[MISSILE_CAM_KEY] = on
	Assets.save_settings()


static func crt_gamma() -> float:
	return clampf(float(Assets.settings.get(GAMMA_KEY, DEFAULT_GAMMA)), MIN_GAMMA, MAX_GAMMA)


## Stores the gamma; screens that use make_corrected() pick it up on their next palette update.
static func apply_crt_gamma(value: float) -> void:
	Assets.settings[GAMMA_KEY] = clampf(value, MIN_GAMMA, MAX_GAMMA)
	Assets.save_settings()


## `c` (a palette colour) as shown with CRT gamma `gamma`; alpha unchanged.
static func make_corrected(c: Color, gamma: float) -> Color:
	var e := 1.0 / gamma
	return Color(pow(c.r, e), pow(c.g, e), pow(c.b, e), c.a)


## `img` with CRT gamma `gamma` applied to its RGB channels (8-bit lookup table); alpha unchanged.
## Returns `img` itself when gamma is 1.0 (raw DAC values).
static func make_corrected_image(img: Image, gamma: float) -> Image:
	if img == null or is_equal_approx(gamma, MIN_GAMMA):
		return img
	var out := img.duplicate() as Image
	out.convert(Image.FORMAT_RGBA8)
	var lut := PackedByteArray()
	lut.resize(256)
	for v in 256:
		lut[v] = int(round(pow(v / 255.0, 1.0 / gamma) * 255.0))
	var data := out.get_data()
	for i in range(0, data.size(), 4):
		data[i] = lut[data[i]]
		data[i + 1] = lut[data[i + 1]]
		data[i + 2] = lut[data[i + 2]]
	out.set_data(out.get_width(), out.get_height(), false, Image.FORMAT_RGBA8, data)
	return out

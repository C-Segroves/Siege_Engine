class_name ChatSettings
## The chat panel's settings, kept in user://settings.json (Assets.settings, key "chat"; the options screen and
## the panel's own move / resize write them):
##   visible_lines   lines shown while the chat is closed (the newest, fading out)
##   history_lines   lines of history shown while it is open (typing, quick chat, U)
##   fade_seconds    seconds a line stays before it fades (0 = never)
##   width           panel width in pixels
##   opacity         background opacity 0..1
##   font_size       text size in pixels
##   position        PRESETS: "auto" (clear of the HUD's windows, ChatPlacement), corners, or "custom"
##   custom_pos      [x, y] share of the window of the panel's top-left corner ("custom")
##   timestamps      show "HH:MM" before each line
##   filters         channel -> shown (ChatChannels)

const KEY := "chat"
const AUTO := "auto"
const CUSTOM := "custom"
const PRESETS := [AUTO, "top_left", "top_right", "bottom_left", "bottom_right", CUSTOM]
const PRESET_NAMES := {AUTO: "Auto (clear of the HUD)", "top_left": "Top left", "top_right": "Top right",
	"bottom_left": "Bottom left", "bottom_right": "Bottom right", CUSTOM: "Custom (dragged)"}
const LIMITS := {
	"visible_lines": Vector2(1, 20), "history_lines": Vector2(4, 40), "fade_seconds": Vector2(0, 120),
	"width": Vector2(200, 1200), "opacity": Vector2(0, 1), "font_size": Vector2(10, 32),
}


static func make_defaults() -> Dictionary:
	var filters := {}
	for c in ChatChannels.ORDER:
		filters[c] = true
	return {"visible_lines": 6, "history_lines": 14, "fade_seconds": 12.0, "width": 440.0, "opacity": 0.55,
		"font_size": 15, "position": AUTO, "custom_pos": [0.02, 0.6], "timestamps": false, "filters": filters}


## The saved settings over the defaults, each number within LIMITS.
static func load_settings() -> Dictionary:
	var out := make_defaults()
	var saved = Assets.settings.get(KEY, {})
	if not (saved is Dictionary):
		push_error("ChatSettings: ignoring unreadable settings")
		return out
	for k in out:
		if saved.has(k) and _is_compatible(saved[k], out[k]):
			out[k] = saved[k]
	out.filters = make_defaults().filters.merged(out.filters, true)
	if not PRESETS.has(str(out.position)):
		out.position = AUTO
	return make_clamped(out)


## `s` with every limited number inside LIMITS (whole numbers stay whole).
static func make_clamped(s: Dictionary) -> Dictionary:
	var out := s.duplicate(true)
	for k in LIMITS:
		var lim: Vector2 = LIMITS[k]
		var v := clampf(float(out[k]), lim.x, lim.y)
		out[k] = int(v) if make_defaults()[k] is int else v
	return out


static func save_settings(s: Dictionary) -> void:
	Assets.settings[KEY] = make_clamped(s)
	Assets.save_settings()


## Changes one setting and saves.
static func apply_value(key: String, value: Variant) -> void:
	var s := load_settings()
	s[key] = value
	save_settings(s)


## Shows or hides a channel and saves.
static func apply_filter(channel: String, shown: bool) -> void:
	var s := load_settings()
	s.filters[channel] = shown
	save_settings(s)


static func reset() -> void:
	save_settings(make_defaults())


## True when a saved value may replace default `d` (same type; JSON turns every number into a float).
static func _is_compatible(v: Variant, d: Variant) -> bool:
	return typeof(v) == typeof(d) or (_is_number(v) and _is_number(d))


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT

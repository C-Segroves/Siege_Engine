class_name CockpitSkin
extends RefCounted
## Which art a game's cockpit instruments use: bitmap arrays and frame numbers, fonts, palette colours
## and STRINGS0 label groups (docs/formats/cockpit.md sections 3 and 8). The defaults are Earthsiege 1's
## (DBSIM addresses in docs/formats/cockpit.md section 3); a pack overrides them in cockpit/skin.json
## (Earthsiege 2: written by tools/export_es2_cockpit.py). A frame or colour of -1 means "not drawn".

const DEFAULTS := {
	"buttons": {"dba": "PBUTTONS"},
	"weapons": {
		"dba": "PBUTTONS", "led_selected": 57, "led_ready": 55, "led_charging": 56, "led_destroyed": -1,
		"frame_selected": -1, "frame_idle": -1, "font": "CPGREEN", "font_selected": "CPYLW",
		"bar_marker": 26, "bar_ready": 55, "bar_charging": 53, "value_font": "CPGREEN", "value_font_empty": "CPRED",
		"ecm_button": 6, "ecm_font": "CPRED",
	},
	"indicators": {"lamp_count": 3, "button_off": 6, "button_on": 7, "font_on": "CPYLW", "font_off": "CPBLUE",
		"button_font_on": "CPPRESS", "button_font_off": "CPON"},
	"engine_bar": {"source": "engine", "colors": []},
	"shields": {"color_ok": 55, "color_low": 53, "lamp_on": 55, "lamp_off": 54},
	"throttle": {"dba": "PBUTTONS", "bar_color": 55, "reverse_color": 59},
	"message": {"font": "CPGREEN"},
	"hud": {
		"tape_dba": "HUDHTICK", "dba": "", "torso_track": -1, "torso_marker": -1, "torso_marker_centred": -1,
		"torso_centred_units": 0, "reticle": [], "reticle_lock_px": 0, "target_pipper": [], "target_corner": [],
		"text_font": "CPBLACK", "nav_font": "CPBLACK", "marker_color": 59, "text_color": 59,
	},
	"mfd": {
		"dba": "PBUTTONS", "mode_off": 10, "mode_on": 11, "mode_step": 2, "mode_labels": false,
		"range_step_button": 7, "range_down_button": 11, "range_up_button": 12,
		"page_frames": [], "option_buttons": [], "option_frames": {}, "option_font": "CPON",
		"title_font": "CPRED", "page_font": "CPGREEN", "label_font": "CPRED",
		"lock_font": "CPYLW", "radar_dba": "RADAR", "radar_frames": 1, "radar_fps": 0.0, "radar_origin": [0, 0],
		"radar_centre": [34, 22], "radar_radius": 22.0,
		"radar_colors": {"friend": 56, "enemy": 53, "target": 59, "target_blink": 60, "nav": 50},
		"status_picture": [1, 1, 24, 43], "diagram_offset": [0, 0], "status_text_x": 26,
		"status_rows": [0, 8, 17, 25, 35], "own_rows": [0, 8, 20, 27, 35],
	},
	"hdd": {
		"dba": "PBUTTONS", "page_off": 22, "page_on": 23, "page_step": 2, "arrows": [], "button6": 51, "button7": 53,
		"zoom_in_button": 6, "zoom_out_button": 7,
		"icons": {"dba": "ICONS", "nav_first": 0, "self": 18, "friend": 27, "enemy": 9, "target": 36,
			"octant_offsets": [1, 2, 3, 4, 5, 6, 7, 8], "anchor": [8, 4]},
		"font": "CPGREEN", "title_font": "CPGREEN", "title_label": "hdd_pages", "grid_color": 54, "led_color": 56,
	},
	"damage": {"colors": [], "shades": 3},
	"strings": {"indicators": 4, "mfd": 5, "own_status": 9, "hdd_pages": 10, "damage_titles": 11,
		"components": 12, "no_target": 16, "no_info": 16, "target": 17, "status": 18, "target_status": 24,
		"range": 26, "missile": 31, "ecm": 3},
	"string_items": {"no_target": 0, "no_info": 1, "target": 0},
}

var _data: Dictionary


func _init(overrides: Dictionary = {}) -> void:
	_data = _make_merged(DEFAULTS, overrides)


## The skin of `pack` (DEFAULTS when the pack has no cockpit/skin.json).
static func load_for(pack: String) -> CockpitSkin:
	var j = Assets.load_json("cockpit/skin.json", pack)
	return CockpitSkin.new(j if j is Dictionary else {})


static func _make_merged(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in over:
		if out.get(k) is Dictionary and over[k] is Dictionary:
			out[k] = _make_merged(out[k], over[k])
		else:
			out[k] = over[k]
	return out


## Value `key` of instrument `section` (`fallback` when absent).
func value(section: String, key: String, fallback: Variant = null) -> Variant:
	var s = _data.get(section)
	return s.get(key, fallback) if s is Dictionary else fallback


func frame(section: String, key: String) -> int:
	return int(value(section, key, -1))


func font(section: String, key: String) -> String:
	return str(value(section, key, ""))


## Bitmap array (DBA name) of instrument `section`.
func dba(section: String) -> String:
	return str(value(section, "dba", ""))


func list(section: String, key: String) -> Array:
	var v = value(section, key, [])
	return v if v is Array else []


## STRINGS0 group of label set `name` (-1: the game has none).
func group(name: String) -> int:
	return int(_data.strings.get(name, -1))


## Item of label set `name` inside its group.
func item(name: String) -> int:
	return int(_data.string_items.get(name, 0))

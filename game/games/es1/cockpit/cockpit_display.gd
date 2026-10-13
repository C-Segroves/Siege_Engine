class_name CockpitDisplay
extends Control
## Original 3Space cockpit instruments of Earthsiege 1 and 2 (docs/formats/cockpit.md), drawn on the
## layout's virtual canvas (Earthsiege 1 320x200, Earthsiege 2 320x240) stretched over the window (same
## mapping as the 3D cockpit camera).
##
## Data: gamedata/<pack>/cockpit/ (tools/export_cockpit.py, tools/export_es2_cockpit.py):
## layout/<HERC>.json (GAU rects; the look-down panel below the front view at canvas.look_down_top),
## panels/, dba/ (instrument bitmaps), fonts/, pdg/ (damage diagrams), pilots/, strings0.json, the
## optional palette per Herc and skin.json (which art the instruments use, CockpitSkin).
## Painters: CockpitHud, CockpitWeapons, CockpitGauges, CockpitShields, CockpitMfd, CockpitHdd on a
## CockpitCanvas.
##
## Actions: cockpit_mode_1..6 (F1..F6) MFD pages (SCANNER again = radar range; F1-F4 are the squad keys in a
## game that has them, SquadKeys: Starsiege), cockpit_mode_next,
## hdd_page_1 / hdd_page_2 (F7 / F8) map / damage, look_down / look_up (PgDn / PgUp, keypad 2 / 8), Earthsiege 2
## look_left / look_right (keypad 4 / 6; CockpitSideView).
## ui_click while the mouse is free (menu_pause): MFD / HDD buttons are clickable.
## Test flags: --mfd=<0..5> --hdd=<0|1> --lookdown --autotarget

const DEFAULT_CANVAS := Vector2(320, 200)
const DEFAULT_LOOK_DOWN_TOP := 200.0
const MAX_MESSAGES := 6
const DEFAULT_RADAR_RANGE := 2
const DEFAULT_MAP_ZOOM := 2
const DEFAULT_BRIGHTNESS := 75
const BRIGHTNESS_STEP := 25
const MIN_BRIGHTNESS := 25
const MAX_BRIGHTNESS := 100
const ENGINE_IDLE := 0.55           # engine bar at zero throttle
const ENGINE_THROTTLE_SHARE := 0.45
const ENGINE_FLICKER := 0.04
const ENGINE_FOLLOW_RATE := 3.0
const AUTOTARGET_DELAY := 1.0
## A long standing hint scrolls once through a one-line message window in this time.
const HINT_SCROLL_SECONDS := 8.0
const MODE_ACTIONS := ["cockpit_mode_1", "cockpit_mode_2", "cockpit_mode_3", "cockpit_mode_4", "cockpit_mode_5", "cockpit_mode_6"]

var herc: Herc
var battle: Node
var cam: Camera3D
var pack := "es1"
var cockpit_name := ""
## Why this cockpit (CockpitFit.make_choice: rule, pack, layout, reason).
var choice := {}
var layout: Dictionary
var gauges: Dictionary              # layout.gauges
## The layout's pixel space and where the look-down panel starts in it.
var canvas_size := DEFAULT_CANVAS
var panel_top := DEFAULT_LOOK_DOWN_TOP

var mfd_mode := CockpitMfd.MODE_SCANNER
var radar_range_i := DEFAULT_RADAR_RANGE
var look_down := false
## Earthsiege 2 side views (look_left / look_right).
var side_view: CockpitSideView
var hdd_page := CockpitHdd.PAGE_MAP
var map_zoom := DEFAULT_MAP_ZOOM
var brightness := DEFAULT_BRIGHTNESS
var messages: Array = []            # [text, time_left, total]
## The standing hint of the remake (the OccupancyDirector's "E: get out of the ..."), shown in the message area
## below the timed messages while it is set ("" = none).
var hint := ""
var clock := 0.0
var time := 0.0
var engine_level := 1.0

## The player's missile camera (MissileCam) for the MFD MISSILE CAM page; null: the page shows its text only.
var missile_cam: MissileCam
## Unit picture of the STATUS / TARGET pages (original art, or another game's unit in 3D).
var target_image: CockpitTargetImage

var _canvas: CockpitCanvas
var _skin: CockpitSkin
var _art_scale := 1.0
var _painters: Array = []           # front view, in drawing order after the HUD
var _hud: CockpitHud
var _gauges: CockpitGauges
var _hdd: CockpitHdd
var _meters: CockpitMeters          # HUD meters (Starsiege, Battledrome, Tribes); null for panel cockpits


## The cockpit of Herc `h` in battle `b` (its own or the best-fitting one, CockpitFit), or null when it gets
## the plain HUD.
static func create(h: Herc, b: Node) -> CockpitDisplay:
	if h == null or h.def.is_empty() or h is Infantry:
		return null
	var fit := CockpitFit.make_choice(h.def)
	if str(fit.layout) == "":
		return null
	var j = Assets.load_json("cockpit/layout/%s.json" % fit.layout, fit.pack)
	if typeof(j) != TYPE_DICTIONARY:
		push_error("CockpitDisplay: layout %s:%s unreadable" % [fit.pack, fit.layout])
		return null
	var c := CockpitDisplay.new()
	c.herc = h
	c.battle = b
	c.pack = fit.pack
	c.cockpit_name = fit.layout
	c.choice = fit
	c._apply_layout(j)
	c._build_painters()
	c._adopt_hud_messages()
	return c


func _apply_layout(j: Dictionary) -> void:
	layout = j
	gauges = j.get("gauges", {})
	var cv: Dictionary = j.get("canvas", {})
	var sz: Array = cv.get("size", [DEFAULT_CANVAS.x, DEFAULT_CANVAS.y])
	canvas_size = Vector2(float(sz[0]), float(sz[1]))
	panel_top = float(cv.get("look_down_top", DEFAULT_LOOK_DOWN_TOP))
	_art_scale = float(cv.get("art_scale", 1.0))
	side_view = CockpitSideView.new(j, pack)


func _build_painters() -> void:
	_skin = CockpitSkin.load_for(pack)
	_canvas = CockpitCanvas.new(self, CockpitAssets.new(pack, _skin, str(layout.get("palette", "palette.json"))))
	_hud = CockpitHud.new(self, _canvas)
	_gauges = CockpitGauges.new(self, _canvas)
	_hdd = CockpitHdd.new(self, _canvas)
	_painters = [CockpitWeapons.new(self, _canvas), _gauges, CockpitShields.new(self, _canvas), CockpitMfd.new(self, _canvas)]
	if layout.has("meters"):
		_meters = CockpitMeters.new(self, _canvas)
		_painters.append(_meters)
	target_image = CockpitTargetImage.new(_canvas, pack)
	add_child(target_image.view)


## Keeps messages that were posted to the placeholder HUD before the cockpit existed.
func _adopt_hud_messages() -> void:
	var hud = battle.get("hud") if battle else null
	if hud and "messages" in hud:
		for m in hud.messages:
			show_message(str(m[0]), float(m[1]))


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for a in OS.get_cmdline_user_args():
		_apply_test_flag(a)


func _apply_test_flag(a: String) -> void:
	if a.begins_with("--mfd="):
		mfd_mode = clampi(int(a.substr(6)), 0, CockpitMfd.MODE_COUNT - 1)
	elif a.begins_with("--hdd="):
		hdd_page = clampi(int(a.substr(6)), 0, 1)
	elif a == "--lookdown":
		look_down = true
	elif a == "--autotarget":
		get_tree().create_timer(AUTOTARGET_DELAY).timeout.connect(_apply_autotarget)


func _apply_autotarget() -> void:
	var best: Herc = null
	for v in _hud.vehicles():
		if v != herc and v.alive and v.team != herc.team:
			if best == null or herc.global_position.distance_to(v.global_position) < herc.global_position.distance_to(best.global_position):
				best = v
	herc.target = best


## The cockpit camera; a frustum camera gets its projection centre on the HUD centre row (the original's
## 3D centre = HUD centre, DBSIM 0x55bc2; Earthsiege 2 per Herc).
func set_camera(c: Camera3D) -> void:
	cam = c
	var h: Dictionary = gauges.get("hud", {})
	if c != null and c.projection == Camera3D.PROJECTION_FRUSTUM and h.has("center"):
		BattleCameras.apply_centre_row(c, float(h.center[1]), canvas_size.y)


func show_message(text: String, seconds := 4.0) -> void:
	messages.append([text.to_upper(), seconds, seconds])
	if messages.size() > MAX_MESSAGES:
		messages.pop_front()


## Texts of the message area, oldest first: the live messages, then the standing hint.
func make_message_texts() -> PackedStringArray:
	var out := PackedStringArray()
	for m in messages:
		out.append(str(m[0]))
	if hint != "":
		out.append(hint.to_upper())
	return out


## What a one-line message window shows: the newest message, else the standing hint ([] when neither), as
## [text, seconds_left, seconds_total] (the hint repeats every HINT_SCROLL_SECONDS).
func make_newest_entry() -> Array:
	if not messages.is_empty():
		return messages[messages.size() - 1]
	if hint == "":
		return []
	return [hint.to_upper(), HINT_SCROLL_SECONDS - fmod(time, HINT_SCROLL_SECONDS), HINT_SCROLL_SECONDS]


## Lines the message area shows: a HUD's message window may hold several, the panel cockpit's message line one.
func make_message_line_count() -> int:
	return _meters.make_message_line_count() if _meters else 1


## Where the messages show on the canvas in the front view: the HUD's message window, else the panel
## cockpit's message line.
func make_message_rect() -> Rect2:
	return _meters.make_message_rect() if _meters else _gauges.make_message_rect(false)


## The canvas rects of the HUD's other windows (none for a panel cockpit: its message line is part of the panel).
func make_window_rects() -> Array:
	return _meters.make_window_rects() if _meters else []


## True when this cockpit shows a compass with the waypoint: the Earthsiege heading tape or a HUD compass meter.
func has_compass() -> bool:
	return _meters.has_compass() if _meters else gauges.get("hud", {}).has("heading_tape")


## The crosshair on the canvas: the HUD centre, which set_camera makes the 3D view's projection centre (the HUD
## reticle meters are drawn around it); the canvas centre without a HUD.
func make_crosshair_point() -> Vector2:
	var c: Array = gauges.get("hud", {}).get("center", [canvas_size.x * 0.5, canvas_size.y * 0.5])
	return Vector2(float(c[0]), float(c[1]))


## World point -> virtual canvas point (null when behind the cockpit camera).
func make_virtual_point(p: Vector3) -> Variant:
	if cam == null or cam.is_position_behind(p):
		return null
	return cam.unproject_position(p) / get_viewport_rect().size * canvas_size


# ------------------------------------------------------------------ update

func _process(delta: float) -> void:
	time += delta
	clock += delta
	position = Vector2.ZERO
	size = get_viewport_rect().size
	_age_messages(delta)
	var on := herc != null and is_instance_valid(herc) and herc.alive and cam != null and cam.current
	visible = on
	_apply_hud_visibility(not on)
	if herc and is_instance_valid(herc):
		_apply_engine_level(delta)
	apply_pictures(on, delta)
	if on and side_view.is_available():
		side_view.apply_camera(cam, canvas_size.x, size.x / maxf(size.y, 1.0))
	if on:
		queue_redraw()


## Keeps the 3D unit pictures (MFD target page, HUD damage meters) on their vehicles while the cockpit shows.
func apply_pictures(on: bool, delta: float) -> void:
	target_image.follow(_shown_target() if on else null, delta)
	if _meters:
		_meters.follow(on, delta)


## The target whose picture the MFD shows now (only on the TARGET page).
func _shown_target() -> Node:
	return herc.target if mfd_mode == CockpitMfd.MODE_TARGET and not look_down and not side_view.is_side() else null


func _age_messages(delta: float) -> void:
	for m in messages:
		m[1] -= delta
	messages = messages.filter(func(m): return m[1] > 0.0)


## The placeholder HUD shows whenever the cockpit does not.
func _apply_hud_visibility(hud_on: bool) -> void:
	var hud = battle.get("hud") if battle else null
	if hud:
		hud.visible = hud_on


## Engine output follows the throttle with a little flicker.
func _apply_engine_level(delta: float) -> void:
	var want := clampf(ENGINE_IDLE + ENGINE_THROTTLE_SHARE * absf(herc.throttle) + randf_range(-ENGINE_FLICKER, ENGINE_FLICKER), 0.0, 1.0)
	engine_level = lerpf(engine_level, want, clampf(delta * ENGINE_FOLLOW_RATE, 0.0, 1.0))


# ------------------------------------------------------------------ input

func _input(event: InputEvent) -> void:
	if not visible or ChatFocus.open:
		return
	if _apply_action(event):
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.is_action_pressed("ui_click") \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not side_view.is_side():
		if apply_click(_make_layout_point(event.position)):
			get_viewport().set_input_as_handled()


## Cockpit key actions; true when `event` was one.
func _apply_action(event: InputEvent) -> bool:
	if side_view.apply_action(event, look_down):
		return true
	for i in MODE_ACTIONS.size():
		if event.is_action_pressed(MODE_ACTIONS[i]) and not SquadKeys.owns(battle, MODE_ACTIONS[i]):
			side_view.apply_front()   # the MFD keys bring the front view back (ES2 0x432ceb)
			apply_mode(i)
			return true
	if event.is_action_pressed("cockpit_mode_next"):
		apply_mode((mfd_mode + 1) % CockpitMfd.MODE_COUNT)
	elif event.is_action_pressed("hdd_page_1"):
		hdd_page = CockpitHdd.PAGE_MAP
	elif event.is_action_pressed("hdd_page_2"):
		hdd_page = CockpitHdd.PAGE_DAMAGE
	elif event.is_action_pressed("look_down") and side_view.is_side():
		side_view.apply_front()   # out of a side view to the front first (ES2 request 6, 0x432ddf)
	elif event.is_action_pressed("look_down") and not is_hud_only():
		look_down = true
	elif event.is_action_pressed("look_up"):
		look_down = false
		side_view.apply_front()
	else:
		return false
	return true


func _make_layout_point(window_pos: Vector2) -> Vector2:
	var v: Vector2 = window_pos / get_viewport_rect().size * canvas_size
	if look_down:
		v.y += panel_top
	return v


## Selects MFD page `m`; selecting SCANNER again steps the radar range.
func apply_mode(m: int) -> void:
	if m == CockpitMfd.MODE_SCANNER and mfd_mode == CockpitMfd.MODE_SCANNER:
		_step_radar_range()
	mfd_mode = m


func _step_radar_range() -> void:
	radar_range_i = (radar_range_i + 1) % CockpitMfd.RADAR_RANGES.size()


## Presses the cockpit button under layout point `v`; true when there was one.
func apply_click(v: Vector2) -> bool:
	return _click_mfd(v) or _click_brightness(v) or _click_hdd(v)


func _click_mfd(v: Vector2) -> bool:
	var mb: Array = gauges.get("mfd", {}).get("buttons", [])
	for i in mb.size():
		if not CockpitCanvas.rect_of(mb[i]).has_point(v):
			continue
		if i < CockpitMfd.MODE_COUNT:
			apply_mode(i)
		elif i == _skin.frame("mfd", "range_step_button") and mfd_mode == CockpitMfd.MODE_SCANNER:
			_step_radar_range()
		elif i == _skin.frame("mfd", "range_down_button"):
			radar_range_i = maxi(radar_range_i - 1, 0)
		elif i == _skin.frame("mfd", "range_up_button"):
			radar_range_i = mini(radar_range_i + 1, CockpitMfd.RADAR_RANGES.size() - 1)
		return true
	return false


func _click_brightness(v: Vector2) -> bool:
	var b: Dictionary = gauges.get("brightness", {})
	if b.has("button_up") and CockpitCanvas.rect_of(b.button_up).has_point(v):
		brightness = mini(brightness + BRIGHTNESS_STEP, MAX_BRIGHTNESS)
		return true
	if b.has("button_down") and CockpitCanvas.rect_of(b.button_down).has_point(v):
		brightness = maxi(brightness - BRIGHTNESS_STEP, MIN_BRIGHTNESS)
		return true
	return false


func _click_hdd(v: Vector2) -> bool:
	var hb: Array = gauges.get("hdd", {}).get("buttons", [])
	for i in hb.size():
		if not CockpitCanvas.rect_of(hb[i]).has_point(v):
			continue
		if i == CockpitHdd.PAGE_MAP or i == CockpitHdd.PAGE_DAMAGE:
			hdd_page = i
		elif i == _skin.frame("hdd", "zoom_in_button"):
			map_zoom = mini(map_zoom + 1, CockpitHdd.MAP_RANGES.size() - 1)
		elif i == _skin.frame("hdd", "zoom_out_button"):
			map_zoom = maxi(map_zoom - 1, 0)
		return true
	return false


# ------------------------------------------------------------------ drawing

## A HUD drawn over the whole view (Starsiege, Battledrome, Tribes): meters, no panel art, no look-down panel.
func is_hud_only() -> bool:
	return layout.has("meters") and not layout.has("panels")


## The panel art of `view` ("front" / "look_down" / "side"); null for a HUD without panel art (layout "meters").
func _panel(view: String) -> Texture2D:
	if is_hud_only():
		return null
	return _canvas.assets.texture(str(layout.get("panels", {}).get(view, "panels/%s_DB%d.png" % [cockpit_name, 0 if view == "front" else 1])), _art_scale)


func _draw() -> void:
	if herc == null or not is_instance_valid(herc):
		return
	var vscale := size / canvas_size
	if look_down:
		draw_set_transform(Vector2(0, -panel_top * vscale.y), 0.0, vscale)
		_canvas.blit(_panel("look_down"), 0, panel_top)
		_hdd.draw()
		_gauges.draw_message(true)
		return
	draw_set_transform(Vector2.ZERO, 0.0, vscale)
	if side_view.is_side():
		side_view.draw(self, _canvas, _panel("side"), size, vscale)   # the gauges scrolled off with the front panel
		return
	_hud.draw()
	_canvas.blit(_panel("front"), 0, 0)
	for p in _painters:
		p.draw()
	if not is_hud_only():
		_gauges.draw_message(false)   # a HUD's messages are in its own message window (CockpitMeters)

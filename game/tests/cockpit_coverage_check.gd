extends Node3D
## Every pilotable vehicle gets a working cockpit (docs/formats/cockpit.md section 9, CockpitFit):
##   1. it resolves a cockpit skin, native or best fit, and the rule that chose it (no plain HUD while its game's
##      cockpit data is installed);
##   2. its instruments follow the vehicle's state (speed, shields, energy, damage, target);
##   3. the cockpit camera sits at a sensible eye point (inside the vehicle's bounds, in its upper part) with the
##      projection centre on the HUD's centre row (BattleCameras.apply_centre_row);
##   4. it starts in its cockpit view (Herc.prefers_chase_view: no chase view when a cockpit layout resolved);
##   5. the remake's overlay messages and standing hint show in the cockpit's own message area (the hint on its
##      own, and in a multi-line window below a long message), which overlaps
##      none of the HUD's windows, and draw nothing outside it (CockpitMessageArea); a HUD without a message area
##      would get a free band clear of every window;
##   6. the chat panel at its default settings and automatic place (ChatPlacement, CockpitOccupancy) overlaps none
##      of the cockpit's windows (nor the plain HUD's meters).
## Saves contact sheets of all cockpits to renders/cockpit_coverage_<n>.png. Needs a window (rendering):
##   godot --audio-driver Dummy --path game res://tests/cockpit_coverage_check.tscn [-- --only=<pack,...>]
##         [--sheets=<dir>] [--shots=<dir>] (full-size frames too)

const TARGET_ID := "es1:APOLLO"
const TARGET_DISTANCE := 60.0       # metres ahead of the vehicle
const SETTLE_FRAMES := 4
## A state change must change at least this many window pixels of the cockpit (instruments moved).
const MIN_CHANGED_PIXELS := 40
## Eye point: within the vehicle's mesh bounds grown by this share sideways, and in their upper part.
const EYE_SIDE_MARGIN := 0.25
const EYE_MIN_HEIGHT := 0.3
const EYE_MAX_HEIGHT := 1.25
const THUMB := Vector2i(400, 250)
const SHEET_COLUMNS := 3
const SHEET_ROWS := 3
const LABEL_HEIGHT := 14
const LABEL_FONT_SIZE := 11
## Share of every component's health the busy state takes away.
const DAMAGE_SHARE := 0.6
const GROUND_SIZE := 4000.0
const SKY := Color(0.55, 0.65, 0.8)
const GROUND := Color(0.45, 0.4, 0.3)
const LONG_MESSAGE := "You are piloting: a test vehicle (with a weapon list far too long for any message window of any game)"
const HINT := "E / Space: get out of the test vehicle (pilot seat)   F: next seat"
const MESSAGE_SECONDS := 30.0
## Share of its lifetime the long message has left when shot.
const MESSAGE_AGE := 0.7
## Window pixels a message may touch around its window rect (scaled-glyph rounding).
const MESSAGE_RECT_SLACK := 1.0
const FREE_BAND_HEIGHT := 20.0

var _failures := 0
var _layer: CanvasLayer
var _thumbs: Array = []             # [label, ImageTexture]
var _rows: Array = []               # [id, rule, pack:layout, reason]
var _shots_dir := ""


func _ready() -> void:
	_build_world()
	_layer = CanvasLayer.new()
	add_child(_layer)
	var only := []
	var sheets := ProjectSettings.globalize_path("res://").path_join("../renders")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = Array(a.substr(7).split(","))
		elif a.begins_with("--sheets="):
			sheets = a.substr(9)
		elif a.begins_with("--shots="):
			_shots_dir = a.substr(8)
			DirAccess.make_dir_recursive_absolute(_shots_dir)
	var target := _spawn(TARGET_ID, Vector3(0, 0, -TARGET_DISTANCE))
	for v in Packs.pilotable(only):
		await _check_vehicle(v, target)
	target.queue_free()
	_print_table()
	await _save_sheets(sheets)
	print("cockpit_coverage_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
		_failures += 1


func _build_world() -> void:
	SceneLighting.add_studio_environment(self, {"background": SKY, "ambient_energy": 0.6})
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.4, 0.0)
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(GROUND_SIZE, GROUND_SIZE)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GROUND
	plane.material = mat
	ground.mesh = plane
	add_child(ground)


func _spawn(id: String, at: Vector3) -> Herc:
	var h: Herc = Flyer.new() if Packs.vehicle(id).get("flyer", false) else Herc.new()
	h.vehicle_id = id
	h.position = at
	h.team = 1 if at != Vector3.ZERO else 0
	add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _settle() -> void:
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw


func _shot() -> Image:
	await _settle()
	return get_viewport().get_texture().get_image()


# ------------------------------------------------------------------ one vehicle

func _check_vehicle(v: Dictionary, target: Herc) -> void:
	var id := str(v.id)
	var choice := CockpitFit.make_choice(v)
	_rows.append([id, choice.rule, "%s:%s" % [choice.pack, choice.layout] if choice.layout != "" else "-", choice.reason])
	var cockpit_data := DirAccess.dir_exists_absolute(Assets.path("cockpit", str(v.pack)))
	_expect(choice.rule != CockpitFit.RULE_PLAIN or not cockpit_data, "%s: resolves a cockpit (%s)" % [id, choice.reason])
	var host := _spawn(id, Vector3.ZERO)
	if host is Flyer:
		host.position.y = 30.0
	var cams := BattleCameras.new()
	cams.build_cockpit_camera(host)
	cams.cockpit_cam.current = true
	await _settle()
	_check_eye(host, cams.cockpit_cam, id)
	if str(choice.layout) != "":
		_expect(not host.prefers_chase_view(), "%s: starts in its cockpit view" % id)
	var ui := _build_ui(host, cams.cockpit_cam, choice)
	if ui is CockpitDisplay:
		_check_centre_row(ui as CockpitDisplay, cams.cockpit_cam, id)
	await _check_instruments(ui, host, target, id)
	if ui is CockpitDisplay:
		await _check_messages(ui as CockpitDisplay, id)
	_check_chat_place(ui, id)
	ui.queue_free()
	cams.release_cockpit_camera(host)
	host.queue_free()
	await _settle()


## The cockpit the battle would show (BattleOverlay.build_cockpit): the original instruments, else the plain HUD.
func _build_ui(host: Herc, cam: Camera3D, choice: Dictionary) -> Control:
	var cockpit := CockpitDisplay.create(host, self)
	if cockpit != null:
		_expect(cockpit.choice.layout == choice.layout, "%s: the display shows the chosen cockpit" % host.vehicle_id)
		_layer.add_child(cockpit)
		cockpit.set_camera(cam)
		cockpit.set_process(false)
		cockpit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		return cockpit
	var hud := HUD.new()
	hud.herc = host
	hud.camera = cam
	_layer.add_child(hud)
	return hud


func _check_eye(host: Herc, cam: Camera3D, id: String) -> void:
	var bounds := _make_mesh_bounds(host)
	var eye := cam.global_position
	var grow := bounds.size * EYE_SIDE_MARGIN
	var inside := eye.x >= bounds.position.x - grow.x and eye.x <= bounds.end.x + grow.x \
		and eye.z >= bounds.position.z - grow.z and eye.z <= bounds.end.z + grow.z
	var rise := (eye.y - bounds.position.y) / maxf(bounds.size.y, 0.01)
	_expect(inside and rise >= EYE_MIN_HEIGHT and rise <= EYE_MAX_HEIGHT,
		"%s: eye point in the vehicle's upper part (height %.2f of %.1f m, eye %s, bounds %s)" % [id, rise, bounds.size.y, eye, bounds])


static func _make_mesh_bounds(host: Herc) -> AABB:
	var out := AABB()
	var first := true
	for mi in host.shape.find_children("*", "MeshInstance3D", true, false):
		if not mi.is_visible_in_tree() or mi.mesh == null:
			continue
		var bb: AABB = mi.global_transform * mi.mesh.get_aabb()
		out = bb if first else out.merge(bb)
		first = false
	return out


func _check_centre_row(cockpit: CockpitDisplay, cam: Camera3D, id: String) -> void:
	var h: Dictionary = cockpit.gauges.get("hud", {})
	if not h.has("center"):
		_expect(false, "%s: layout has a HUD centre" % id)
		return
	var probe := Camera3D.new()
	probe.size = cam.size
	BattleCameras.apply_centre_row(probe, float(h.center[1]), cockpit.canvas_size.y)
	_expect(is_equal_approx(cam.frustum_offset.y, probe.frustum_offset.y), "%s: view centre on the HUD centre row" % id)
	probe.free()


## Two states of the vehicle must draw differently, and the cockpit view must not be empty.
func _check_instruments(ui: Control, host: Herc, target: Herc, id: String) -> void:
	_apply_state(host, null, 0.0)
	ui.queue_redraw()
	var idle := await _shot()
	_apply_state(host, target, 1.0)
	if ui is CockpitDisplay:
		(ui as CockpitDisplay).apply_pictures(true, 1.0)
		await _settle()
	ui.queue_redraw()
	var busy := await _shot()
	var changed := _count_changed(idle, busy)
	_expect(changed >= MIN_CHANGED_PIXELS, "%s: instruments follow the state (%d px changed)" % [id, changed])
	if _shots_dir != "":
		busy.save_png(_shots_dir.path_join(id.replace(":", "_") + ".png"))
	var thumb := busy.duplicate()
	thumb.resize(THUMB.x, THUMB.y, Image.INTERPOLATE_BILINEAR)
	_thumbs.append(["%s  ->  %s  (%s)" % [id, _rows[-1][2], _rows[-1][1]], ImageTexture.create_from_image(thumb)])


## The chat panel's default place on this window is clear of every window of the cockpit (or the plain HUD).
func _check_chat_place(ui: Control, id: String) -> void:
	var screen := get_viewport().get_visible_rect().size
	var occupied: Array = HUD.make_occupied_rects(screen)
	if ui is CockpitDisplay:
		var cockpit := ui as CockpitDisplay
		occupied = ChatPlacement.make_screen_rects(CockpitOccupancy.make_rects(cockpit), cockpit.canvas_size, screen)
	var r := ChatPlacement.make_free_rect(occupied, ChatPanel.make_closed_size(ChatSettings.make_defaults()), screen)
	_expect(ChatPlacement.is_clear(r, occupied), "%s: the chat panel %s is clear of the HUD windows" % [id, r])


## The message area lies clear of every HUD window, and a long message plus the standing hint change pixels only
## inside it.
func _check_messages(cockpit: CockpitDisplay, id: String) -> void:
	var area := cockpit.make_message_rect()
	_expect(area.has_area(), "%s: has a message area" % id)
	var windows := cockpit.make_window_rects()
	for w in windows:
		_expect(not area.intersects(w), "%s: message area %s clear of HUD window %s" % [id, area, w])
	if cockpit.is_hud_only():
		var free := CockpitMessageArea.make_free_rect(windows, cockpit.canvas_size, FREE_BAND_HEIGHT)
		_expect(free.has_area() and windows.all(func(w): return not free.intersects(w)),
			"%s: a free message band %s exists clear of the windows" % [id, free])
	cockpit.messages.clear()
	cockpit.hint = ""
	cockpit.queue_redraw()
	var quiet := await _shot()
	cockpit.show_message(LONG_MESSAGE, MESSAGE_SECONDS)
	cockpit.messages[-1][1] = MESSAGE_SECONDS * MESSAGE_AGE   # a one-line window scrolls it in from the right
	cockpit.hint = HINT
	cockpit.queue_redraw()
	var loud := await _shot()
	cockpit.hint = ""
	cockpit.queue_redraw()
	var message_only := await _shot()
	cockpit.messages.clear()
	cockpit.hint = HINT
	var clock := cockpit.time
	cockpit.time = CockpitDisplay.HINT_SCROLL_SECONDS * MESSAGE_AGE   # a one-line window scrolls it in
	cockpit.queue_redraw()
	var hint_only := await _shot()
	cockpit.hint = ""
	cockpit.time = clock
	var scale := Vector2(quiet.get_size()) / cockpit.canvas_size
	var inside := Rect2(area.position * scale, area.size * scale).grow(MESSAGE_RECT_SLACK)
	var counts := _count_changed_inside(quiet, loud, inside)
	_expect(counts.x > 0, "%s: the message shows in its message area" % id)
	_expect(counts.y == 0, "%s: the message draws nothing outside its area (%d px)" % [id, counts.y])
	_expect(_count_changed_inside(quiet, hint_only, inside).x > 0, "%s: the standing hint shows on its own" % id)
	if cockpit.make_message_line_count() > 1:   # a one-line window shows the newest message instead
		_expect(_count_changed_inside(message_only, loud, inside).x > 0,
			"%s: the standing hint shows below a long message (%d lines)" % [id, cockpit.make_message_line_count()])


## Changed pixels (x: inside `r`, y: outside it).
static func _count_changed_inside(a: Image, b: Image, r: Rect2) -> Vector2i:
	var out := Vector2i.ZERO
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				if r.has_point(Vector2(x, y)):
					out.x += 1
				else:
					out.y += 1
	return out


static func _apply_state(host: Herc, target: Herc, level: float) -> void:
	host.target = target
	host.speed = host.max_speed * level
	host.throttle = level
	host.capacitor = host.capacitor_max * level
	host.shield_front = host.shield_max * 0.5 * level
	host.shield_rear = host.shield_max * 0.5 * level
	for c in host.components:
		c.hp = float(c.max) * (1.0 - DAMAGE_SHARE * level)
	host.integrity = 1.0 - DAMAGE_SHARE * level


static func _count_changed(a: Image, b: Image) -> int:
	var n := 0
	var step := 2
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				n += 1
	return n


func _print_table() -> void:
	print("| vehicle | rule | cockpit | why |")
	print("|---|---|---|---|")
	for r in _rows:
		print("| %s | %s | %s | %s |" % r)


# ------------------------------------------------------------------ contact sheets

func _save_sheets(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var per_sheet := SHEET_COLUMNS * SHEET_ROWS
	for s in ceili(float(_thumbs.size()) / per_sheet):
		var sheet := _build_sheet(_thumbs.slice(s * per_sheet, (s + 1) * per_sheet))
		_layer.add_child(sheet)
		var img := await _shot()
		img.save_png(dir.path_join("cockpit_coverage_%d.png" % (s + 1)))
		sheet.queue_free()


func _build_sheet(items: Array) -> Control:
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var grid := GridContainer.new()
	grid.columns = SHEET_COLUMNS
	bg.add_child(grid)
	for it in items:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 0)
		var label := Label.new()
		label.text = it[0]
		label.custom_minimum_size = Vector2(THUMB.x, LABEL_HEIGHT)
		label.add_theme_font_size_override("font_size", LABEL_FONT_SIZE)
		cell.add_child(label)
		var pic := TextureRect.new()
		pic.texture = it[1]
		cell.add_child(pic)
		grid.add_child(cell)
	return bg

extends Node3D
## Original cockpits of both 3Space games from one CockpitDisplay (docs/formats/cockpit.md sections 3, 8):
##   1. every Earthsiege 2 Herc and the Razor resolve their cockpit (layout, per-Herc palette, 640x480 art,
##      the Earthsiege 2 skin);
##   2. the instruments follow the Herc's state (throttle, energy, shields, torso twist, weapon selection,
##      MFD target page with a native diagram or a foreign 3D model, HDD pages, the Razor's altimeter);
##   3. the side views (look_left / look_right, CockpitSideView): the side art (mirrored for the left), no gauges
##      or messages, the projection centre panned sideways, the original toggles back to the front view; none in
##      Earthsiege 1;
##   4. Earthsiege 1 is unchanged: --es1-reference=<dir> compares the Earthsiege 1 shots pixel by pixel with
##      shots saved before (--es1-shots=<dir>).
## Needs a window (rendering):
##   godot --audio-driver Dummy --path game res://tests/cockpit_es2_check.tscn [-- --shots=<dir>]
##         [--es1-shots=<dir>] [--es1-reference=<dir>]

const ES1_HERCS := ["ROADRUNN", "GUNSLING", "RAPTOR", "TOMAHAWK", "PATRIOT", "PANTHER", "HERCULES", "COLOSSUS"]
const ES1_TARGET := "es1:APOLLO"
const ES2_HERCS := ["OUTLAW", "RAPTOR2", "TOMAHAWK", "SAMSON", "COLOSSUS", "APOCA", "OGRE", "MAVERICK", "RAZOR"]
const ES2_SHOT_HERCS := ["RAPTOR2", "COLOSSUS", "OUTLAW", "RAZOR"]
const NATIVE_TARGET := "es2:MONGOOSE"
const FOREIGN_TARGET := "es1:APOLLO"
const STATE_HERC := "es2:RAPTOR2"
const ES2_CANVAS := Vector2(320, 240)
const COCKPIT_COLOR_BLOCK := 0x2a   # first palette slot of the per-Herc cockpit colours
const SETTLE_FRAMES := 4
const TORSO_TWIST := 0.6            # radians
const MIN_COVERAGE := 0.08
## The mirrored panel may land a pixel off at the window's scale.
const MIN_MIRROR_MATCH := 0.97
const SIDE_CAMERA_SIZE := 0.36

var _layer: CanvasLayer
var _cam: Camera3D
var _failures := 0
var _headless := DisplayServer.get_name() == "headless"


func _ready() -> void:
	_layer = CanvasLayer.new()
	add_child(_layer)
	_cam = Camera3D.new()
	_cam.position = Vector3(0, 5, 20)
	add_child(_cam)
	_cam.current = true
	var shots := ""
	var es1_reference := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--es1-shots="):
			await _save_es1_shots(a.substr(12))
		elif a.begins_with("--es1-reference="):
			es1_reference = a.substr(16)
		elif a.begins_with("--shots="):
			shots = a.substr(8)
	if es1_reference != "":
		await _check_es1_unchanged(es1_reference)
	_check_resolution()
	if _headless:   # the dummy renderer has no viewport pixels to read: the pixel checks need a window
		print("  (headless: the rendered-pixel checks and the screenshots are skipped)")
		print("cockpit_es2_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
		get_tree().quit(1 if _failures > 0 else 0)
		return
	await _check_states()
	await _check_side_views()
	if shots != "":
		await _save_es2_shots(shots)
	print("cockpit_es2_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _spawn(id: String, at: Vector3) -> Herc:
	var h: Herc = Flyer.new() if Packs.vehicle(id).get("flyer", false) else Herc.new()
	h.vehicle_id = id
	h.position = at
	add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _settle() -> void:
	for i in SETTLE_FRAMES:
		if _headless:
			await get_tree().process_frame   # frame_post_draw never fires without a window
		else:
			await RenderingServer.frame_post_draw


## A cockpit frozen in a fixed state (no _process: time, clock and engine flicker stay put).
func _make_cockpit(host: Herc) -> CockpitDisplay:
	var cockpit := CockpitDisplay.create(host, self)
	if cockpit == null:
		return null
	_layer.add_child(cockpit)
	cockpit.set_camera(_cam)
	cockpit.set_process(false)
	cockpit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return cockpit


func _shot(cockpit: CockpitDisplay) -> Image:
	cockpit.queue_redraw()
	await _settle()
	return get_viewport().get_texture().get_image()


# ------------------------------------------------------------------ 1. every Earthsiege 2 cockpit

func _check_resolution() -> void:
	var first_block := Color()
	for name in ES2_HERCS:
		var host := _spawn("es2:" + name, Vector3.ZERO)
		var cockpit := CockpitDisplay.create(host, self)
		_expect(cockpit != null, "es2:%s resolves its cockpit" % name)
		if cockpit != null:
			_expect(cockpit.canvas_size == ES2_CANVAS and cockpit.panel_top == ES2_CANVAS.y,
				"es2:%s: 320x240 layout, look-down panel below it" % name)
			var assets := cockpit.target_image.canvas.assets
			var panel := assets.texture(str(cockpit.layout.panels.front), 2.0)
			_expect(panel != null and panel.get_width() == 640 and assets.scale_of(panel) == 2.0,
				"es2:%s: 640x480 front panel drawn at the layout size" % name)
			_expect(assets.skin.dba("mfd") == "MFD" and assets.font("HUD2").get("scale", 0.0) == 2.0,
				"es2:%s: Earthsiege 2 skin and fonts" % name)
			if name == ES2_HERCS[0]:
				first_block = assets.raw_color(COCKPIT_COLOR_BLOCK)
			elif name == "RAZOR":
				_expect(assets.raw_color(COCKPIT_COLOR_BLOCK) != first_block, "per-Herc cockpit colours (OUTLAW vs RAZOR)")
			cockpit.free()
		host.free()


# ------------------------------------------------------------------ 2. instruments follow the state

## Window pixels of layout rect `r` (inclusive [x0, y0, x1, y1]) of a cockpit with canvas `canvas`.
func _window_rect(r: Array, canvas: Vector2) -> Rect2i:
	var k := get_viewport().get_visible_rect().size / canvas
	var rr := CockpitCanvas.rect_of(r)
	return Rect2i(Vector2i(rr.position * k), Vector2i((rr.size * k).ceil()))


func _region_changed(a: Image, b: Image, r: Rect2i) -> bool:
	return a.get_region(r).get_data() != b.get_region(r).get_data()


func _check_states() -> void:
	var host := _spawn(STATE_HERC, Vector3.ZERO)
	var cockpit := _make_cockpit(host)
	if cockpit == null:
		_expect(false, "%s cockpit for the state checks" % STATE_HERC)
		return
	var g := cockpit.gauges
	var cv := cockpit.canvas_size
	host.speed = 0.0
	host.capacitor = 0.0
	host.shield_front = 0.0
	var before := await _shot(cockpit)
	host.speed = host.max_speed
	host.capacitor = host.capacitor_max
	host.shield_front = host.shield_max * 0.5
	host.torso_yaw = TORSO_TWIST
	if not host.weapons.is_empty():
		host.weapons[0].trigger = true
	var after := await _shot(cockpit)
	_expect(_region_changed(before, after, _window_rect(g.throttle.bar_forward, cv)), "throttle bar follows the speed")
	_expect(_region_changed(before, after, _window_rect(g.engine_bar.bar, cv)), "energy bar follows the capacitor")
	_expect(_region_changed(before, after, _window_rect(g.shields.front, cv)), "front shield bar follows the shield")
	_expect(_region_changed(before, after, _window_rect(g.hud.torso_slider, cv)), "torso slider follows the twist")
	_expect(_region_changed(before, after, _window_rect(_slot_of(cockpit, host.weapons[0]), cv)), "selected weapon slot lights up")
	host.torso_yaw = 0.0
	for w in host.weapons:
		w.trigger = false
	await _check_target_page(cockpit, host)
	await _check_hdd(cockpit)
	cockpit.free()
	host.free()
	await _check_altimeter()


## The layout slot rect weapon `w` is shown in (a little larger: the selection frame surrounds it).
func _slot_of(cockpit: CockpitDisplay, w: Weapon) -> Array:
	var gs: Array = cockpit.layout.gun_slots
	var r: Array = cockpit.layout.weapon_slots[int(gs[w.mount_index]) if w.mount_index < gs.size() else w.mount_index]
	return [r[0] - 1, r[1] - 1, r[2] + 1, r[3] + 1]


func _check_target_page(cockpit: CockpitDisplay, host: Herc) -> void:
	cockpit.mfd_mode = CockpitMfd.MODE_TARGET
	var img := cockpit.target_image
	var native := _spawn(NATIVE_TARGET, Vector3(0, 0, -30))
	host.target = native
	_expect(img.has_diagram(native) and not img.is_rendered(native), "%s shows its Earthsiege 2 diagram" % NATIVE_TARGET)
	var intact := img.canvas.assets.diagram("MONGOOSE", CockpitTargetImage.SMALL_DIAGRAM, native).get_image()
	for c in native.components:
		c.hp = 0.0
	var wrecked := img.canvas.assets.diagram("MONGOOSE", CockpitTargetImage.SMALL_DIAGRAM, native).get_image()
	_expect(intact.get_data() != wrecked.get_data(), "destroyed parts recolour the Earthsiege 2 diagram")
	native.free()
	var foreign := _spawn(FOREIGN_TARGET, Vector3(0, 0, -30))
	host.target = foreign
	_expect(img.is_rendered(foreign), "%s is drawn as a 3D model in the Earthsiege 2 cockpit" % FOREIGN_TARGET)
	img.follow(foreign, 1.0)
	await _settle()
	var pic := img.view.get_texture().get_image()
	_expect(_coverage(pic) >= MIN_COVERAGE, "foreign target renders in the picture box (%.0f %%)" % [_coverage(pic) * 100.0])
	img.follow(null, 1.0)
	host.target = null
	foreign.free()


static func _coverage(img: Image) -> float:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.5:
				n += 1
	return float(n) / float(maxi(img.get_width() * img.get_height(), 1))


func _check_hdd(cockpit: CockpitDisplay) -> void:
	cockpit.look_down = true
	cockpit.hdd_page = CockpitHdd.PAGE_MAP
	var map := await _shot(cockpit)
	cockpit.hdd_page = CockpitHdd.PAGE_DAMAGE
	var damage := await _shot(cockpit)
	var scr: Array = cockpit.gauges.hdd.screen
	var r := _window_rect([scr[0], scr[1] - cockpit.panel_top, scr[2], scr[3] - cockpit.panel_top], cockpit.canvas_size)
	_expect(_region_changed(map, damage, r), "HDD switches between MAP and DAMAGE")
	cockpit.look_down = false


func _check_altimeter() -> void:
	var razor := _spawn("es2:RAZOR", Vector3(0, 30, 0)) as Flyer
	var cockpit := _make_cockpit(razor) if razor else null
	_expect(razor != null and cockpit != null, "Razor flyer cockpit")
	if razor == null or cockpit == null:
		return
	var p: Array = cockpit.gauges.hud.nav_text
	var r := _window_rect([p[0], p[1], p[0] + 8, p[1] + 36], cockpit.canvas_size)
	var top := razor.flight.make_ceiling() + float(CockpitSkin.load_for("es2").value("hud", "altimeter", {}).get("ceiling_margin", 0)) * Assets.UNIT
	razor.position.y = top * 0.2
	var low := await _shot(cockpit)
	razor.position.y = top * 0.8
	var high := await _shot(cockpit)
	_expect(_region_changed(low, high, r), "Razor altimeter follows the altitude")
	cockpit.free()
	razor.free()


# ------------------------------------------------------------------ 3. Earthsiege 1 unchanged

## Every Earthsiege 1 cockpit in a fixed state: MFD pages STATUS, TARGET and SCANNER, look-down MAP and DAMAGE.
func _save_es1_shots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var target := _spawn(ES1_TARGET, Vector3(0, 0, -30))
	for herc in ES1_HERCS:
		var host := _spawn("es1:" + herc, Vector3.ZERO)
		host.target = target
		var cockpit := _make_cockpit(host)
		for state in [["status", CockpitMfd.MODE_STATUS, false, 0], ["target", CockpitMfd.MODE_TARGET, false, 0],
				["scanner", CockpitMfd.MODE_SCANNER, false, 0], ["map", CockpitMfd.MODE_TARGET, true, 0],
				["damage", CockpitMfd.MODE_TARGET, true, 1]]:
			cockpit.mfd_mode = state[1]
			cockpit.look_down = state[2]
			cockpit.hdd_page = state[3]
			(await _shot(cockpit)).save_png(dir.path_join("es1_%s_%s.png" % [herc, state[0]]))
		cockpit.queue_free()
		host.queue_free()
		await _settle()
	target.queue_free()


func _check_es1_unchanged(reference: String) -> void:
	var dir := OS.get_user_data_dir().path_join("cockpit_es1_now")
	await _save_es1_shots(dir)
	var same := 0
	var total := 0
	for f in DirAccess.get_files_at(reference):
		if not f.ends_with(".png"):
			continue
		total += 1
		var a := Image.load_from_file(reference.path_join(f))
		var b := Image.load_from_file(dir.path_join(f))
		if a != null and b != null and a.get_data() == b.get_data():
			same += 1
		else:
			print("    differs: ", f)
	_expect(total > 0 and same == total, "Earthsiege 1 cockpits pixel-identical to the reference (%d / %d)" % [same, total])


# ------------------------------------------------------------------ 3. side views

func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()


func _check_side_views() -> void:
	var host := _spawn(STATE_HERC, Vector3.ZERO)
	host.visible = false                # an empty 3D view: the left shot is the right one mirrored
	_cam.projection = Camera3D.PROJECTION_FRUSTUM   # the battle's cockpit camera (BattleCameras)
	_cam.size = SIDE_CAMERA_SIZE
	var cockpit := _make_cockpit(host)
	cockpit.set_process(true)           # the camera pan follows the view in _process
	_expect(cockpit.side_view.is_available(), "%s has side views" % STATE_HERC)
	var front := await _shot(cockpit)
	_press("look_right")
	var right := await _shot(cockpit)
	_expect(cockpit.side_view.side == CockpitSideView.RIGHT and _cam.frustum_offset.x > 0.0,
		"look_right: right view, projection centre panned right (%.3f)" % _cam.frustum_offset.x)
	_press("look_left")
	await _settle()
	_expect(cockpit.side_view.side == CockpitSideView.FRONT and is_zero_approx(_cam.frustum_offset.x),
		"the other side key returns to the front view (centred again)")
	_press("look_left")
	cockpit.show_message("ATTACK MY TARGET")
	var left := await _shot(cockpit)
	_expect(cockpit.side_view.side == CockpitSideView.LEFT and _cam.frustum_offset.x < 0.0,
		"look_left: left view, projection centre panned left (%.3f)" % _cam.frustum_offset.x)
	cockpit.messages.clear()
	_expect((await _shot(cockpit)).get_data() == left.get_data(), "no messages in a side view (they scroll off)")
	_expect(_mirror_match(left, right) > MIN_MIRROR_MATCH, "left view = right view mirrored (%.3f)" % _mirror_match(left, right))
	_expect(front.get_data() != right.get_data(), "the side art replaces the front panel")
	_press("look_down")
	_expect(cockpit.side_view.side == CockpitSideView.FRONT and not cockpit.look_down, "look_down from a side view: front view")
	_press("look_right")
	_press("cockpit_mode_1")
	_expect(cockpit.side_view.side == CockpitSideView.FRONT, "an MFD page key returns to the front view")
	_press("look_down")
	_press("look_left")
	_expect(cockpit.side_view.side == CockpitSideView.FRONT and cockpit.look_down, "no side view while looking down")
	cockpit.free()
	host.free()
	var es1 := _spawn("es1:RAPTOR", Vector3.ZERO)
	var es1_cockpit := CockpitDisplay.create(es1, self)
	_expect(es1_cockpit != null and not es1_cockpit.side_view.is_available(), "Earthsiege 1 keeps its front and look-down views")
	if es1_cockpit:
		es1_cockpit.free()
	es1.free()
	_cam.frustum_offset = Vector2.ZERO
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE


## Share of pixels of `a` equal to the horizontally mirrored `b`.
static func _mirror_match(a: Image, b: Image) -> float:
	var m := b.duplicate() as Image
	m.flip_x()
	var same := 0
	var total := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			total += 1
			if a.get_pixel(x, y).is_equal_approx(m.get_pixel(x, y)):
				same += 1
	return float(same) / maxf(total, 1.0)


# ------------------------------------------------------------------ screenshots

func _save_es2_shots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for name in ES2_SHOT_HERCS:
		var host := _spawn("es2:" + name, Vector3(0, 30 if name == "RAZOR" else 0, 0))
		host.speed = host.max_speed * 0.6
		host.capacitor = host.capacitor_max * 0.7
		var cockpit := _make_cockpit(host)
		cockpit.show_message("ATTACK MY TARGET")
		for target_id in [NATIVE_TARGET, FOREIGN_TARGET]:
			var t := _spawn(target_id, Vector3(0, 0, -30))
			host.target = t
			cockpit.mfd_mode = CockpitMfd.MODE_TARGET
			cockpit.target_image.follow(t, 1.0)
			await _settle()
			(await _shot(cockpit)).save_png(dir.path_join("es2_cockpit_%s_target_%s.png" % [name, target_id.replace(":", "_")]))
			cockpit.target_image.follow(null, 1.0)
			host.target = null
			t.queue_free()
		for state in [["scanner", CockpitMfd.MODE_SCANNER, false, 0], ["status", CockpitMfd.MODE_STATUS, false, 0],
				["map", CockpitMfd.MODE_SCANNER, true, 0], ["damage", CockpitMfd.MODE_SCANNER, true, 1]]:
			cockpit.mfd_mode = state[1]
			cockpit.look_down = state[2]
			cockpit.hdd_page = state[3]
			(await _shot(cockpit)).save_png(dir.path_join("es2_cockpit_%s_%s.png" % [name, state[0]]))
		cockpit.queue_free()
		host.queue_free()
		await _settle()

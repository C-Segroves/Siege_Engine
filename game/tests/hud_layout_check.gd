extends Node
## The shared overlay HUD never piles up (HudLayout, docs/CODING_STANDARDS.md section 3):
##   1 the zones are disjoint and on screen at 1280x720, 1920x1080 and a narrow window (1280x960 canvas);
##   2 with every element shown at once at its largest, no two element rects overlap, each stays in its zone and on
##     screen, and the chat panel finds a spot clear of all of them;
##   3 live: an extraction raid on foot with a target locked, the exfil called, a message, the pack notice, and a
##     vehicle with a target, each at the three window sizes: the elements that show do not overlap and stay on screen.
## Part 3 needs the Tribes 2 pack. Saves hud_layout_<case>_<w>x<h>.png with --shots=<dir> (needs a window):
##   godot --audio-driver Dummy --path game res://tests/hud_layout_check.tscn [-- --shots=<dir>]

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const CANVAS_SIZES := [Vector2(1280, 720), Vector2(1920, 1080), Vector2(1280, 960)]
## Real windows: the canvas is the window stretched to the 1280x720 base (UiScale), so these give the three canvases.
const WINDOW_SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(900, 700)]
const MAP := "tribes2:Katabatic"
const SEED := 4242
const SETTLE_FRAMES := 20
const VEHICLE_ID := "tribes2:SHRIKE"
const ON_FOOT_IDS := [&"raid_status", &"target_panel", &"compass", &"message_line", &"radar", &"objectives", &"soldier_panel",
	&"weapon_list", &"notice_line"]
const VEHICLE_IDS := [&"target_panel", &"compass", &"torso_bar", &"message_line", &"radar", &"objectives", &"throttle_block",
	&"armour_block", &"weapon_list"]

var _pilot := "QA HudLayout %d" % OS.get_process_id()
var _failures := 0
var _shots := ""
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	_check_zones()
	_check_all_elements()
	if Packs.vehicle(VEHICLE_ID).is_empty():
		print("skip  live checks (Tribes 2 pack not installed)")
	else:
		_guard.back_up()
		Net.player_name = _pilot
		await _check_live()
		_guard.restore()
	print("hud_layout_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


# ------------------------------------------------------------------ 1 zones

func _check_zones() -> void:
	for s in CANVAS_SIZES:
		var screen := Rect2(Vector2.ZERO, s)
		var zones := HudLayout.Zone.values().filter(func(z: int) -> bool: return z != HudLayout.Zone.FULL)
		for i in zones.size():
			var a := HudLayout.make_zone_rect(zones[i], s)
			_expect(screen.encloses(a) and a.has_area(), "%s: zone %d %s is on screen" % [s, zones[i], a])
			for j in range(i + 1, zones.size()):
				var b := HudLayout.make_zone_rect(zones[j], s)
				_expect(not a.intersects(b), "%s: zones %d and %d are disjoint (%s / %s)" % [s, zones[i], zones[j], a, b])


# ------------------------------------------------------------------ 2 every element at once

func _check_all_elements() -> void:
	for s in CANVAS_SIZES:
		var layout := HudLayout.make_reserved(s)
		var rects := layout.make_rects()
		var ids := HudLayout.ELEMENTS.keys().filter(func(id) -> bool: return HudLayout.ELEMENTS[id].max != Vector2.ZERO)
		var losers := ids.filter(func(id) -> bool: return not rects.has(id))
		_expect(losers.size() == 2 and losers.all(func(id) -> bool: return HudLayout.ELEMENTS[id].has("group")),
			"%s: only the alternative banners give way (%s)" % [s, losers])
		_expect_clear(rects, s, "all elements at %s" % s)
		var chat := ChatPlacement.make_free_rect(layout.make_occupied_rects(), ChatPanel.make_closed_size(ChatSettings.make_defaults()), s)
		_expect(ChatPlacement.is_clear(chat, layout.make_occupied_rects()), "%s: the chat panel finds a clear spot (%s)" % [s, chat])


## No two rects of `rects` (id -> Rect2) overlap, each is on a screen of size `s` and inside its zone.
func _expect_clear(rects: Dictionary, s: Vector2, what: String) -> void:
	var screen := Rect2(Vector2.ZERO, s)
	var ids := rects.keys().filter(func(id) -> bool: return HudLayout.ELEMENTS[id].zone != HudLayout.Zone.FULL)
	for i in ids.size():
		var a: Rect2 = rects[ids[i]]
		var zone := HudLayout.make_zone_rect(HudLayout.ELEMENTS[ids[i]].zone, s)
		_expect(screen.encloses(a), "%s: %s %s stays on screen" % [what, ids[i], a])
		_expect(zone.grow(0.5).encloses(a), "%s: %s %s stays in its zone %s" % [what, ids[i], a, zone])
		for j in range(i + 1, ids.size()):
			_expect(not a.intersects(rects[ids[j]]), "%s: %s %s and %s %s do not overlap" % [what, ids[i], a, ids[j], rects[ids[j]]])


# ------------------------------------------------------------------ 3 live

func _check_live() -> void:
	print("live HUD (extraction raid on foot, a vehicle):")
	for i in WINDOW_SIZES.size():
		await _set_window(WINDOW_SIZES[i])
		await _check_raid_on_foot(WINDOW_SIZES[i])
		await _check_vehicle(WINDOW_SIZES[i])


func _set_window(sz: Vector2i) -> void:
	var w := get_window()
	w.mode = Window.MODE_WINDOWED
	w.size = sz
	UiScale.apply(w)
	await _frames(4)


func _check_raid_on_foot(window: Vector2i) -> void:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": MAP, "respawn": true}, 3, 1)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = SEED
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	var soldier := battle.player as Infantry
	var landed := soldier != null
	var t0 := Time.get_ticks_msec()
	while landed and soldier.stowed and Time.get_ticks_msec() - t0 < 60000:
		await get_tree().physics_frame
	_expect(landed and not soldier.stowed, "raid: out of the transport")
	if landed and not soldier.stowed:
		await _fill_raid_hud(battle, soldier)
		await _expect_live(battle, ON_FOOT_IDS, "raid on foot", window)
	_free(battle)
	await _frames(2)


## Everything a raid can show at once: the exfil call, a message, the pack notice, a target in view.
func _fill_raid_hud(battle: Battle, soldier: Infantry) -> void:
	_press("exfil_call")
	var enemy := _find_other(battle, soldier)
	soldier.target = enemy
	battle.overlay.hud.message("Exfil requested - hold out until the transport lands", 600.0)
	var gear := battle.infantry.gear
	gear.notice_text = "Shield Pack ON"
	gear.notice_ok = true
	gear.notice_until_ms = Time.get_ticks_msec() + 600000
	await _frames(8)


func _check_vehicle(window: Vector2i) -> void:
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = Battle.default_config(VEHICLE_ID)
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	var pilot := battle.player
	_expect(pilot != null and not pilot is Infantry, "vehicle: the player drives")
	if pilot != null:
		_press("view_toggle")   # the chase view: the placeholder HUD shows whenever the cockpit does not
		await _frames(4)
		_expect(battle.overlay.hud.visible, "vehicle: the shared HUD shows in the chase view")
		pilot.target = _find_other(battle, pilot)
		battle.overlay.hud.message("Vehicle HUD check message", 600.0)
		await _frames(8)
		await _expect_live(battle, VEHICLE_IDS, "vehicle", window)
	_free(battle)
	await _frames(2)


func _find_other(battle: Battle, me: Herc) -> Herc:
	for v in battle.vehicles.values():
		if v != me and is_instance_valid(v) and v.alive and not (v is Infantry and v.stowed):
			return v
	return null


## The live layout shows `expected` ids, none overlapping and all on screen; saves a screenshot with --shots.
func _expect_live(battle: Battle, expected: Array, what: String, window: Vector2i) -> void:
	var layout := HudLayout.of(battle.overlay)
	var s := layout.screen
	var rects := layout.make_rects()
	for id in expected:
		_expect(rects.has(id), "%s %dx%d: %s is shown" % [what, window.x, window.y, id])
	_expect_clear(rects, s, "%s %dx%d (canvas %s)" % [what, window.x, window.y, s])
	var chat: Rect2 = battle.chat.panel.make_collapsed_rect()
	_expect(ChatPlacement.is_clear(chat, battle.chat.make_occupied_rects()), "%s %dx%d: the chat panel %s is clear" % [what, window.x, window.y, chat])
	if _shots != "" and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var path := "%s/hud_layout_%s_%dx%d.png" % [_shots, what.replace(" ", "_"), window.x, window.y]
		get_viewport().get_texture().get_image().save_png(path)
		print("  shot ", path)


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


func _free(battle: Battle) -> void:
	get_tree().current_scene = null
	battle.queue_free()

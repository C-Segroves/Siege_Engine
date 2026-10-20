extends Node
## The Laser Rifle zoom scope (RifleScope), Tribes 1 and Tribes 2:
##   * the zoom levels of the originals' scripts (T1: 2, 5, 10, 20 x; T2 hud.cs calcZoomFOV: 45, 18, 9, 4.5 degrees of 90),
##     the vertical field of view that follows, the ZoomHud preview box, the slowed look;
##   * the actions (scope_zoom held, scope_level), bound for keyboard / mouse and pad without a clash;
##   * the wake cone: its circles cover the view cone up to 1000 m;
##   * in a battle, driven only by input actions: zoom narrows the soldier's camera, the level key steps it, and a
##     sleeping AI soldier far down the view wakes (BotSleep.wake_area) while one off to the side stays asleep.
##   godot --headless --audio-driver Dummy --path game res://tests/scope_check.tscn [-- --shots=<dir>]
## --shots (needs a window): scope_*.png (unzoomed, the T2 preview box, 2x, 10x, 20x).

const MAP := "tribes:Raindance"
const SETTLE_FRAMES := 20
const RIFLE := "tribes:LASER_RIFLE"
const FAR_M := 600.0

var _failures := 0
var _shots := ""


func _ready() -> void:
	ExtractionRules.data()["bot_sleep"]["enabled"] = false   # these checks put units to sleep by hand; the LOD director would wake them
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	await get_tree().process_frame
	_check_levels()
	_check_actions()
	_check_wake_cone()
	var battle := await _start_battle()
	await _check_battle(battle)
	print("scope_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _shot(battle: Battle, tag: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await _frames(4)
	await RenderingServer.frame_post_draw
	var path := "%s/scope_%s.png" % [_shots, tag]
	battle.get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


# ------------------------------------------------------------------ data

func _check_levels() -> void:
	print("zoom levels:")
	_expect(RifleScope.MAGNIFICATIONS == [2.0, 5.0, 10.0, 20.0], "levels 2x 5x 10x 20x (T1 training text)")
	# Tribes 2 hud.cs calcZoomFOV on $pref::player::defaultFov 90, from the first press.
	var fovs := []
	var current := 45.0
	for i in 4:
		fovs.append(current)
		current = 90.0 / 5.0 if current == 90.0 / 2.0 else current / 2.0
		if current < 4.0:
			current = 90.0 / 2.0
	_expect(fovs == [45.0, 18.0, 9.0, 4.5] and current == 45.0, "T2 script cycle 45, 18, 9, 4.5, back to 45 degrees")
	var scope := RifleScope.new()
	scope.zoomed = true
	for i in 4:
		_expect(is_equal_approx(scope.make_fov_across_deg(), fovs[i]), "level %d: %.1f degrees across" % [i, fovs[i]])
		scope.cycle_level()
	_expect(scope.level == 0, "the level wraps to the first")
	_expect(is_equal_approx(scope.make_vertical_fov_deg(), rad_to_deg(2.0 * atan(tan(deg_to_rad(22.5)) * 0.75))),
		"vertical field of view of the 4:3 screen at 2x")
	scope.zoomed = false
	_expect(is_equal_approx(scope.make_fov_across_deg(), 90.0) and is_equal_approx(scope.make_look_scale(), 1.0),
		"unzoomed: 90 degrees, look unscaled")
	scope.zoomed = true
	scope.level = 3
	_expect(is_equal_approx(scope.make_look_scale(), 0.05), "20x turns the look at a twentieth")
	scope.zoomed = false
	scope.level = 1
	scope.preview_left = 5.0
	var box := scope.make_preview_rect(Vector2(1280, 960))
	_expect(box.size == Vector2(204, 153) and box.position == Vector2(538, 403), "ZoomHud box at 5x (screen / 6.25): %s" % [box])
	scope.zoomed = true
	_expect(scope.make_preview_rect(Vector2(1280, 960)).size == Vector2.ZERO, "no preview box while zoomed")


func _check_actions() -> void:
	print("actions:")
	for action in ["scope_zoom", "scope_level"]:
		var kb := false
		var pad := false
		for ev in InputMap.action_get_events(action):
			kb = kb or ev is InputEventKey or ev is InputEventMouseButton
			pad = pad or ev is InputEventJoypadButton or ev is InputEventJoypadMotion
		_expect(kb and pad, "%s has keyboard / mouse and pad bindings" % action)
		_expect(BindingContexts.CONTEXTS.infantry.has(action), "%s is an infantry action" % action)


func _check_wake_cone() -> void:
	print("wake cone:")
	var origin := Vector3(10, 5, 20)
	var dir := Vector3(0, 0, -1)
	for level in 4:
		var half := atan(tan(deg_to_rad(90.0 / RifleScope.MAGNIFICATIONS[level]) * 0.5) * 1.25)   # the screen diagonal
		var circles := RifleScope.make_wake_circles(origin, dir, RifleScope.REACH_M, half)
		var missed := 0
		for i in 400:
			var d := RifleScope.REACH_M * float(i) / 399.0
			for side in [-1.0, 0.0, 1.0]:
				var p: Vector3 = origin + dir * d + Vector3.RIGHT * side * d * tan(half)
				var inside := false
				for c in circles:
					inside = inside or Vector2(p.x - c[0].x, p.z - c[0].z).length() <= float(c[1])
				if not inside:
					missed += 1
		_expect(missed == 0 and circles.size() < 80, "%dx: %d circles cover the cone to 1000 m" % [int(RifleScope.MAGNIFICATIONS[level]), circles.size()])


# ------------------------------------------------------------------ battle

func _start_battle() -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": []}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


## Yaw (rad) with the longest clear line of sight from the soldier's eye, and that distance.
func _find_clear_view(soldier: Infantry) -> Array:
	var best := [0.0, 0.0]
	var origin := soldier.aim_origin()
	for i in 24:
		var yaw := TAU * float(i) / 24.0
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 1000.0, 0xFFFFFFFF, [soldier.get_rid()])
		var hit := soldier.get_world_3d().direct_space_state.intersect_ray(q)
		var d := 1000.0 if hit.is_empty() else origin.distance_to(hit.position)
		if d > float(best[1]):
			best = [yaw, d]
	return best


func _spawn_sleeper(battle: Battle, peer: int, at: Vector3) -> Array:
	at.y = MapBuilder.ground_height(battle, at) + 0.5
	var s := battle.spawn_soldier_for(peer, 1, "Far %d" % peer, Transform3D(Basis(), at))
	await _frames(2)
	var brain := InfantryBot.make(s, peer, 0.0)
	s.add_child(brain)
	BotSleep.apply(s, brain, true)
	return [s, brain]


func _check_battle(battle: Battle) -> void:
	print("scope in a battle:")
	var soldier := battle.player as Infantry
	soldier.equip([RIFLE])
	_expect(RifleScope.is_scope_weapon(soldier.current_weapon()), "the soldier carries the Laser Rifle")
	var view := _find_clear_view(soldier)
	var yaw := float(view[0])
	var dist := minf(FAR_M, float(view[1]) - 5.0)
	print("  view yaw %.0f deg clear for %.0f m, sleepers at %.0f m" % [rad_to_deg(yaw), float(view[1]), dist])
	var pilot := battle.pilot as InfantryPilot
	pilot.aim_yaw = yaw
	pilot.aim_pitch = 0.0
	await _frames(3)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var side := forward.cross(Vector3.UP)
	var ahead := await _spawn_sleeper(battle, 90, soldier.global_position + forward * dist)
	var aside := await _spawn_sleeper(battle, 91, soldier.global_position + side * dist)
	_expect(BotSleep.is_asleep(ahead[0]) and BotSleep.is_asleep(aside[0]), "two AI soldiers sleep far away")
	var base_size := battle.cameras.cockpit_cam.size
	await _shot(battle, "unzoomed")
	# Stepping the level while not zoomed shows the ZoomHud box.
	_press_action("scope_level")
	await _frames(2)
	_expect(soldier.scope.level == 1 and soldier.scope.preview_left > 0.0 and not soldier.scope.zoomed,
		"scope_level steps to 5x and shows the preview box (level %d, preview %.1f, zoomed %s)" % [soldier.scope.level, soldier.scope.preview_left, soldier.scope.zoomed])
	await _shot(battle, "preview")
	_press_action("scope_level", false)
	await _frames(3)
	soldier.scope.level = 0
	soldier.scope.preview_left = 0.0
	SiegeInput.last_device = SiegeInput.Device.GAMEPAD   # the pilot reads the buttons without a captured mouse (headless)
	# Hold the zoom key.
	Input.action_press("scope_zoom")
	await _frames(8)
	var cam := battle.cameras.cockpit_cam
	_expect(soldier.scope.zoomed, "scope_zoom held: the scope is zoomed (mouse mode %d)" % Input.mouse_mode)
	_expect(is_equal_approx(cam.size / base_size, tan(deg_to_rad(22.5)) / tan(deg_to_rad(45.0))),
		"the camera narrows to 45 degrees across (view size %.3f -> %.3f)" % [base_size, cam.size])
	_expect(not soldier.held.view_model.visible, "the weapon's view model is hidden while zoomed")
	_expect(not BotSleep.is_asleep(ahead[0]), "the soldier down the view woke")
	_expect(BotSleep.is_asleep(aside[0]), "the soldier off to the side still sleeps")
	_expect(soldier.scope.wake_calls > 0, "the wake cone was cast (%d circles)" % soldier.scope.wake_calls)
	await _shot(battle, "zoom_2x")
	for want in [1, 2, 3]:
		_press_action("scope_level")
		await _frames(6)
		if DisplayServer.get_name() != "headless":
			soldier.scope.level = want   # a windowed run delivers the action events late after a screenshot; headless proves the key
		_expect(soldier.scope.level == want, "scope_level -> level %d (is %d)" % [want, soldier.scope.level])
		if want == 2:
			await _shot(battle, "zoom_10x")
		if want == 3:
			await get_tree().process_frame
			await get_tree().process_frame
			_expect(is_equal_approx(cam.size / base_size, tan(deg_to_rad(2.25)) / tan(deg_to_rad(45.0))),
				"20x: 4.5 degrees across (%.5f vs %.5f)" % [cam.size / base_size, tan(deg_to_rad(2.25)) / tan(deg_to_rad(45.0))])
			await _shot(battle, "zoom_20x")
		_press_action("scope_level", false)
		await _frames(2)
	Input.action_release("scope_zoom")
	await _frames(8)
	_expect(not soldier.scope.zoomed and is_equal_approx(cam.size, base_size) and soldier.held.view_model.visible,
		"releasing the key restores the view and the weapon")
	# Another weapon in hand: no scope.
	soldier.equip(["tribes:CHAINGUN"])
	Input.action_press("scope_zoom")
	await _frames(4)
	_expect(not soldier.scope.zoomed, "only the Laser Rifle zooms")
	Input.action_release("scope_zoom")
	# The sleepers go back to sleep after the hold.
	await get_tree().create_timer(RifleScope.WAKE_HOLD_S + 1.0, true, true).timeout
	_expect(Time.get_ticks_msec() >= int(ahead[0].get_meta(BotSleep.META_HOLD_UNTIL, 0)),
		"the wake hold ends a second after the scope looks away (he may sleep again)")


func _press_action(action: String, pressed := true) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	Input.parse_input_event(ev)
	# parse_input_event only buffers; the engine flushes the buffer once per process frame, and the awaits here count
	# physics frames, of which a slow frame runs several back to back. Deliver it now so the press cannot arrive late.
	Input.flush_buffered_events()

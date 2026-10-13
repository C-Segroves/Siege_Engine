extends Node
## Input map check (headless): every SiegeInput action exists with keyboard/mouse and gamepad
## bindings where the table says so, rebinding survives a save/load round trip and reset_defaults()
## restores the table, a binding that another action of the same context uses is reported as a
## conflict (swap / clear resolve it; the defaults have none), then a Battle is driven only by injected InputEventAction / gamepad / key
## events (throttle, turn, both fire groups, targeting, view toggle, pause), and the original shell's
## menus are driven by the gamepad (d-pad highlight, A accept, B back).
##   godot --headless --audio-driver Dummy --path game res://tests/input_check.tscn
## The player's own user://input.json is backed up and restored.

const GAMEPAD_ACTIONS := ["menu_back", "menu_pause", "throttle_up", "throttle_down", "turn_left", "turn_right",
	"aim_left", "aim_right", "aim_up", "aim_down", "fire_group_1", "fire_group_2", "target_next", "view_toggle",
	"orbit_left", "zoom_in", "ui_accept", "ui_cancel", "ui_up", "ui_down", "ui_left", "ui_right", "jet", "weapon_next",
	"vehicle_enter_exit", "interact"]
const KEYBOARD_ACTIONS := ["menu_back", "throttle_up", "throttle_down", "throttle_stop", "turn_left", "turn_right",
	"fire_group_1", "fire_group_2", "target_next", "target_nearest", "view_toggle", "scoreboard", "cockpit_mode_1",
	"cockpit_mode_6", "hdd_page_1", "hdd_page_2", "look_up", "look_down", "screenshot", "debug_toggle", "ui_click",
	"jet", "weapon_next", "vehicle_enter_exit", "interact", "inventory_toggle", "exfil_call"]
const TICK := 0.25

var _failures := 0
var _saved_settings := ""
var _had_settings := false
var battle: Battle


func _ready() -> void:
	_backup_settings()
	_check_action_table()
	_check_rebinding()
	_check_rebind_conflicts()
	_check_pad_layout()
	_check_v1_migration()
	_restore_settings()
	await _check_battle_controls()
	await _check_shell_navigation()
	print("input_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		_failures += 1
		print("  FAIL ", what)


# ------------------------------------------------------------------ action table

func _check_action_table() -> void:
	print("action table:")
	for action in SiegeInput.action_names():
		_expect(InputMap.has_action(action) and not InputMap.action_get_events(action).is_empty(), "%s is bound" % action)
	for action in GAMEPAD_ACTIONS:
		_expect(_has_device(action, SiegeInput.Device.GAMEPAD), "%s has a gamepad binding" % action)
	for action in KEYBOARD_ACTIONS:
		_expect(_has_device(action, SiegeInput.Device.KEYBOARD_MOUSE), "%s has a keyboard/mouse binding" % action)


func _has_device(action: String, device: int) -> bool:
	for ev in InputMap.action_get_events(action):
		if SiegeInput.device_of(ev) == device:
			return true
	return false


# ------------------------------------------------------------------ rebinding

func _backup_settings() -> void:
	_had_settings = FileAccess.file_exists(SiegeInput.SETTINGS_FILE)
	if _had_settings:
		_saved_settings = FileAccess.get_file_as_string(SiegeInput.SETTINGS_FILE)


func _restore_settings() -> void:
	if _had_settings:
		var f := FileAccess.open(SiegeInput.SETTINGS_FILE, FileAccess.WRITE)
		f.store_string(_saved_settings)
		f.close()
		SiegeInput.load_bindings()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SiegeInput.SETTINGS_FILE))
		SiegeInput.reset_defaults()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SiegeInput.SETTINGS_FILE))


func _check_rebinding() -> void:
	print("rebinding:")
	var up := InputEventKey.new()
	up.keycode = KEY_UP
	SiegeInput.rebind("throttle_up", up)
	_expect(InputMap.action_has_event("throttle_up", up), "rebind adds the new key")
	_expect(not _has_physical_key("throttle_up", KEY_W), "rebind replaces the old key")
	_expect(_has_device("throttle_up", SiegeInput.Device.GAMEPAD), "rebind keeps the gamepad binding")
	SiegeInput.reset_defaults()
	SiegeInput.rebind("throttle_up", up)
	InputMap.action_erase_events("throttle_up")
	SiegeInput.load_bindings()
	_expect(InputMap.action_has_event("throttle_up", up), "the rebinding survives save + load")
	SiegeInput.reset_defaults()
	_expect(_has_physical_key("throttle_up", KEY_W) and not InputMap.action_has_event("throttle_up", up),
		"reset_defaults restores W")


## QA #16: Z (torso_center) for throttle_stop is a conflict in the battle context; swap gives
## torso_center throttle_stop's X, clear just takes Z away; other contexts may share a control.
func _check_rebind_conflicts() -> void:
	print("rebinding conflicts:")
	SiegeInput.reset_defaults()
	for action in SiegeInput.action_names():
		for ev in InputMap.action_get_events(action):
			var clash: Array = SiegeInput.find_conflicts(action, ev)
			_expect(clash.is_empty(), "default %s / %s has no conflict %s" % [action, BindingText.make_event_text(ev), clash])
	var z := _make_key(KEY_Z)
	_expect(SiegeInput.find_conflicts("throttle_stop", z) == ["torso_center"], "Z for throttle_stop conflicts with torso_center")
	_expect(SiegeInput.find_conflicts("viewer_cell_state", _make_key(KEY_T)).is_empty(), "T in the viewer does not conflict with battle targeting")
	_expect(SiegeInput.find_conflicts("menu_back", _make_key(KEY_ESCAPE)).is_empty(), "Esc: menu_back and menu_pause live in different contexts")
	SiegeInput.rebind_swapping("throttle_stop", z, ["torso_center"])
	_expect(InputMap.action_has_event("throttle_stop", z) and _has_physical_key("torso_center", KEY_X)
		and not _has_physical_key("torso_center", KEY_Z), "swap: throttle_stop gets Z, torso_center gets X")
	SiegeInput.reset_defaults()
	SiegeInput.rebind_clearing("throttle_stop", z, ["torso_center"])
	_expect(InputMap.action_has_event("throttle_stop", z) and not _has_device("torso_center", SiegeInput.Device.KEYBOARD_MOUSE)
		and _has_device("torso_center", SiegeInput.Device.GAMEPAD), "clear: torso_center loses Z, keeps its pad binding")
	SiegeInput.reset_defaults()


static func _make_key(code: Key) -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = code
	k.physical_keycode = code
	return k


func _has_physical_key(action: String, key: Key) -> bool:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey and ev.physical_keycode == key:
			return true
	return false


# ------------------------------------------------------------------ driving a Herc

func _check_battle_controls() -> void:
	print("battle controls:")
	battle = load("res://games/es1/battle.tscn").instantiate()
	var cfg := Battle.default_config("es1:RAPTOR")
	cfg["ai"] = []
	battle.config = cfg
	add_child(battle)
	await _wait(1.0)
	var p := battle.player
	_expect(p != null, "the battle has a player Herc")
	if p == null:
		return
	await _check_throttle_and_turn(p)
	await _check_fire_groups(p)
	await _check_targeting_and_view(p)


func _check_throttle_and_turn(p: Herc) -> void:
	var t0 := p.throttle
	await _hold_action("throttle_up")
	_expect(p.throttle > t0 + 0.05, "throttle_up action raises the throttle (%.2f -> %.2f)" % [t0, p.throttle])
	_send_physical_key(KEY_X, true)
	_send_physical_key(KEY_X, false)
	await _wait(0.05)
	_expect(is_zero_approx(p.throttle), "X (throttle_stop) stops")
	_send_physical_key(KEY_W, true)
	await _wait(TICK)
	_send_physical_key(KEY_W, false)
	_expect(p.throttle > 0.05, "W key raises the throttle (%.2f)" % p.throttle)
	var t1 := p.throttle
	_send_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)
	await _wait(TICK)
	_send_axis(JOY_AXIS_TRIGGER_LEFT, 0.0)
	_expect(p.throttle < t1 - 0.05, "left trigger lowers the throttle (%.2f -> %.2f)" % [t1, p.throttle])
	_send_axis(JOY_AXIS_LEFT_X, -1.0)
	await _wait(TICK)
	_expect(p.turn < -0.9, "left stick turns left (turn %.2f)" % p.turn)
	_send_axis(JOY_AXIS_LEFT_X, 0.0)
	await _wait(TICK)
	_expect(is_zero_approx(p.turn), "centred stick stops turning")
	var yaw0: float = battle.pilot.aim_yaw
	_send_axis(JOY_AXIS_RIGHT_X, 1.0)
	await _wait(TICK)
	_send_axis(JOY_AXIS_RIGHT_X, 0.0)
	_expect(battle.pilot.aim_yaw < yaw0, "right stick twists the torso (%.2f -> %.2f)" % [yaw0, battle.pilot.aim_yaw])


func _check_fire_groups(p: Herc) -> void:
	_send_button(JOY_BUTTON_RIGHT_SHOULDER, true)
	await _wait(TICK)
	_expect(_group_triggered(p, 0), "RB fires group 1")
	_send_button(JOY_BUTTON_RIGHT_SHOULDER, false)
	await _wait(TICK)
	_expect(not _group_triggered(p, 0), "releasing RB stops group 1")
	_send_action("fire_group_2", true)
	await _wait(TICK)
	_expect(_group_triggered(p, 1) or not _has_group(p, 1), "fire_group_2 action fires group 2")
	_send_action("fire_group_2", false)
	await _wait(TICK)


func _check_targeting_and_view(p: Herc) -> void:
	var xf := p.global_transform.translated(-p.global_transform.basis.z * 150.0)
	var enemy := battle.spawn_ai("es1:SCORPION", 1, xf, [], "Dummy", {"skill": 0.0})
	enemy.set_physics_process(false)
	await _wait(0.1)
	_send_button(JOY_BUTTON_Y, true)
	_send_button(JOY_BUTTON_Y, false)
	await _wait(0.05)
	_expect(p.target == enemy, "Y (target_next) targets the enemy")
	var chase := battle.use_chase
	_send_button(JOY_BUTTON_BACK, true)
	_send_button(JOY_BUTTON_BACK, false)
	await _wait(0.05)
	_expect(battle.use_chase != chase, "Back (view_toggle) switches the view")
	_send_action("menu_pause", true)
	_send_action("menu_pause", false)
	await _wait(0.05)
	_expect(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "menu_pause frees the mouse")


## The Call of Duty / Hunt pad layout on foot: X interact (E on the keyboard, boarding folded in), Y weapon swap,
## the raid's inventory and exfil as holds (HeldAction); loot_pickup is gone.
func _check_pad_layout() -> void:
	print("pad layout:")
	_expect(_is_bound("interact", _make_pad(JOY_BUTTON_X)), "pad X is interact")
	_expect(_is_bound("interact", _make_key(KEY_E)), "E is interact")
	_expect(_is_bound("weapon_next", _make_pad(JOY_BUTTON_Y)), "pad Y is weapon_next")
	_expect(not _is_bound("weapon_next", _make_pad(JOY_BUTTON_X)), "pad X no longer swaps weapons")
	_expect(not InputMap.has_action("loot_pickup"), "loot_pickup is unified into interact")
	_expect(not BindingContexts.CONTEXTS.infantry.has("vehicle_enter_exit"), "on foot boarding is folded into interact")


## A version 1 user://input.json (loot_pickup, weapon_next on pad X) loads with interact and the new pad defaults.
func _check_v1_migration() -> void:
	var v1 := {"loot_pickup": [{"type": "key", "keycode": KEY_L, "physical_keycode": KEY_L},
			{"type": "joy_button", "button": JOY_BUTTON_PADDLE1}],
		"weapon_next": [{"type": "key", "keycode": KEY_Q, "physical_keycode": KEY_Q},
			{"type": "joy_button", "button": JOY_BUTTON_X}]}
	var out := SiegeInput.make_migrated_v1(v1)
	_expect(out.has("interact") and not out.has("loot_pickup"), "v1 loot_pickup becomes interact")
	_expect((out.interact as Array).any(func(d): return int(d.get("keycode", 0)) == KEY_L), "v1: the player's loot key is kept")
	_expect((out.weapon_next as Array).any(func(d): return str(d.type) == "joy_button" and int(d.button) == JOY_BUTTON_Y),
		"v1: weapon_next moves to pad Y")
	_expect(not (out.weapon_next as Array).any(func(d): return str(d.type) == "joy_button" and int(d.button) == JOY_BUTTON_X),
		"v1: weapon_next leaves pad X")


static func _is_bound(action: String, ev: InputEvent) -> bool:
	return BindingContexts.find_matching(action, ev) != null


static func _make_pad(button: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.device = -1
	return e


# ------------------------------------------------------------------ shell menus by gamepad

func _check_shell_navigation() -> void:
	print("shell navigation:")
	battle.queue_free()
	if not ShellData.available():
		print("  skip (no shell data)")
		return
	EsShell.booted = true   # straight to the main menu
	var shell: EsShell = load("res://es1_shell.tscn").instantiate()
	add_child(shell)
	await _wait(0.3)
	_expect(shell.top() != null and shell.top().id == EsShell.MAIN_MENU, "the shell shows the main menu")
	_send_button(JOY_BUTTON_DPAD_DOWN, true)
	_send_button(JOY_BUTTON_DPAD_DOWN, false)
	await _wait(0.05)
	_expect(not shell.top().highlighted().is_empty(), "d-pad highlights a button")
	shell.top().hover = shell.top().controls.find(shell.top().find(EsShell.SINGLE_MENU))
	_send_button(JOY_BUTTON_A, true)
	_send_button(JOY_BUTTON_A, false)
	await _wait(0.1)
	_expect(shell.top().id == EsShell.SINGLE_MENU, "A opens the highlighted SINGLE MISSION")
	_send_button(JOY_BUTTON_B, true)
	_send_button(JOY_BUTTON_B, false)
	await _wait(0.1)
	_expect(shell.top().id == EsShell.MAIN_MENU, "B goes back to the main menu")
	shell.queue_free()


static func _has_group(p: Herc, group: int) -> bool:
	return p.weapons.any(func(w): return w.group == group)


static func _group_triggered(p: Herc, group: int) -> bool:
	return p.weapons.any(func(w): return w.group == group and w.trigger)


# ------------------------------------------------------------------ synthetic events

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _hold_action(action: String) -> void:
	_send_action(action, true)
	await _wait(TICK)
	_send_action(action, false)


static func _send_action(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)


static func _send_physical_key(key: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	ev.pressed = pressed
	Input.parse_input_event(ev)


static func _send_axis(axis: JoyAxis, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	Input.parse_input_event(ev)


static func _send_button(button: JoyButton, pressed: bool) -> void:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.pressure = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)

extends Node
## The project's one input map (autoload "SiegeInput"), see docs/CODING_STANDARDS.md §2.
##
## At startup every action of the table below is registered with its default keyboard / mouse and
## gamepad bindings (an action that already exists, e.g. from project.godot, keeps its own events),
## then the player's rebinding is loaded from user://input.json. Gameplay and UI code only ask
## Input / InputEvent about these action names; the helpers below cover the analog reads.

## In the current store (UserStore).
var SETTINGS_FILE: String:
	get: return UserStore.path("input.json")
const SETTINGS_VERSION := 2
## Version 1 files: the extraction "loot_pickup" became "interact", and these actions' gamepad defaults moved
## (the Call of Duty / Hunt layout: X interact, Y weapon swap); their saved gamepad events are replaced.
const RENAMED_ACTIONS_V1 := {"loot_pickup": "interact"}
## Gamepad holds (HeldAction, "tap = the button's own action, hold = another"): held action -> [tap action whose
## pad button is held, seconds]. The keyboard keeps its own key for the held action.
const HELD_ACTIONS := {"inventory_toggle": ["interact", 0.5], "exfil_call": ["torso_center", 1.0],
	"command_map": ["view_toggle", 0.5]}
## Gamepad chords (ChordAction): chord action -> the pad buttons held together. The keyboard has its own key for
## the action; no single pad button is free on foot, so the pad fires it from LB + RB (docs/design/lobby_loadout_economy.md §11).
const CHORD_ACTIONS := {"callin_menu": [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]}
const MOVED_PAD_ACTIONS_V1 := ["weapon_next", "interact", "inventory_toggle", "exfil_call"]
const STICK_DEADZONE := 0.2
const TRIGGER_DEADZONE := 0.1
const DEFAULT_MOUSE_SENSITIVITY := 0.0025   # radians per mouse pixel (torso twist / pitch)
const STICK_LOOK_RATE := 2.0                # radians per second at full right-stick deflection
const SCREENSHOT_DIR := "user://screenshots"
const ANY_DEVICE := -1                      # InputMap matches events from every device

enum Device { KEYBOARD_MOUSE, GAMEPAD }

## Menu actions Godot already defines; only gamepad extras are added to them.
const BUILTIN_UI_ACTIONS := ["ui_accept", "ui_cancel", "ui_up", "ui_down", "ui_left", "ui_right"]

## Mouse sensitivity for mouse look (saved with the bindings).
var mouse_sensitivity := DEFAULT_MOUSE_SENSITIVITY
## The device the player touched last: battle code uses it to allow firing without mouse capture.
var last_device: Device = Device.KEYBOARD_MOUSE


func _enter_tree() -> void:
	register_defaults()
	load_bindings()


func _input(event: InputEvent) -> void:
	_track_device(event)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("screenshot"):
		save_screenshot()


# ------------------------------------------------------------------ the action table

## action -> [keyboard / mouse events..., gamepad events...], deadzone from make_deadzone().
func make_default_bindings() -> Dictionary:
	return {
		"menu_back": [_key(KEY_ESCAPE), _joy_button(JOY_BUTTON_B)],
		"menu_pause": [_key(KEY_ESCAPE), _joy_button(JOY_BUTTON_START)],
		"menu_scroll_up": [_mouse_button(MOUSE_BUTTON_WHEEL_UP)],
		"menu_scroll_down": [_mouse_button(MOUSE_BUTTON_WHEEL_DOWN)],
		"ui_click": [_mouse_button(MOUSE_BUTTON_LEFT)],
		"menu_secondary": [_mouse_button(MOUSE_BUTTON_RIGHT), _joy_button(JOY_BUTTON_X)],
		"menu_info": [_key(KEY_F1), _joy_button(JOY_BUTTON_Y)],
		"menu_tab_prev": [_key_with(KEY_PAGEUP, KEY_MASK_CTRL), _joy_button(JOY_BUTTON_LEFT_SHOULDER)],
		"menu_tab_next": [_key_with(KEY_PAGEDOWN, KEY_MASK_CTRL), _joy_button(JOY_BUTTON_RIGHT_SHOULDER)],
		"menu_zone_prev": [_key_with(KEY_TAB, KEY_MASK_SHIFT), _joy_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)],
		"menu_zone_next": [_key(KEY_TAB), _joy_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)],
		"menu_switch_kind": [_key(KEY_V), _joy_button(JOY_BUTTON_BACK)],
		"menu_primary": [_key_with(KEY_ENTER, KEY_MASK_CTRL), _joy_button(JOY_BUTTON_START)],
		"callin_menu": [_key(KEY_L)],
		"throttle_up": [_physical_key(KEY_W), _joy_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)],
		"throttle_down": [_physical_key(KEY_S), _joy_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)],
		"throttle_stop": [_physical_key(KEY_X), _joy_button(JOY_BUTTON_LEFT_STICK)],
		"turn_left": [_physical_key(KEY_A), _joy_axis(JOY_AXIS_LEFT_X, -1.0)],
		"turn_right": [_physical_key(KEY_D), _joy_axis(JOY_AXIS_LEFT_X, 1.0)],
		"aim_left": [_joy_axis(JOY_AXIS_RIGHT_X, -1.0)],
		"aim_right": [_joy_axis(JOY_AXIS_RIGHT_X, 1.0)],
		"aim_up": [_joy_axis(JOY_AXIS_RIGHT_Y, -1.0)],
		"aim_down": [_joy_axis(JOY_AXIS_RIGHT_Y, 1.0)],
		"torso_center": [_physical_key(KEY_Z), _joy_button(JOY_BUTTON_RIGHT_STICK)],
		"ascend": [_physical_key(KEY_SPACE), _joy_button(JOY_BUTTON_A)],
		"descend": [_physical_key(KEY_CTRL), _joy_button(JOY_BUTTON_X)],
		"fire_group_1": [_mouse_button(MOUSE_BUTTON_LEFT), _joy_button(JOY_BUTTON_RIGHT_SHOULDER)],
		"fire_group_2": [_mouse_button(MOUSE_BUTTON_RIGHT), _joy_button(JOY_BUTTON_LEFT_SHOULDER)],
		"jet": [_mouse_button(MOUSE_BUTTON_RIGHT), _joy_button(JOY_BUTTON_LEFT_SHOULDER)],
		"weapon_next": [_physical_key(KEY_Q), _joy_button(JOY_BUTTON_Y)],
		"vehicle_enter_exit": [_physical_key(KEY_E), _joy_button(JOY_BUTTON_B)],
		"seat_next": [_physical_key(KEY_F), _joy_button(JOY_BUTTON_DPAD_LEFT)],
		"grenade_throw": [_physical_key(KEY_G), _joy_button(JOY_BUTTON_DPAD_UP)],
		"mine_drop": [_physical_key(KEY_B), _joy_button(JOY_BUTTON_DPAD_DOWN)],
		"pack_use": [_physical_key(KEY_R), _joy_button(JOY_BUTTON_DPAD_RIGHT)],
		"repair_kit_use": [_physical_key(KEY_H), _joy_button(JOY_BUTTON_LEFT_STICK)],
		"scope_zoom": [_mouse_button(MOUSE_BUTTON_MIDDLE), _joy_button(JOY_BUTTON_PADDLE1)],
		"scope_level": [_physical_key(KEY_X), _joy_button(JOY_BUTTON_PADDLE2)],
		"interact": [_physical_key(KEY_E), _joy_button(JOY_BUTTON_X)],
		"inventory_toggle": [_physical_key(KEY_I)],
		"exfil_call": [_physical_key(KEY_O)],
		"target_next": [_key(KEY_T), _joy_button(JOY_BUTTON_Y)],
		"target_nearest": [_key(KEY_C)],
		"view_toggle": [_key(KEY_V), _joy_button(JOY_BUTTON_BACK)],
		"scoreboard": [_key(KEY_TAB)],
		"objectives_toggle": [_key(KEY_J)],
		"command_map": [_key(KEY_N)],
		"missile_cam_toggle": [_key(KEY_M)],
		"cockpit_mode_1": [_key(KEY_F1)],
		"cockpit_mode_2": [_key(KEY_F2)],
		"cockpit_mode_3": [_key(KEY_F3)],
		"cockpit_mode_4": [_key(KEY_F4)],
		"cockpit_mode_5": [_key(KEY_F5)],
		"cockpit_mode_6": [_key(KEY_F6)],
		"radar_mode_toggle": [_key(KEY_SEMICOLON)],
		"cloak_toggle": [_key_with(KEY_X, KEY_MASK_CTRL)],
		"cockpit_mode_next": [_joy_button(JOY_BUTTON_DPAD_RIGHT)],
		"hdd_page_1": [_key(KEY_F7)],
		"hdd_page_2": [_key(KEY_F8)],
		"look_up": [_key(KEY_PAGEUP), _key(KEY_KP_8), _joy_button(JOY_BUTTON_DPAD_UP)],
		"look_down": [_key(KEY_PAGEDOWN), _key(KEY_KP_2), _joy_button(JOY_BUTTON_DPAD_DOWN)],
		"look_left": [_key(KEY_KP_4)],
		"look_right": [_key(KEY_KP_6)],
		"orbit": [_mouse_button(MOUSE_BUTTON_LEFT), _mouse_button(MOUSE_BUTTON_RIGHT)],
		"orbit_left": [_physical_key(KEY_Q), _joy_axis(JOY_AXIS_RIGHT_X, -1.0)],
		"orbit_right": [_physical_key(KEY_E), _joy_axis(JOY_AXIS_RIGHT_X, 1.0)],
		"orbit_up": [_physical_key(KEY_R), _joy_axis(JOY_AXIS_RIGHT_Y, -1.0)],
		"orbit_down": [_physical_key(KEY_F), _joy_axis(JOY_AXIS_RIGHT_Y, 1.0)],
		"zoom_in": [_mouse_button(MOUSE_BUTTON_WHEEL_UP), _joy_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)],
		"zoom_out": [_mouse_button(MOUSE_BUTTON_WHEEL_DOWN), _joy_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)],
		"viewer_next_lod": [_key(KEY_L)],
		"viewer_cell_state": [_key(KEY_C)],
		"viewer_interpolation": [_key(KEY_I)],
		"chat_all": [_key(KEY_ENTER), _key(KEY_KP_ENTER)],
		"chat_team": [_key(KEY_Y)],
		"chat_quick": [_key(KEY_K), _joy_button(JOY_BUTTON_MISC1)],
		"chat_history": [_key(KEY_U)],
		"chat_send": [_key(KEY_ENTER), _key(KEY_KP_ENTER)],
		"chat_cancel": [_key(KEY_ESCAPE), _joy_button(JOY_BUTTON_B)],
		"chat_scroll_up": [_mouse_button(MOUSE_BUTTON_WHEEL_UP), _key(KEY_PAGEUP), _joy_axis(JOY_AXIS_RIGHT_Y, -1.0)],
		"chat_scroll_down": [_mouse_button(MOUSE_BUTTON_WHEEL_DOWN), _key(KEY_PAGEDOWN), _joy_axis(JOY_AXIS_RIGHT_Y, 1.0)],
		"chat_channel_next": [_key(KEY_TAB), _joy_button(JOY_BUTTON_Y)],
		"screenshot": [_key(KEY_F12)],
		"debug_toggle": [_key(KEY_F10)],
	}


## Gamepad extras for Godot's own ui_* actions (left stick next to the d-pad).
func make_builtin_ui_extras() -> Dictionary:
	return {
		"ui_accept": [_joy_button(JOY_BUTTON_A)],
		"ui_cancel": [_joy_button(JOY_BUTTON_B)],
		"ui_up": [_joy_button(JOY_BUTTON_DPAD_UP), _joy_axis(JOY_AXIS_LEFT_Y, -1.0)],
		"ui_down": [_joy_button(JOY_BUTTON_DPAD_DOWN), _joy_axis(JOY_AXIS_LEFT_Y, 1.0)],
		"ui_left": [_joy_button(JOY_BUTTON_DPAD_LEFT), _joy_axis(JOY_AXIS_LEFT_X, -1.0)],
		"ui_right": [_joy_button(JOY_BUTTON_DPAD_RIGHT), _joy_axis(JOY_AXIS_LEFT_X, 1.0)],
	}


static func make_deadzone(action: String) -> float:
	var is_trigger := action.begins_with("throttle_") or action.begins_with("zoom_") or action.begins_with("menu_zone_")
	return TRIGGER_DEADZONE if is_trigger else STICK_DEADZONE


## Every action this script owns (the table above), in table order.
func action_names() -> Array:
	return make_default_bindings().keys()


# ------------------------------------------------------------------ registration / rebinding

## Adds every missing action with its default events, and the gamepad extras to the ui_* actions.
func register_defaults() -> void:
	var defaults := make_default_bindings()
	for action in defaults:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, make_deadzone(action))
		for ev in defaults[action]:
			InputMap.action_add_event(action, ev)
	_add_builtin_ui_extras()


func _add_builtin_ui_extras() -> void:
	var extras := make_builtin_ui_extras()
	for action in extras:
		if not InputMap.has_action(action):
			InputMap.add_action(action, STICK_DEADZONE)
		for ev in extras[action]:
			if not InputMap.action_has_event(action, ev):
				InputMap.action_add_event(action, ev)


## Binds `event` to `action`, replacing the action's old binding on the same device
## (keyboard / mouse or gamepad), and saves the result.
func rebind(action: String, event: InputEvent) -> void:
	if not InputMap.has_action(action):
		push_error("SiegeInput.rebind: unknown action '%s'" % action)
		return
	var device := device_of(event)
	for old in InputMap.action_get_events(action):
		if device_of(old) == device:
			InputMap.action_erase_event(action, old)
	InputMap.action_add_event(action, event)
	save_bindings()


## The other actions sharing a context with `action` that `event` already triggers (empty: no
## conflict). Contexts: BindingContexts.
func find_conflicts(action: String, event: InputEvent) -> Array:
	var out := []
	for other in BindingContexts.make_peers(action):
		if other != action and InputMap.has_action(other) and BindingContexts.find_matching(other, event) != null:
			out.append(other)
	return out


## Binds `event` to `action`; the first of `others` (the conflicting actions) gets the control
## `action` used on that device instead, the rest lose `event`.
func rebind_swapping(action: String, event: InputEvent, others: Array) -> void:
	var previous := _find_on_device(action, device_of(event))
	rebind_clearing(action, event, others)
	if previous != null and not others.is_empty():
		InputMap.action_add_event(str(others[0]), previous)
		save_bindings()


## Binds `event` to `action` and removes it from `others` (the conflicting actions).
func rebind_clearing(action: String, event: InputEvent, others: Array) -> void:
	for other in others:
		var taken := BindingContexts.find_matching(str(other), event)
		if taken != null:
			InputMap.action_erase_event(str(other), taken)
	rebind(action, event)


func _find_on_device(action: String, device: Device) -> InputEvent:
	for ev in InputMap.action_get_events(action):
		if device_of(ev) == device:
			return ev
	return null


## Restores every action of the table to its default events and saves.
func reset_defaults() -> void:
	var defaults := make_default_bindings()
	for action in defaults:
		InputMap.action_erase_events(action)
		for ev in defaults[action]:
			InputMap.action_add_event(action, ev)
	mouse_sensitivity = DEFAULT_MOUSE_SENSITIVITY
	save_bindings()


static func device_of(event: InputEvent) -> Device:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return Device.GAMEPAD
	return Device.KEYBOARD_MOUSE


# ------------------------------------------------------------------ user://input.json

func save_bindings() -> void:
	var bindings := {}
	for action in action_names():
		var events := []
		for ev in InputMap.action_get_events(action):
			var d := make_event_dict(ev)
			if not d.is_empty():
				events.append(d)
		bindings[action] = events
	var f := FileAccess.open(SETTINGS_FILE, FileAccess.WRITE)
	if f == null:
		push_error("SiegeInput: cannot write %s" % SETTINGS_FILE)
		return
	f.store_string(JSON.stringify({"version": SETTINGS_VERSION, "mouse_sensitivity": mouse_sensitivity,
		"bindings": bindings}, " "))


func load_bindings() -> void:
	if not FileAccess.file_exists(SETTINGS_FILE):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_FILE))
	var version := int(data.get("version", 0)) if data is Dictionary else 0
	if version != SETTINGS_VERSION and version != 1:
		push_error("SiegeInput: ignoring unreadable %s" % SETTINGS_FILE)
		return
	mouse_sensitivity = float(data.get("mouse_sensitivity", DEFAULT_MOUSE_SENSITIVITY))
	var bindings: Dictionary = data.get("bindings", {})
	if version == 1:
		bindings = make_migrated_v1(bindings)
	for action in bindings:
		if InputMap.has_action(action) and bindings[action] is Array:
			_apply_saved_events(action, bindings[action])


## Version 1 bindings in today's names, with the moved actions' gamepad events back at their new defaults.
func make_migrated_v1(bindings: Dictionary) -> Dictionary:
	var out := {}
	for action in bindings:
		out[RENAMED_ACTIONS_V1.get(action, action)] = bindings[action]
	var defaults := make_default_bindings()
	for action in MOVED_PAD_ACTIONS_V1:
		if not (out.get(action) is Array):
			continue
		var kept := (out[action] as Array).filter(func(d) -> bool: return not str(d.get("type", "")).begins_with("joy_"))
		for ev in defaults[action]:
			if device_of(ev) == Device.GAMEPAD:
				kept.append(make_event_dict(ev))
		out[action] = kept
	return out


func _apply_saved_events(action: String, saved: Array) -> void:
	InputMap.action_erase_events(action)
	for d in saved:
		var ev := make_event(d)
		if ev:
			InputMap.action_add_event(action, ev)


## InputEvent -> JSON-friendly dictionary ({} for event types that are not bindable).
static func make_event_dict(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		var d := {"type": "key", "keycode": int(ev.keycode), "physical_keycode": int(ev.physical_keycode)}
		if ev.get_modifiers_mask() != 0:
			d["modifiers"] = int(ev.get_modifiers_mask())
		return d
	if ev is InputEventMouseButton:
		return {"type": "mouse_button", "button": int(ev.button_index)}
	if ev is InputEventJoypadButton:
		return {"type": "joy_button", "button": int(ev.button_index)}
	if ev is InputEventJoypadMotion:
		return {"type": "joy_axis", "axis": int(ev.axis), "value": float(ev.axis_value)}
	return {}


## Inverse of make_event_dict(); null for unknown entries.
static func make_event(d: Dictionary) -> InputEvent:
	match str(d.get("type", "")):
		"key":
			var k := InputEventKey.new()
			k.keycode = int(d.get("keycode", 0)) as Key
			k.physical_keycode = int(d.get("physical_keycode", 0)) as Key
			k.device = ANY_DEVICE
			_apply_modifiers(k, int(d.get("modifiers", 0)))
			return k
		"mouse_button":
			return _mouse_button(int(d.get("button", 0)))
		"joy_button":
			return _joy_button(int(d.get("button", 0)))
		"joy_axis":
			return _joy_axis(int(d.get("axis", 0)), float(d.get("value", 1.0)))
	return null


# ------------------------------------------------------------------ analog helpers

## Right-stick look for this frame (radians): x = yaw right, y = pitch down.
func make_stick_look(delta: float) -> Vector2:
	return Input.get_vector("aim_left", "aim_right", "aim_up", "aim_down") * STICK_LOOK_RATE * delta


## Mouse look from a motion event (radians): x = yaw right, y = pitch down.
func make_mouse_look(event: InputEventMouseMotion) -> Vector2:
	return event.relative * mouse_sensitivity


## Raw aim deflection (-1..1 per axis, no rate): x = right, y = down. Flyers use it as a stick.
func make_aim_axes() -> Vector2:
	return Input.get_vector("aim_left", "aim_right", "aim_up", "aim_down")


## -1 (descend) .. 1 (ascend) flyer climb input.
func make_lift_axis() -> float:
	return Input.get_axis("descend", "ascend")


## -1 (left) .. 1 (right) turn input, analog on a stick.
func make_turn_axis() -> float:
	return Input.get_axis("turn_left", "turn_right")


## Throttle change per second as a fraction of full: + up, - down (analog on the triggers).
func make_throttle_axis() -> float:
	return Input.get_axis("throttle_down", "throttle_up")


## Orbit input from the right stick for this frame: x = yaw, y = pitch.
func make_stick_orbit(delta: float) -> Vector2:
	return Input.get_vector("orbit_left", "orbit_right", "orbit_up", "orbit_down") * STICK_LOOK_RATE * delta


## True while the player uses a gamepad (the mouse need not be captured to fire).
func is_gamepad_active() -> bool:
	return last_device == Device.GAMEPAD


func _track_device(event: InputEvent) -> void:
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > STICK_DEADZONE):
		last_device = Device.GAMEPAD
	elif event is InputEventKey or event is InputEventMouseButton:
		last_device = Device.KEYBOARD_MOUSE


## Saves the current frame to user://screenshots/ (the `screenshot` action).
func save_screenshot() -> void:
	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	var path := "%s/shot_%d.png" % [SCREENSHOT_DIR, Time.get_unix_time_from_system()]
	get_viewport().get_texture().get_image().save_png(path)
	print("screenshot: ", ProjectSettings.globalize_path(path))


# ------------------------------------------------------------------ event factories

static func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.device = ANY_DEVICE
	return ev


static func _physical_key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.device = ANY_DEVICE
	return ev


## A key with modifiers (`modifiers` = KeyModifierMask bits, e.g. KEY_MASK_CTRL).
static func _key_with(code: Key, modifiers: int) -> InputEventKey:
	var ev := _key(code)
	_apply_modifiers(ev, modifiers)
	return ev


static func _apply_modifiers(ev: InputEventKey, modifiers: int) -> void:
	ev.shift_pressed = (modifiers & KEY_MASK_SHIFT) != 0
	ev.ctrl_pressed = (modifiers & KEY_MASK_CTRL) != 0
	ev.alt_pressed = (modifiers & KEY_MASK_ALT) != 0
	ev.meta_pressed = (modifiers & KEY_MASK_META) != 0


static func _mouse_button(button: int) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button as MouseButton
	ev.device = ANY_DEVICE
	return ev


static func _joy_button(button: int) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button as JoyButton
	ev.device = ANY_DEVICE
	return ev


static func _joy_axis(axis: int, direction: float) -> InputEventJoypadMotion:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis as JoyAxis
	ev.axis_value = direction
	ev.device = ANY_DEVICE
	return ev

class_name BindingText
## Short human-readable names for input bindings and actions (options screen).

const MOUSE_BUTTONS := {
	MOUSE_BUTTON_LEFT: "Mouse left", MOUSE_BUTTON_RIGHT: "Mouse right", MOUSE_BUTTON_MIDDLE: "Mouse middle",
	MOUSE_BUTTON_WHEEL_UP: "Wheel up", MOUSE_BUTTON_WHEEL_DOWN: "Wheel down",
}
const JOY_BUTTONS := {
	JOY_BUTTON_A: "Pad A", JOY_BUTTON_B: "Pad B", JOY_BUTTON_X: "Pad X", JOY_BUTTON_Y: "Pad Y",
	JOY_BUTTON_BACK: "Pad Back", JOY_BUTTON_START: "Pad Start", JOY_BUTTON_LEFT_STICK: "Pad LS click",
	JOY_BUTTON_RIGHT_STICK: "Pad RS click", JOY_BUTTON_LEFT_SHOULDER: "Pad LB", JOY_BUTTON_RIGHT_SHOULDER: "Pad RB",
	JOY_BUTTON_DPAD_UP: "D-pad up", JOY_BUTTON_DPAD_DOWN: "D-pad down", JOY_BUTTON_DPAD_LEFT: "D-pad left",
	JOY_BUTTON_DPAD_RIGHT: "D-pad right", JOY_BUTTON_MISC1: "Pad Share",
	JOY_BUTTON_PADDLE1: "Pad paddle 1", JOY_BUTTON_PADDLE2: "Pad paddle 2", JOY_BUTTON_PADDLE3: "Pad paddle 3",
}
const JOY_AXES := {
	JOY_AXIS_LEFT_X: ["Left stick left", "Left stick right"], JOY_AXIS_LEFT_Y: ["Left stick up", "Left stick down"],
	JOY_AXIS_RIGHT_X: ["Right stick left", "Right stick right"], JOY_AXIS_RIGHT_Y: ["Right stick up", "Right stick down"],
	JOY_AXIS_TRIGGER_LEFT: ["LT", "LT"], JOY_AXIS_TRIGGER_RIGHT: ["RT", "RT"],
}
const SEPARATOR := ",  "


## "W,  RT" for every event bound to `action`: keyboard and mouse first, then the gamepad
## (whatever order rebinding left them in). A held action (SiegeInput HELD_ACTIONS) adds its pad hold:
## "I,  hold Pad X (0.5 s)" - the pad button of its tap action.
static func make_action_bindings(action: String) -> String:
	if not InputMap.has_action(action):
		return "(not registered)"
	var parts := PackedStringArray()
	var pad_parts := PackedStringArray()
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
			pad_parts.append(make_event_text(ev))
		else:
			parts.append(make_event_text(ev))
	parts.append_array(pad_parts)
	var hold := make_hold_text(action)
	if hold != "":
		parts.append(hold)
	return SEPARATOR.join(parts) if not parts.is_empty() else "(unbound)"


## {held action: [tap action, seconds]} (SiegeInput HELD_ACTIONS; {} when it has none).
static func make_held_actions() -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var input: Node = tree.root.get_node_or_null("/root/SiegeInput") if tree != null else null
	if input == null or input.get_script() == null:
		return {}
	var held = input.get_script().get_script_constant_map().get("HELD_ACTIONS", {})
	return held if held is Dictionary else {}


## "hold Pad X (0.5 s)" for a held action, "" for any other.
static func make_hold_text(action: String) -> String:
	var held := make_held_actions()
	if not held.has(action):
		return ""
	var tap := str(held[action][0])
	if not InputMap.has_action(tap):
		return ""
	for ev in InputMap.action_get_events(tap):
		if ev is InputEventJoypadButton:
			return "hold %s (%s s)" % [make_event_text(ev), str(held[action][1])]
	return ""


static func make_event_text(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		return OS.get_keycode_string(code)
	if ev is InputEventMouseButton:
		return MOUSE_BUTTONS.get((ev as InputEventMouseButton).button_index, ev.as_text())
	if ev is InputEventJoypadButton:
		return JOY_BUTTONS.get((ev as InputEventJoypadButton).button_index, ev.as_text())
	if ev is InputEventJoypadMotion:
		var m := ev as InputEventJoypadMotion
		var names: Array = JOY_AXES.get(m.axis, [ev.as_text(), ev.as_text()])
		return names[1] if m.axis_value > 0.0 else names[0]
	return ev.as_text()


## "fire_group_1" -> "Fire group 1".
static func make_action_name(action: String) -> String:
	return action.replace("_", " ").capitalize()

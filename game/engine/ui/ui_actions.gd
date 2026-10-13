class_name UiActions
## Input-action queries and focus wiring shared by every app screen. Screens ask about named
## actions only (docs/CODING_STANDARDS.md section 2); an action SiegeInput has not registered yet
## reads as "not pressed" instead of raising InputMap errors.

const BACK := "menu_back"
const BACK_FALLBACK := "ui_cancel"


## True when `event` presses `action` (unknown actions are never pressed).
static func is_pressed(event: InputEvent, action: String) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action, false, true)


## True when `event` releases `action`.
static func is_released(event: InputEvent, action: String) -> bool:
	return InputMap.has_action(action) and event.is_action_released(action, true)


## Analog strength of `action` carried by `event` (0 for unknown actions or other events).
static func strength(event: InputEvent, action: String) -> float:
	if not InputMap.has_action(action) or not event.is_action(action, true):
		return 0.0
	return event.get_action_strength(action, true)


## `menu_back` leaves a screen; `ui_cancel` stands in until SiegeInput registers `menu_back`.
static func is_back(event: InputEvent) -> bool:
	if InputMap.has_action(BACK):
		return is_pressed(event, BACK)
	return is_pressed(event, BACK_FALLBACK)


## Visible, enabled, focusable controls under `root`, in tree (reading) order.
static func focusables(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	for child in root.get_children():
		var c := child as Control
		if c == null or not c.visible:
			continue
		if c.focus_mode == Control.FOCUS_ALL and not _is_disabled(c):
			out.append(c)
		out.append_array(focusables(c))
	return out


## Links `chain` top-to-bottom: up/down and Tab / Shift+Tab walk the list in order.
static func link_vertical(chain: Array[Control]) -> void:
	for i in chain.size():
		var c := chain[i]
		var prev := chain[i - 1] if i > 0 else c
		var next := chain[i + 1] if i + 1 < chain.size() else c
		c.focus_neighbor_top = c.get_path_to(prev)
		c.focus_neighbor_bottom = c.get_path_to(next)
		c.focus_previous = c.get_path_to(prev)
		c.focus_next = c.get_path_to(next)


## Links `chain` left-to-right (a row of buttons).
static func link_horizontal(chain: Array[Control]) -> void:
	for i in chain.size():
		var c := chain[i]
		c.focus_neighbor_left = c.get_path_to(chain[i - 1] if i > 0 else c)
		c.focus_neighbor_right = c.get_path_to(chain[i + 1] if i + 1 < chain.size() else c)


static func _is_disabled(c: Control) -> bool:
	return c is BaseButton and (c as BaseButton).disabled

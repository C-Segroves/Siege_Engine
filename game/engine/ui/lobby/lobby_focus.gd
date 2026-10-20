class_name LobbyFocus
extends RefCounted
## Keyboard and gamepad movement over the lobby's zones (docs/design/lobby_loadout_economy.md section 5.5): Game Options,
## Operator Setup, the carousel, the others list, the task list, the chat and the footer (and the narrow tab bar).
## `ui_*` walks the controls of a zone in order and on into the next zone; `menu_zone_next` / `menu_zone_prev` (Tab,
## Shift+Tab, pad RT / LT) jump to the first control of the next / previous zone. A zone is an Array[Control].


## Links every zone's controls in reading order (up/down/left/right and Tab order), and the end of a zone to the next.
static func link(zones: Array) -> void:
	var chain: Array[Control] = []
	for zone in zones:
		var controls: Array[Control] = []
		controls.assign(zone)
		UiActions.link_horizontal(controls)
		chain.append_array(controls)
	UiActions.link_vertical(chain)


## The zones' visible, enabled controls only (zones that are hidden or empty drop out).
static func make_live_zones(zones: Array) -> Array:
	var out := []
	for zone in zones:
		var live := (zone as Array).filter(func(c: Variant) -> bool:
			return is_instance_valid(c) and c.is_visible_in_tree() and c.focus_mode == Control.FOCUS_ALL and not (c is BaseButton and c.disabled))
		if not live.is_empty():
			out.append(live)
	return out


## The index of the zone holding `control` (-1 when none).
static func find_zone(zones: Array, control: Control) -> int:
	for i in zones.size():
		if (zones[i] as Array).has(control):
			return i
	return -1


## Focuses the first control of the zone `delta` zones from the one holding the focus (wraps).
static func jump(zones: Array, current: Control, delta: int) -> void:
	if zones.is_empty():
		return
	var at := find_zone(zones, current)
	var target := posmod(at + delta, zones.size()) if at >= 0 else (0 if delta > 0 else zones.size() - 1)
	((zones[target] as Array)[0] as Control).grab_focus()

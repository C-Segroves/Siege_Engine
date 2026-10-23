class_name BindingContexts
## Which input actions are live at the same time (docs/CODING_STANDARDS.md section 2): one control
## may not be bound twice inside a context - rebinding warns and offers to swap or clear
## (SiegeInput.find_conflicts, the options screen). The same control may serve several contexts
## (Esc: menu_back in menus, menu_pause in battle; wheel: menu scroll and hangar zoom; C: target
## nearest in battle, cell state in the shape viewer; Enter: open the chat in battle, send it in the chat).

const CONTEXTS := {
	## The shared actions of the loadout and lobby screens: secondary (remove, rename) on mouse right / pad X,
	## info (pin the tooltip), tab and zone jumps, infantry / vehicle switch, the footer primary action. Tab and
	## Shift+Tab are two controls (the modifier counts, is_same_control); handlers ask with exact_match (UiActions).
	"menus": ["ui_click", "menu_back", "menu_scroll_up", "menu_scroll_down", "menu_secondary", "menu_info",
		"menu_tab_prev", "menu_tab_next", "menu_zone_prev", "menu_zone_next", "menu_switch_kind", "menu_primary",
		"orbit_left", "orbit_right", "orbit_up", "orbit_down"],
	"battle": ["menu_pause", "throttle_up", "throttle_down", "throttle_stop", "turn_left", "turn_right",
		"aim_left", "aim_right", "aim_up", "aim_down", "torso_center", "ascend", "descend", "fire_group_1",
		"fire_group_2", "target_next", "target_nearest", "view_toggle", "scoreboard", "cockpit_mode_1",
		"cockpit_mode_2", "cockpit_mode_3", "cockpit_mode_4", "cockpit_mode_5", "cockpit_mode_6",
		"cockpit_mode_next", "radar_mode_toggle", "cloak_toggle", "hdd_page_1", "hdd_page_2", "look_up", "look_down", "look_left", "look_right", "vehicle_enter_exit", "structure_repair", "seat_next", "objectives_toggle", "missile_cam_toggle", "command_map", "chat_all",
		"chat_team", "chat_quick", "chat_history"],
	## On foot (Tribes armour) and in a passenger seat: boarding is folded into interact (E, pad X: the nearest
	## thing in reach - an item, a loot cache, a switch, a vehicle hatch; InfantryInteraction), so
	## vehicle_enter_exit (E, pad B: getting out) belongs to the battle context only; on foot its pad B still
	## boards. jet shares the right mouse button / LB with fire_group_2
	## of the battle context, interact the pad X with descend, weapon_next the pad Y with target_next (a soldier
	## has no target lock; T still cycles targets on foot), the gear actions the d-pad with the cockpit views and
	## repair_kit_use the left stick click with throttle_stop - a soldier never needs both at once. On the pad,
	## inventory_toggle is a hold of interact (X), exfil_call a hold of torso_center (right stick click) and
	## command_map a hold of view_toggle (Back; in a vehicle too). The Laser Rifle scope (RifleScope): scope_zoom is
	## held (the original IDACTION_SNIPER_FOV / toggleZoom), scope_level steps the magnification (IDACTION_INC_SNIPER_FOV
	## / setZoomFOV); the originals' E / Z and A / T are the interact / torso_center and strafe / target keys here, so
	## the middle mouse button and X (throttle_stop is not an infantry action) carry them, the pad's back paddles:
	## HeldAction, tap = the button's own action. callin_menu (extraction call-ins) is L, and on the pad the chord
	## LB + RB (ChordAction): every single pad button is taken on foot.
	"infantry": ["menu_pause", "throttle_up", "throttle_down", "turn_left", "turn_right", "aim_left",
		"aim_right", "aim_up", "aim_down", "torso_center", "ascend", "jet", "fire_group_1", "weapon_next",
		"view_toggle", "scoreboard", "objectives_toggle", "seat_next",
		"grenade_throw", "mine_drop", "pack_use", "repair_kit_use", "chat_all", "chat_team", "chat_quick", "chat_history",
		"interact", "inventory_toggle", "exfil_call", "command_map", "scope_zoom", "scope_level", "callin_menu"],
	## While the chat is open (typing, the quick-chat menu, the history): the battle and infantry actions are
	## suspended (BattleChat holds the player's controls), so the chat may reuse their controls.
	"chat": ["chat_send", "chat_cancel", "chat_scroll_up", "chat_scroll_down", "chat_channel_next"],
	"viewer": ["orbit", "orbit_left", "orbit_right", "orbit_up", "orbit_down", "zoom_in", "zoom_out",
		"viewer_next_lod", "viewer_cell_state", "viewer_interpolation"],
}
## Actions live in every context.
const GLOBAL_ACTIONS := ["screenshot", "debug_toggle"]


## Every action live at the same time as `action` (its contexts plus the global actions).
static func make_peers(action: String) -> Array:
	var peers := GLOBAL_ACTIONS.duplicate()
	for context in CONTEXTS:
		var members: Array = CONTEXTS[context]
		if members.has(action) or GLOBAL_ACTIONS.has(action):
			for a in members:
				if not peers.has(a):
					peers.append(a)
	return peers


## The event of `action` that is the same control as `event` (null when none).
static func find_matching(action: String, event: InputEvent) -> InputEvent:
	for ev in InputMap.action_get_events(action):
		if is_same_control(ev, event):
			return ev
	return null


## True when `a` and `b` are the same key / button / stick direction. Mouse and pad modifiers are ignored
## (InputEvent.is_match ignores an axis' direction unless asked for exact modifiers too); two keys must also
## carry the same modifiers (Tab and Shift+Tab are two controls).
static func is_same_control(a: InputEvent, b: InputEvent) -> bool:
	if not a.is_match(b, false):
		return false
	if a is InputEventKey and b is InputEventKey:
		return make_key_modifiers(a) == make_key_modifiers(b)
	if a is InputEventJoypadMotion and b is InputEventJoypadMotion:
		return signf((a as InputEventJoypadMotion).axis_value) == signf((b as InputEventJoypadMotion).axis_value)
	return true


## The modifier bits a key event needs besides the key itself (pressing Ctrl alone carries the Ctrl bit: not counted).
static func make_key_modifiers(ev: InputEventKey) -> int:
	var code := ev.physical_keycode if ev.physical_keycode != KEY_NONE else ev.keycode
	var own := {KEY_SHIFT: KEY_MASK_SHIFT, KEY_CTRL: KEY_MASK_CTRL, KEY_ALT: KEY_MASK_ALT, KEY_META: KEY_MASK_META}
	return ev.get_modifiers_mask() & ~int(own.get(code, 0))

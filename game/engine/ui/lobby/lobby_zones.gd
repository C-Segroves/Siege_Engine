class_name LobbyZones
extends RefCounted
## The lobby's focus zones in reading order (docs/design/lobby_loadout_economy.md section 5.5): the narrow tab bar, Game
## Options, Operator Setup, the carousel, the others list, the task list, the chat and the footer. LobbyFocus links and
## jumps over them; this lists which controls belong to which zone.


## One Array of controls per zone, in order (zones with nothing to focus are dropped by LobbyFocus.make_live_zones).
static func make_zones(screen: LobbyScreen, footer: Array) -> Array:
	var tabs: Array = screen.layout.tab_buttons.values().filter(func(b: Button) -> bool: return screen.layout.narrow and b.visible)
	var cards: Array = [screen.carousel.mode_button, screen.carousel.prev_button, screen.carousel.ring, screen.carousel.next_button]
	for card in screen.carousel.make_visible_cards():
		cards.append_array(card.make_focusables())
	return [tabs, UiActions.focusables(screen.options), UiActions.focusables(screen.setup), cards,
		[screen.list.filter, screen.list.tree], UiActions.focusables(screen.tasks_scroll), [screen.chat.line_edit, screen.chat.quick_button], footer]

class_name TeamCarousel
extends VBoxContainer
## The pilot's own squad (docs/design/lobby_loadout_economy.md section 5.3): his own member first, then his squadmates,
## computer-controlled members and (campaign) wingmen. A 3D ring (TeamRing) shows them on platforms, one mode at a time
## (everybody's infantry or everybody's vehicle, the mode button / `menu_switch_kind` toggles it), the focused member
## in front under one spotlight; beneath it the OperatorCards of the members in view (name, ready, warnings, the part of
## the current mode). The large arrows on the stage, the page dots and the lobby screen's `menu_tab_prev` / `menu_tab_next`
## (pad LB / RB) turn the arc. Cards are kept by key and updated in place, so focus survives a roster change.
##   refresh(cards, team_choices)      cards: LobbyCards dictionaries, the local pilot's first
##   ready_toggled(on) / team_picked(team) / card_edit(card_key)   what the local card or a wingman card asks for

signal ready_toggled(on: bool)
signal team_picked(team: int)
signal card_edit(card_key: String)

const DOT_ON := "o"
const DOT_OFF := "."

var visible_count := 1
var ring: TeamRing
var mode_button: Button
var mode := TeamRing.MODE_INFANTRY
var focus_index := 0
var prev_button: Button
var next_button: Button
var _header: Label
var _row: HBoxContainer
var _dots: Label
var _team_choices: Array = []
var _cards := {}          # key -> OperatorCard
var _order: Array = []    # keys in display order
var _spacers: Array[Control] = []   # empty slots after the last card, so a lone card keeps the width of one of three


func _init() -> void:
	_header = Widgets.section("")
	add_child(_header)
	ring = TeamRing.new()
	add_child(ring)
	mode_button = Widgets.small_button("", toggle_mode)
	mode_button.tooltip_text = "Show the team's vehicles or infantry (V / pad View)"
	ring.add_corner(mode_button)
	_apply_mode_text()
	prev_button = _make_arrow("<", "menu_tab_prev", -1)
	next_button = _make_arrow(">", "menu_tab_next", 1)
	ring.add_arrows(prev_button, next_button)
	_row = HBoxContainer.new()
	_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_row)
	_dots = Widgets.label("", "DimLabel")
	_dots.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_dots)


## A large arrow for the stage: the arrow over the pad shoulder that does the same ("<" over "LB"); the tooltip lists every binding.
func _make_arrow(arrow: String, action: String, delta: int) -> Button:
	var b := Widgets.small_button(arrow, func() -> void: step(delta))
	var hint := _make_pad_hint(action)
	b.text = arrow + ("
" + hint if hint != "" else "")
	b.tooltip_text = "%s member (%s)" % ["Previous" if delta < 0 else "Next", BindingText.make_action_bindings(action)]
	b.focus_mode = Control.FOCUS_ALL
	return b


## "LB" for an action bound to the left shoulder ("" when no pad button is bound).
static func _make_pad_hint(action: String) -> String:
	if not InputMap.has_action(action):
		return ""
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton:
			return BindingText.make_event_text(ev).trim_prefix("Pad ")
	return ""


func set_header(text: String) -> void:
	_header.text = text


## A narrow window gets a lower ring.
func set_narrow(on: bool) -> void:
	ring.set_compact(on)


## Switches the whole ring between the team's infantry and the team's vehicles; the focused member stays.
func toggle_mode() -> void:
	apply_mode(TeamRing.MODE_VEHICLE if mode == TeamRing.MODE_INFANTRY else TeamRing.MODE_INFANTRY)


func apply_mode(new_mode: String) -> void:
	mode = new_mode
	ring.set_mode(new_mode)
	_apply_mode_text()
	for key in _cards:
		(_cards[key] as OperatorCard).apply(_cards[key].data, _team_choices if bool(_cards[key].data.get("you", false)) else [], mode)


func _apply_mode_text() -> void:
	mode_button.text = "Show vehicles" if mode == TeamRing.MODE_INFANTRY else "Show infantry"


## Shows `cards`; `team_choices` ([{team, name}]) feeds the local card's team picker.
func refresh(cards: Array, team_choices := []) -> void:
	var keys := cards.map(func(c: Dictionary) -> String: return str(c.key))
	for key in _cards.keys():
		if not keys.has(key):
			_remove_card(key)
	for card_data in cards:
		var card: OperatorCard = _cards.get(str(card_data.key))
		if card == null:
			card = _add_card(str(card_data.key))
		card.apply(card_data, team_choices if bool(card_data.you) else [], mode)
	for i in cards.size():
		_row.move_child(_cards[keys[i]], i)
	_order = keys
	focus_index = clampi(focus_index, 0, maxi(_order.size() - 1, 0))
	_team_choices = team_choices
	ring.set_members(cards)
	_apply_window()


func _add_card(key: String) -> OperatorCard:
	var card := OperatorCard.new()
	card.ready_toggled.connect(func(on: bool) -> void: ready_toggled.emit(on))
	card.team_picked.connect(func(team: int) -> void: team_picked.emit(team))
	card.gui_input.connect(_on_card_input.bind(card))
	_row.add_child(card)
	_cards[key] = card
	return card


func _remove_card(key: String) -> void:
	_cards[key].queue_free()
	_cards.erase(key)


func card_count() -> int:
	return _order.size()


func card_for(key: String) -> OperatorCard:
	return _cards.get(key)


## Cards currently shown, left to right.
func make_visible_cards() -> Array:
	return _order.slice(_window_start(), _window_start() + visible_count).map(func(k: String) -> OperatorCard: return _cards[k])


## Moves the focus by `delta` members round the ring: past the last member comes the first again.
func step(delta: int) -> void:
	focus_index = posmod(focus_index + delta, _order.size()) if not _order.is_empty() else 0
	_apply_window()
	var shown := make_visible_cards()
	if not shown.is_empty() and not has_focus_inside():
		(shown[0] as Control).grab_focus()


func has_focus_inside() -> bool:
	var owner_control := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	return owner_control != null and is_ancestor_of(owner_control)


## The first card of the window: the selected card sits in its middle when the window allows.
func _window_start() -> int:
	var start := focus_index - visible_count / 2
	return clampi(start, 0, maxi(_order.size() - visible_count, 0))


func _apply_window() -> void:
	var start := _window_start()
	for i in _order.size():
		_cards[_order[i]].visible = i >= start and i < start + visible_count
	_apply_spacers(maxi(visible_count - (mini(_order.size(), start + visible_count) - start), 0))
	ring.set_focus(focus_index)
	prev_button.disabled = false   # a ring: the arrows wrap round
	next_button.disabled = false
	prev_button.visible = _order.size() > 1
	next_button.visible = prev_button.visible
	_dots.visible = _order.size() > 1
	_dots.text = " ".join(range(_order.size()).map(func(i: int) -> String: return DOT_ON if i == focus_index else DOT_OFF))


func _apply_spacers(count: int) -> void:
	while _spacers.size() > count:
		_spacers.pop_back().queue_free()
	while _spacers.size() < count:
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_row.add_child(spacer)
		_spacers.append(spacer)


func _on_card_input(event: InputEvent, card: OperatorCard) -> void:
	if UiActions.is_pressed(event, "menu_secondary") or UiActions.is_pressed(event, "ui_accept"):
		if str(card.data.get("kind", "")) == LobbyWingmen.KIND:
			card.accept_event()
			card_edit.emit(card.key)

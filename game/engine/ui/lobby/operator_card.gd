class_name OperatorCard
extends PanelContainer
## One operator of the squad in the lobby carousel (docs/design/lobby_loadout_economy.md section 5.3): name, team
## colour bar, ping, ready dot, an infantry card and a vehicle card, and for the card of the local pilot the ready
## check box and (team match) the team picker. Shows what LobbyCards made; takes focus so a pad can step onto it.
##   card.apply(data)          update in place (focus stays)
##   ready_toggled(on)         the local pilot's Ready box changed
##   team_picked(team)         the local pilot picked a team

signal ready_toggled(on: bool)
signal team_picked(team: int)

const BAR_WIDTH := 8.0
const READY_TEXT := "READY"
const NOT_READY_TEXT := "not ready"
const HOST_TEXT := "HOST"

var key := ""
var data := {}
var ready_box: CheckBox
var team_picker: OptionButton
var _bar: ColorRect
var _name: Label
var _ping: Label
var _dot: PanelContainer
var _infantry_title: Label
var _infantry_text: Label
var _infantry_detail: Label
var _vehicle_title: Label
var _vehicle_text: Label
var _vehicle_detail: Label
var _state: Label
var _note: Label
var _warning: Label
var _building := false
var _choices_key := ""


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	custom_minimum_size = Vector2(Widgets.metric("button_width") * 0.6, 0)
	var box := VBoxContainer.new()
	add_child(box)
	box.add_child(_build_header())
	_infantry_title = _add_line(box, "DimLabel")
	_infantry_text = _add_line(box, "")
	_infantry_detail = _add_line(box, "DimLabel")
	_vehicle_title = _add_line(box, "DimLabel")
	_vehicle_text = _add_line(box, "")
	_vehicle_detail = _add_line(box, "DimLabel")
	box.add_child(_build_footer())
	_note = _add_line(box, "DimLabel")
	_warning = _add_line(box, "BadgeNotAllowed")
	focus_entered.connect(_refresh_look)
	focus_exited.connect(_refresh_look)


func _build_header() -> Control:
	var row := HBoxContainer.new()
	_bar = ColorRect.new()
	_bar.custom_minimum_size = Vector2(BAR_WIDTH, 0)
	row.add_child(_bar)
	_name = Widgets.label("", "SectionLabel")
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.clip_text = true
	row.add_child(_name)
	_ping = Widgets.label("", "DimLabel")
	row.add_child(_ping)
	_dot = PanelContainer.new()
	_dot.custom_minimum_size = Vector2(Widgets.metric("font_size_body"), Widgets.metric("font_size_body"))
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_dot)
	return row


func _build_footer() -> Control:
	var row := HBoxContainer.new()
	_state = Widgets.label("", "StatusLabel")
	_state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_state)
	ready_box = Widgets.check_box(READY_TEXT.capitalize(), false)
	ready_box.toggled.connect(func(on: bool) -> void:
		if not _building:
			ready_toggled.emit(on))
	row.add_child(ready_box)
	team_picker = OptionButton.new()
	team_picker.clip_text = true
	team_picker.custom_minimum_size = Vector2(TeamList.PICKER_WIDTH, 0)
	team_picker.item_selected.connect(func(i: int) -> void:
		if not _building:
			team_picked.emit(team_picker.get_item_id(i) - TeamList.PICKER_ID_OFFSET))
	row.add_child(team_picker)
	return row


static func _add_line(parent: Control, variation: String) -> Label:
	var l := Widgets.label("", variation)
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


## Shows `card_data` (LobbyCards). `team_choices` is [{team, name}] for the local pilot's picker (empty = no picker).
func apply(card_data: Dictionary, team_choices := [], part_mode := TeamRing.MODE_INFANTRY) -> void:
	_building = true
	data = card_data
	key = str(card_data.key)
	_name.text = str(card_data.name)
	_ping.text = str(card_data.ping)
	_bar.color = card_data.team_color
	_bar.visible = bool(card_data.team_visible)
	var show_infantry := part_mode == TeamRing.MODE_INFANTRY   # one mode at a time: the ring shows the same one
	_apply_part(_infantry_title, _infantry_text, _infantry_detail, card_data.infantry if show_infantry else {})
	_apply_part(_vehicle_title, _vehicle_text, _vehicle_detail, {} if show_infantry else card_data.vehicle)
	_apply_ready(card_data)
	_apply_team_picker(card_data, team_choices)
	_note.text = str(card_data.note)
	_note.visible = _note.text != ""
	_warning.text = str(card_data.get("warning", ""))
	_warning.visible = _warning.text != ""
	_refresh_look()
	_building = false


## The local pilot's card and the card with focus use the selected look.
func _refresh_look() -> void:
	theme_type_variation = "CardPanelSelected" if bool(data.get("you", false)) or has_focus() else "CardPanel"


func _apply_part(title: Label, text: Label, detail: Label, part: Dictionary) -> void:
	var shown: bool = str(part.get("text", "")) != ""
	title.visible = shown
	text.visible = shown
	detail.visible = shown and str(part.get("detail", "")) != ""
	title.text = str(part.get("title", ""))
	text.text = str(part.get("text", ""))
	detail.text = str(part.get("detail", ""))


func _apply_ready(card_data: Dictionary) -> void:
	_dot.theme_type_variation = "ReadyDot" if card_data.ready else "ReadyDotOff"
	var own_box: bool = bool(card_data.you) and not bool(card_data.host)
	ready_box.visible = own_box
	ready_box.button_pressed = bool(card_data.ready)
	_state.visible = not own_box
	_state.text = HOST_TEXT if card_data.host else (READY_TEXT if card_data.ready else NOT_READY_TEXT)
	if card_data.kind != LobbyModel.PILOT_KIND:
		_state.text = str(card_data.get("state", ""))


func _apply_team_picker(card_data: Dictionary, team_choices: Array) -> void:
	team_picker.visible = bool(card_data.you) and not team_choices.is_empty()
	if not team_picker.visible:
		return
	var key := JSON.stringify(team_choices)
	if key != _choices_key:   # refilled only when the teams change: an open picker stays open
		_choices_key = key
		team_picker.clear()
		for c in team_choices:
			team_picker.add_icon_item(TeamList._make_swatch_icon(TeamList.make_team_color(int(c.team))), str(c.name),
				int(c.team) + TeamList.PICKER_ID_OFFSET)
	team_picker.select(team_picker.get_item_index(int(card_data.team) + TeamList.PICKER_ID_OFFSET))


## The controls on the card that take focus, in reading order (the card itself first).
func make_focusables() -> Array[Control]:
	var out: Array[Control] = [self]
	for c: Control in [ready_box, team_picker]:
		if c.is_visible_in_tree():
			out.append(c)
	return out

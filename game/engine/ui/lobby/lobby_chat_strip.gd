class_name LobbyChatStrip
extends VBoxContainer
## The lobby's chat (docs/design/lobby_loadout_economy.md section 5): the last lines, a line to type into (Enter sends,
## "/t " before the text says it to the team) and a Quick button with the canned lines of the battle's quick chat, which
## a gamepad can pick (`chat_quick` opens it). Lines travel through LobbyChatHub. `chat_all` (Enter) focuses the line
## while nothing else takes the key.

const LINE_PLACEHOLDER := "type here (Enter)"
const TEAM_PREFIX := "/t "
const QUICK_TEXT := "Quick"
const MIN_LOG_HEIGHT := 70.0
const MAX_QUICK_LINES := 14

var log_view: RichTextLabel
var line_edit: LineEdit
var quick_button: MenuButton
var hub: LobbyChatHub
var _quick_lines: Array = []


func _init() -> void:
	log_view = RichTextLabel.new()
	log_view.scroll_following = true
	log_view.selection_enabled = false
	log_view.focus_mode = Control.FOCUS_NONE
	log_view.custom_minimum_size = Vector2(0, MIN_LOG_HEIGHT)
	log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(log_view)
	var row := HBoxContainer.new()
	line_edit = Widgets.line_edit("", LINE_PLACEHOLDER)
	line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line_edit.max_length = ChatLog.MAX_TEXT_LENGTH
	line_edit.text_submitted.connect(_on_submitted)
	row.add_child(line_edit)
	quick_button = MenuButton.new()
	quick_button.text = QUICK_TEXT
	quick_button.flat = false
	_fill_quick_menu()
	quick_button.get_popup().id_pressed.connect(_on_quick_picked)
	row.add_child(quick_button)
	add_child(row)


func _ready() -> void:
	hub = LobbyChatHub.ensure(get_tree())
	hub.line_received.connect(_on_line)
	for line in hub.history:
		_show(line.channel, line.sender, line.text)


func _fill_quick_menu() -> void:
	var popup := quick_button.get_popup()
	for category in QuickChat.load_menu():
		for item in category.items:
			if _quick_lines.size() >= MAX_QUICK_LINES:
				return
			popup.add_item("%s: %s" % [category.name, item.label], _quick_lines.size())
			_quick_lines.append(item)


func _on_quick_picked(id: int) -> void:
	var item: Dictionary = _quick_lines[id]
	hub.say(ChatChannels.TEAM if bool(item.team) and LobbySettings.is_team_match(Net.settings) else ChatChannels.ALL, str(item.text))


func _on_submitted(text: String) -> void:
	var channel := ChatChannels.ALL
	if text.begins_with(TEAM_PREFIX):
		channel = ChatChannels.TEAM
		text = text.substr(TEAM_PREFIX.length())
	hub.say(channel, text)
	line_edit.clear()


func _on_line(channel: String, sender: String, text: String) -> void:
	_show(channel, sender, text)


func _show(channel: String, sender: String, text: String) -> void:
	var color := ChatChannels.color_of(channel)
	var who := "" if sender == "" else "[%s] " % sender
	log_view.push_color(color)
	log_view.add_text("%s%s%s\n" % ["(team) " if channel == ChatChannels.TEAM else "", who, text])
	log_view.pop()


## Focuses the line to type into.
func open_typing() -> void:
	line_edit.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if UiActions.is_pressed(event, "chat_all"):
		get_viewport().set_input_as_handled()
		open_typing()
	elif UiActions.is_pressed(event, "chat_quick"):
		get_viewport().set_input_as_handled()
		quick_button.get_popup().popup_centered()

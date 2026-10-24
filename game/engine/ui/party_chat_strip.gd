class_name PartyChatStrip
extends VBoxContainer
## The party's chat: the last lines, a line to type into (Enter sends) and a Quick button with the canned lines of the lobby's
## quick chat, which a gamepad can pick. The lines travel through the party service
## (PartyClient.say), so they also reach a member who is away on a raid and show when he comes back.

const LINE_PLACEHOLDER := "type here (Enter)"
const MIN_LOG_HEIGHT := 90.0
const QUICK_TEXT := "Quick"
const MAX_QUICK_LINES := 14
const SYSTEM_COLOR := Color(0.7, 0.8, 0.9)
const SAY_COLOR := Color(0.9, 0.9, 0.85)

var log_view: RichTextLabel
var line_edit: LineEdit
var quick_button: MenuButton
var _client: PartyClient
var _quick_lines: Array = []
var _shown := 0


func _init(p_client: PartyClient) -> void:
	_client = p_client
	add_child(Widgets.section("Chat"))
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
	line_edit.max_length = PartyRegistry.MAX_CHAT_TEXT
	line_edit.text_submitted.connect(_on_submitted)
	row.add_child(line_edit)
	quick_button = MenuButton.new()
	quick_button.text = QUICK_TEXT
	quick_button.flat = false
	_fill_quick_menu()
	quick_button.get_popup().id_pressed.connect(func(id: int) -> void: _client.say(str(_quick_lines[id].text)))
	row.add_child(quick_button)
	add_child(row)
	_client.changed.connect(refresh)
	refresh()


func _exit_tree() -> void:
	if _client.changed.is_connected(refresh):
		_client.changed.disconnect(refresh)


## Shows the lines that arrived since the last call.
func refresh() -> void:
	while _shown < _client.chat.size():
		var line: Dictionary = _client.chat[_shown]
		_shown += 1
		var who := "" if str(line.name) == "" else "[%s] " % line.name
		log_view.push_color(SYSTEM_COLOR if str(line.name) == "" else SAY_COLOR)
		log_view.add_text("%s%s\n" % [who, line.text])
		log_view.pop()


func _fill_quick_menu() -> void:
	var popup := quick_button.get_popup()
	for category in QuickChat.load_menu():
		for item in category.items:
			if _quick_lines.size() >= MAX_QUICK_LINES:
				return
			popup.add_item("%s: %s" % [category.name, item.label], _quick_lines.size())
			_quick_lines.append(item)


func _on_submitted(text: String) -> void:
	if text.strip_edges() != "":
		_client.say(text)
	line_edit.clear()

class_name ChatPanel
extends Control
## The chat panel of every battle, in every game, cockpit, HUD and on foot (docs/formats/cockpit.md section
## 9.6): the remake's own window, not bound to any original HUD's message line.
##
## Closed, it shows the newest `visible_lines` lines of the channels the filters show, each fading out
## `fade_seconds` after it arrived. Open, it shows `history_lines` of the full history with scrollback
## (chat_scroll_up / chat_scroll_down: wheel, PgUp / PgDn, right stick), the channel filter tabs and, while
## typing, the input line. Modes: typing (chat_all / chat_team; Enter sends, Esc cancels, Tab switches all /
## team), the quick-chat menu (chat_quick, QuickChatMenu) and the history (chat_history), which is also the
## edit mode: drag the title strip to move the panel, the corner grip to resize it (saved as the "custom"
## position, ChatSettings). While open the panel takes every key and button event (the battle holds the
## player's controls, BattleChat); the mouse is free.
## Placement: ChatPlacement with the HUD's occupied rects from `occupied_provider`.

signal say_requested(channel: String, text: String)
signal opened
signal closed

enum Mode { CLOSED, TYPING, QUICK, HISTORY }

const PAD := 6.0
const LINE_GAP := 4.0
const FADE_OUT_SECONDS := 1.5
const OPEN_MIN_OPACITY := 0.35
## The open panel is at least this wide, so the filter tabs and the scroll notes fit (it may then cover HUD
## windows while open; the closed panel never does).
const OPEN_MIN_WIDTH := 480.0
const GRIP_SIZE := 14.0
const SETTINGS_POLL_SECONDS := 0.5
const QUICK_MENU_GAP := 8.0
const BACKGROUND := Color(0.02, 0.04, 0.05)
const OUTLINE := Color(0.0, 0.0, 0.0, 0.85)
const OUTLINE_SIZE := 3
const DIM := Color(0.7, 0.75, 0.7)
const MORE_ABOVE := "^%d"
const NEWER_BELOW := "v%d"
const TITLE := "CHAT"

var chat_log: ChatLog
var settings := ChatSettings.make_defaults()
var mode := Mode.CLOSED
## The channel typed lines go to (ChatChannels.SPOKEN).
var channel := ChatChannels.ALL
## Wrapped lines scrolled back from the newest.
var scroll := 0
## () -> Array of screen Rect2 the HUD in use draws into ([]: none).
var occupied_provider := Callable()
var quick_menu: Array = []

var _tabs: HBoxContainer
var _input_row: HBoxContainer
var _line: ChatInputLine
var _channel_label: Label
var _quick: QuickChatMenu
var _closed_rect := Rect2()
var _placement_key := []
var _drag := ""                     # "", "move" or "resize"
var _drag_from := Vector2.ZERO
var _drag_start := {}
var _settings_t := 0.0


func _init(p_log: ChatLog) -> void:
	chat_log = p_log
	name = "ChatPanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	settings = ChatSettings.load_settings()
	quick_menu = QuickChat.load_menu()
	_build_tabs()
	_build_input_row()
	_apply_mode_controls()


func _build_tabs() -> void:
	_tabs = HBoxContainer.new()
	var title := Widgets.label(TITLE, "DimLabel")
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tabs.add_child(title)
	for c in ChatChannels.ORDER:
		var b := Widgets.small_button(ChatChannels.label_of(c), func() -> void: pass)
		b.toggle_mode = true
		b.button_pressed = bool(settings.filters.get(c, true))
		b.toggled.connect(func(on: bool) -> void: apply_filter(c, on))
		_tabs.add_child(b)
	add_child(_tabs)


func _build_input_row() -> void:
	_input_row = HBoxContainer.new()
	_channel_label = Widgets.label("")
	_input_row.add_child(_channel_label)
	_line = ChatInputLine.new()
	_input_row.add_child(_line)
	add_child(_input_row)


# ------------------------------------------------------------------ opening and closing

func is_open() -> bool:
	return mode != Mode.CLOSED


## Opens the input line for `p_channel` (ChatChannels.ALL / TEAM).
func open_typing(p_channel: String) -> void:
	channel = p_channel
	_set_mode(Mode.TYPING)
	_line.text = ""
	_refresh_channel_label()
	_line.grab_focus()


func open_quick() -> void:
	_set_mode(Mode.QUICK)
	_quick = QuickChatMenu.new(quick_menu)
	_quick.picked.connect(_on_quick_picked)
	add_child(_quick)


## Opens the full history (and the move / resize handles).
func open_history() -> void:
	_set_mode(Mode.HISTORY)
	grab_focus()


func close() -> void:
	_set_mode(Mode.CLOSED)


func _set_mode(m: Mode) -> void:
	var was_open := is_open()
	if is_instance_valid(_quick):
		_quick.queue_free()
	_quick = null
	mode = m
	scroll = 0
	_drag = ""
	_apply_mode_controls()
	if is_open() and not was_open:
		opened.emit()
	elif not is_open() and was_open:
		closed.emit()


func _apply_mode_controls() -> void:
	var open := is_open()
	mouse_filter = Control.MOUSE_FILTER_STOP if open else Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_ALL if open else Control.FOCUS_NONE
	_tabs.visible = open
	_input_row.visible = mode == Mode.TYPING
	if not open and has_focus():
		release_focus()
	if not open and _line.has_focus():
		_line.release_focus()


func _refresh_channel_label() -> void:
	_channel_label.text = "%s:" % ChatChannels.label_of(channel)


# ------------------------------------------------------------------ settings

## Shows or hides `c`'s lines (and saves it).
func apply_filter(c: String, shown: bool) -> void:
	settings.filters[c] = shown
	scroll = 0
	ChatSettings.apply_filter(c, shown)


## Picks up changes the options screen made (it may be opened from the battle menu).
func _poll_settings(delta: float) -> void:
	_settings_t -= delta
	if _settings_t > 0.0 or _drag != "":
		return
	_settings_t = SETTINGS_POLL_SECONDS
	var fresh := ChatSettings.load_settings()
	if fresh != settings:
		settings = fresh
		for i in ChatChannels.ORDER.size():
			(_tabs.get_child(i + 1) as Button).set_pressed_no_signal(bool(settings.filters.get(ChatChannels.ORDER[i], true)))


func line_height() -> float:
	return float(settings.font_size) + LINE_GAP


func bar_height() -> float:
	return float(Widgets.metric("row_height"))


func make_collapsed_size() -> Vector2:
	return make_closed_size(settings)


## The closed panel's size with settings `s` (ChatSettings).
static func make_closed_size(s: Dictionary) -> Vector2:
	return Vector2(float(s.width), int(s.visible_lines) * (float(s.font_size) + LINE_GAP) + PAD * 2.0)


## The open panel's size: as wide as the closed panel (the automatic place may narrow it) but at least
## OPEN_MIN_WIDTH, history_lines high.
func make_open_size() -> Vector2:
	return Vector2(maxf(_closed_rect.size.x, OPEN_MIN_WIDTH),
		int(settings.history_lines) * line_height() + PAD * 2.0 + bar_height() * 2.0)


## The closed panel's screen rect (where its lines show).
func make_collapsed_rect() -> Rect2:
	return _closed_rect


## The open panel's screen rect: it grows upwards from the closed panel's bottom edge, downwards when there is
## no room above.
func make_open_rect() -> Rect2:
	var c := make_collapsed_rect()
	var s := make_open_size()
	var top := c.end.y - s.y
	if top < 0.0:
		top = c.position.y
	return Rect2(ChatPlacement.make_clamped(Vector2(c.position.x, top), s, get_viewport_rect().size), s)


func grows_upwards() -> bool:
	return make_open_rect().position.y < make_collapsed_rect().position.y


# ------------------------------------------------------------------ frame

func _process(delta: float) -> void:
	_poll_settings(delta)
	_apply_placement()
	var r := make_open_rect() if is_open() else make_collapsed_rect()
	position = r.position
	size = r.size
	_layout_children()
	queue_redraw()


func _apply_placement() -> void:
	if _drag != "":
		return
	var screen := get_viewport_rect().size
	var occupied: Array = occupied_provider.call() if occupied_provider.is_valid() else []
	var custom: Array = settings.custom_pos
	var key := [screen, occupied, settings.position, custom, make_collapsed_size()]
	if key == _placement_key:
		return
	_placement_key = key
	_closed_rect = ChatPlacement.make_rect(str(settings.position), make_collapsed_size(), screen, occupied,
		Vector2(float(custom[0]), float(custom[1])))


func _layout_children() -> void:
	var inner := size.x - PAD * 2.0
	_tabs.position = Vector2(PAD, PAD)
	_tabs.size = Vector2(inner, bar_height())
	_input_row.position = Vector2(PAD, size.y - PAD - bar_height())
	_input_row.size = Vector2(inner, bar_height())
	if is_instance_valid(_quick):
		var screen := get_viewport_rect().size
		var right := position.x + size.x + QUICK_MENU_GAP + _quick.size.x <= screen.x
		var x := size.x + QUICK_MENU_GAP if right else -_quick.size.x - QUICK_MENU_GAP
		var y := clampf(size.y - _quick.size.y, -position.y, screen.y - position.y - _quick.size.y)
		_quick.position = Vector2(x, y)


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	var lines := ChatLines.make_lines(chat_log.make_shown(settings.filters), {"font": get_theme_default_font(),
		"font_size": settings.font_size, "width": size.x - PAD * 2.0, "timestamps": settings.timestamps})
	if is_open():
		_draw_open(lines)
	else:
		_draw_closed(lines)


## The history: `history_lines` lines ending `scroll` lines before the newest, on the panel background.
func _draw_open(lines: Array) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(BACKGROUND, maxf(float(settings.opacity), OPEN_MIN_OPACITY)))
	scroll = clampi(scroll, 0, maxi(lines.size() - int(settings.history_lines), 0))
	var last := lines.size() - scroll
	var first := maxi(last - int(settings.history_lines), 0)
	var y := PAD + bar_height() + PAD
	for i in range(first, last):
		_draw_line(lines[i], y, 1.0)
		y += line_height()
	var notes := PackedStringArray()
	if first > 0:
		notes.append(MORE_ABOVE % first)
	if scroll > 0:
		notes.append(NEWER_BELOW % scroll)
	_draw_note("  ".join(notes), PAD + (bar_height() - line_height()) * 0.5)
	draw_rect(_make_grip_rect(), Color(DIM, 0.6))


## The newest `visible_lines` lines that have not faded out, at the bottom of the closed panel.
func _draw_closed(lines: Array) -> void:
	var now := Time.get_ticks_msec()
	var shown := lines.filter(func(l: Dictionary) -> bool: return make_alpha(int(l.msec), now) > 0.0)
	shown = shown.slice(maxi(shown.size() - int(settings.visible_lines), 0))
	if shown.is_empty():
		return
	var top := size.y - PAD - shown.size() * line_height()
	var strongest := 0.0
	for l in shown:
		strongest = maxf(strongest, make_alpha(int(l.msec), now))
	draw_rect(Rect2(0.0, top - PAD, size.x, size.y - top + PAD), Color(BACKGROUND, float(settings.opacity) * strongest))
	var y := top
	for l in shown:
		_draw_line(l, y, make_alpha(int(l.msec), now))
		y += line_height()


## 1 while a line received at `msec` is younger than fade_seconds, then fading to 0 over FADE_OUT_SECONDS.
func make_alpha(msec: int, now: int) -> float:
	var fade := float(settings.fade_seconds)
	if fade <= 0.0:
		return 1.0
	var age := (now - msec) / 1000.0
	return clampf(1.0 - (age - fade) / FADE_OUT_SECONDS, 0.0, 1.0)


func _draw_line(l: Dictionary, top: float, alpha: float) -> void:
	var font := get_theme_default_font()
	var fs := int(settings.font_size)
	var at := Vector2(PAD, top + font.get_ascent(fs))
	var color := ChatChannels.color_of(str(l.channel))
	var full := str(l.prefix) + str(l.text)
	draw_string_outline(font, at, full, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, OUTLINE_SIZE, Color(OUTLINE, OUTLINE.a * alpha))
	if str(l.prefix) != "":
		draw_string(font, at, l.prefix, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			Color(color.lightened(ChatChannels.SENDER_LIGHTEN), alpha))
		at.x += font.get_string_size(l.prefix, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, at, l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(color, alpha))


## `text` right-aligned in the filter tab row (the scroll position).
func _draw_note(text: String, top: float) -> void:
	var font := get_theme_default_font()
	var fs := int(settings.font_size) - 2
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, Vector2(size.x - PAD - w, top + font.get_ascent(fs)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, DIM)


# ------------------------------------------------------------------ input while open

func _input(event: InputEvent) -> void:
	if is_open() and _apply_chat_action(event):
		get_viewport().set_input_as_handled()


## The chat actions while open (before the GUI, so the input line never sees them); true when `event` was one.
func _apply_chat_action(event: InputEvent) -> bool:
	if UiActions.is_pressed(event, "chat_cancel"):
		if not (mode == Mode.QUICK and _quick.go_back()):
			close()
	elif mode == Mode.TYPING and UiActions.is_pressed(event, "chat_send"):
		_send()
	elif mode == Mode.TYPING and UiActions.is_pressed(event, "chat_channel_next"):
		channel = ChatChannels.make_next_spoken(channel)
		_refresh_channel_label()
	elif UiActions.is_pressed(event, "chat_scroll_up"):
		scroll += 1
	elif UiActions.is_pressed(event, "chat_scroll_down"):
		scroll = maxi(scroll - 1, 0)
	elif (mode == Mode.HISTORY and UiActions.is_pressed(event, "chat_history")) \
			or (mode == Mode.QUICK and UiActions.is_pressed(event, "chat_quick")):
		close()
	else:
		return false
	return true


func _send() -> void:
	var text := ChatLog.make_clean(_line.text)
	close()
	if text != "":
		say_requested.emit(channel, text)


func _on_quick_picked(item: Dictionary) -> void:
	close()
	say_requested.emit(ChatChannels.TEAM if bool(item.get("team", false)) else ChatChannels.ALL, str(item.get("text", "")))


## Keys and buttons nothing inside the panel used stop here, so none reaches the game while the chat is open.
func _gui_input(event: InputEvent) -> void:
	if not is_open():
		return
	_apply_drag_event(event)
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		accept_event()


# ------------------------------------------------------------------ moving and resizing (edit mode)

func _make_grip_rect() -> Rect2:
	var y := 0.0 if grows_upwards() else size.y - GRIP_SIZE
	return Rect2(size.x - GRIP_SIZE, y, GRIP_SIZE, GRIP_SIZE)


func _apply_drag_event(event: InputEvent) -> void:
	if event is InputEventMouseButton and UiActions.is_pressed(event, "ui_click"):
		_start_drag(event as InputEventMouseButton)
	elif event is InputEventMouseButton and UiActions.is_released(event, "ui_click") and _drag != "":
		_finish_drag()
		accept_event()
	elif event is InputEventMouseMotion and _drag != "":
		_apply_drag((event as InputEventMouseMotion).global_position - _drag_from)
		accept_event()


func _start_drag(event: InputEventMouseButton) -> void:
	if _make_grip_rect().has_point(event.position):
		_drag = "resize"
	elif event.position.y < PAD + bar_height():
		_drag = "move"
	else:
		return
	_drag_from = event.global_position
	_drag_start = {"pos": _closed_rect.position, "width": _closed_rect.size.x, "lines": int(settings.history_lines),
		"up": grows_upwards()}
	accept_event()


func _apply_drag(delta: Vector2) -> void:
	var screen := get_viewport_rect().size
	if _drag == "move":
		_closed_rect.position = ChatPlacement.make_clamped(_drag_start.pos + delta, _closed_rect.size, screen)
		return
	settings.width = clampf(_drag_start.width + delta.x, ChatSettings.LIMITS.width.x, ChatSettings.LIMITS.width.y)
	_closed_rect.size.x = settings.width
	var dy := -delta.y if _drag_start.up else delta.y
	var lines := int(_drag_start.lines) + int(round(dy / line_height()))
	settings.history_lines = clampi(lines, int(ChatSettings.LIMITS.history_lines.x), int(ChatSettings.LIMITS.history_lines.y))


## Saves the dragged place (as the "custom" position) or size.
func _finish_drag() -> void:
	var screen := get_viewport_rect().size
	if _drag == "move":
		settings.position = ChatSettings.CUSTOM
		settings.custom_pos = [_closed_rect.position.x / screen.x, _closed_rect.position.y / screen.y]
	_drag = ""
	ChatSettings.save_settings(settings)
	settings = ChatSettings.load_settings()
	_placement_key = []

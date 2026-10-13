extends Node
## Headless check of the battle chat (docs/formats/cockpit.md section 9.6, BattleChat / ChatPanel):
## - history and scrollback: the open panel scrolls back with chat_scroll_up and returns with chat_scroll_down;
## - channel filters hide and show a channel's lines (and are saved);
## - typing (chat_all) frees the mouse, holds the player's controls (W does not throttle; Esc cancels the chat
##   instead of opening the battle menu), puts the keys into the line, chat_send says it to all; closing restores
##   the mouse mode; the quick-chat menu (chat_quick) says a canned line;
## - team routing: a team line reaches only the sender's team; the host's flood guard and length cap;
## - campaign radio lines (Battle.radio) arrive on the radio channel with their speaker;
## - the closed panel's automatic place is clear of the plain HUD's meters;
## - the settings (lines, position, filters) persist in user://settings.json, which is backed up and restored.
##   godot --headless --audio-driver Dummy --path game res://tests/chat_check.tscn

const BATTLE_SCENE := "res://games/es1/battle.tscn"
const PLAYER_VEHICLE := "es1:RAPTOR"
const SETTLE_SECONDS := 1.5
const STEP_FRAMES := 3
const HISTORY_LINES := 40
const TYPED := "wave"
const RADIO_SPEAKER := "Test speaker"
const SETTINGS_FILE := "user://settings.json"
## The smallest window the placement is checked on (the remake's default window).
const MIN_PLACEMENT_SCREEN := Vector2(1280, 800)
const SETTINGS_BACKUP := "user://settings.json.chat_check_backup"

var _fails := 0
var _had_settings := false


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_back_up_settings()
	ChatSettings.reset()
	var b := await _start_battle()
	_check_placement(b)
	await _check_scrollback(b)
	_check_filters(b)
	await _check_typing(b)
	await _check_quick_chat(b)
	_check_team_routing(b)
	_check_rate_limit_and_cap(b)
	await _check_radio(b)
	_check_settings_persist()
	b.queue_free()
	_restore_settings()
	print("chat_check: %s (%d failures)" % ["OK" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# ------------------------------------------------------------------ helpers

func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _frames(n := STEP_FRAMES) -> void:
	for i in n:
		await get_tree().process_frame


func _send_action(action: String) -> void:
	for pressed in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames()


func _send_key(code: Key, unicode := 0) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.unicode = unicode
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames()


func _start_battle() -> Battle:
	var cfg := MatchFlow.make_skirmish_config(PLAYER_VEHICLE, [], MapPicker.config_at(0))
	cfg["ai"] = []
	var b: Battle = load(BATTLE_SCENE).instantiate()
	b.config = cfg
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	return b


func _back_up_settings() -> void:
	_had_settings = FileAccess.file_exists(SETTINGS_FILE)
	if _had_settings:
		DirAccess.copy_absolute(ProjectSettings.globalize_path(SETTINGS_FILE), ProjectSettings.globalize_path(SETTINGS_BACKUP))


func _restore_settings() -> void:
	if _had_settings:
		DirAccess.copy_absolute(ProjectSettings.globalize_path(SETTINGS_BACKUP), ProjectSettings.globalize_path(SETTINGS_FILE))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_BACKUP))
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_FILE))


func _count(b: Battle, channel: String, text := "") -> int:
	return b.overlay.chat_log.entries.filter(func(e: Dictionary) -> bool:
		return e.channel == channel and (text == "" or e.text == text)).size()


# ------------------------------------------------------------------ checks

func _check_placement(b: Battle) -> void:
	var panel := b.chat.panel
	_expect(is_instance_valid(panel) and panel.is_inside_tree(), "the chat panel is on the battle overlay")
	var r := panel.make_collapsed_rect()
	var occupied: Array = b.chat.make_occupied_rects()
	if panel.get_viewport_rect().size.x < MIN_PLACEMENT_SCREEN.x:
		print("skip  auto placement: the headless window is too small (cockpit_coverage_check checks it windowed)")
	else:
		_expect(ChatPlacement.is_clear(r, occupied), "auto placement %s is clear of the HUD's %d rects" % [r, occupied.size()])
	var hud_rects := HUD.make_occupied_rects(MIN_PLACEMENT_SCREEN) + InfantryHud.make_occupied_rects(MIN_PLACEMENT_SCREEN)
	var plain := ChatPlacement.make_free_rect(hud_rects, ChatPanel.make_closed_size(ChatSettings.make_defaults()), MIN_PLACEMENT_SCREEN)
	_expect(ChatPlacement.is_clear(plain, hud_rects), "on a %s window the plain HUD leaves room for the panel at %s" % [MIN_PLACEMENT_SCREEN, plain])
	_expect(_count(b, ChatChannels.SYSTEM) > 0, "the intro / piloting messages are system lines in the chat")


func _check_scrollback(b: Battle) -> void:
	for i in HISTORY_LINES:
		b.overlay.chat_log.add(ChatChannels.SYSTEM, "", "history line %d" % i)
	await _send_action("chat_history")
	var panel := b.chat.panel
	_expect(panel.mode == ChatPanel.Mode.HISTORY, "chat_history opens the full history")
	_expect(ChatFocus.open, "the chat counts as open (gameplay _input handlers stand back)")
	await _send_action("chat_scroll_up")
	await _send_action("chat_scroll_up")
	_expect(panel.scroll == 2, "chat_scroll_up scrolls back (%d)" % panel.scroll)
	await _send_action("chat_scroll_down")
	_expect(panel.scroll == 1, "chat_scroll_down scrolls forward again")
	await _send_action("chat_cancel")
	_expect(not panel.is_open() and panel.scroll == 0, "chat_cancel closes the history at the newest line")


func _check_filters(b: Battle) -> void:
	var panel := b.chat.panel
	b.overlay.chat_log.add(ChatChannels.TEAM, "Mate", "team line")
	panel.apply_filter(ChatChannels.TEAM, false)
	var shown := b.overlay.chat_log.make_shown(panel.settings.filters)
	_expect(shown.all(func(e: Dictionary) -> bool: return e.channel != ChatChannels.TEAM), "a hidden channel's lines are not shown")
	_expect(not bool(ChatSettings.load_settings().filters.team), "the filter is saved")
	panel.apply_filter(ChatChannels.TEAM, true)
	shown = b.overlay.chat_log.make_shown(panel.settings.filters)
	_expect(shown.any(func(e: Dictionary) -> bool: return e.channel == ChatChannels.TEAM), "showing it again brings the lines back")


func _check_typing(b: Battle) -> void:
	var panel := b.chat.panel
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var before := Input.mouse_mode
	b.player.throttle = 0.0
	await _send_action("chat_all")
	_expect(panel.mode == ChatPanel.Mode.TYPING and panel.channel == ChatChannels.ALL, "chat_all opens typing to all")
	_expect(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "typing frees the mouse")
	_expect(b.pilot.process_mode == Node.PROCESS_MODE_DISABLED, "typing holds the player's controls")
	for c in TYPED:
		await _send_key(OS.find_keycode_from_string(c.to_upper()), c.unicode_at(0))
	await get_tree().create_timer(0.3).timeout
	_expect(is_zero_approx(b.player.throttle), "W while typing does not throttle (%.2f)" % b.player.throttle)
	await _send_key(KEY_ENTER)
	_expect(_count(b, ChatChannels.ALL, TYPED) == 1, "the typed line is said to all ('%s')" % TYPED)
	_expect(not panel.is_open() and not ChatFocus.open, "sending closes the chat")
	_expect(Input.mouse_mode == before, "closing restores the mouse mode (%d)" % Input.mouse_mode)
	_expect(b.pilot.process_mode != Node.PROCESS_MODE_DISABLED, "closing gives the controls back")
	await _send_action("chat_team")
	await _send_key(KEY_ESCAPE)
	_expect(not panel.is_open() and not b.is_menu_open(), "Esc cancels the chat and does not open the battle menu")


func _check_quick_chat(b: Battle) -> void:
	var panel := b.chat.panel
	await _send_action("chat_quick")
	_expect(panel.mode == ChatPanel.Mode.QUICK, "chat_quick opens the quick-chat menu")
	var menu: Array = panel.quick_menu
	_expect(not menu.is_empty() and not (menu[0].items as Array).is_empty(), "the quick-chat menu has lines (%d headings)" % menu.size())
	var tribes := QuickChat.load_pack_menu("tribes")
	if not tribes.is_empty():
		_expect(menu == tribes, "the menu is the one extracted from the installed Tribes chat menu")
	var menu_node: QuickChatMenu = panel.find_children("*", "QuickChatMenu", true, false)[0]
	menu_node.show_category(0)
	var item: Dictionary = menu[0].items[0]
	menu_node.picked.emit(item)
	await _frames()
	var channel := ChatChannels.TEAM if bool(item.get("team", false)) else ChatChannels.ALL
	_expect(_count(b, channel, str(item.text)) == 1, "a picked line is said on its channel (%s)" % channel)
	_expect(not panel.is_open(), "picking closes the menu")


func _check_team_routing(b: Battle) -> void:
	var chat := b.chat
	b.config["roster"] = {1: {"name": "Host", "team": 0}, 2: {"name": "Mate", "team": 0}, 3: {"name": "Rival", "team": 1}}
	var team := chat.team_of(2)
	_expect(chat.make_recipients(ChatChannels.TEAM, team, [1, 2, 3]) == [1, 2], "a team line reaches the sender's team only")
	_expect(chat.make_recipients(ChatChannels.ALL, team, [1, 2, 3]) == [1, 2, 3], "an all line reaches everybody")
	_expect(chat.make_recipients(ChatChannels.TEAM, chat.team_of(3), [1, 2, 3]) == [3], "the other team's line stays on its team")


func _check_rate_limit_and_cap(b: Battle) -> void:
	var chat := b.chat
	chat.limiter = ChatRateLimiter.new()
	for i in ChatRateLimiter.DEFAULT_BURST + 2:
		chat.route(1, ChatChannels.ALL, "flood %d" % i)
	var flood := b.overlay.chat_log.entries.filter(func(e: Dictionary) -> bool: return str(e.text).begins_with("flood"))
	_expect(flood.size() == ChatRateLimiter.DEFAULT_BURST, "the flood guard lets %d of %d lines through" % [flood.size(), ChatRateLimiter.DEFAULT_BURST + 2])
	_expect(_count(b, ChatChannels.SYSTEM, BattleChat.RATE_LIMIT_TEXT) >= 1, "the sender is told he is too fast")
	chat.limiter = ChatRateLimiter.new()
	chat.route(1, ChatChannels.ALL, "x".repeat(ChatLog.MAX_TEXT_LENGTH * 2))
	var last: Dictionary = b.overlay.chat_log.entries[-1]
	_expect(str(last.text).length() == ChatLog.MAX_TEXT_LENGTH, "a long line is cut to %d characters" % ChatLog.MAX_TEXT_LENGTH)
	_expect(str(last.sender) == b.make_pilot_name(1), "the host names the sender from the roster")


func _check_radio(b: Battle) -> void:
	b.radio(RADIO_SPEAKER, "radio check")
	await _frames()
	var e := b.overlay.chat_log.find_newest(ChatChannels.RADIO)
	_expect(not e.is_empty() and e.sender == RADIO_SPEAKER, "a radio line arrives with its speaker")
	var hidden := b.overlay.chat_log.make_shown({ChatChannels.RADIO: false})
	_expect(hidden.all(func(x: Dictionary) -> bool: return x.channel != ChatChannels.RADIO), "the radio filter hides radio lines")


func _check_settings_persist() -> void:
	ChatSettings.apply_value("visible_lines", 9)
	ChatSettings.apply_value("position", "top_right")
	var saved = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_FILE))
	var chat: Dictionary = saved.get(ChatSettings.KEY, {}) if saved is Dictionary else {}
	_expect(int(chat.get("visible_lines", 0)) == 9 and chat.get("position") == "top_right", "settings are saved to %s" % SETTINGS_FILE)
	_expect(ChatSettings.load_settings().visible_lines == 9, "and read back")
	ChatSettings.apply_value("visible_lines", 999)
	_expect(ChatSettings.load_settings().visible_lines == int(ChatSettings.LIMITS.visible_lines.y), "out-of-range values are clamped")
	ChatSettings.reset()
	_expect(ChatSettings.load_settings() == ChatSettings.make_defaults(), "reset restores the defaults")

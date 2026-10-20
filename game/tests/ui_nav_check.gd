extends Node
## Headless check of keyboard / gamepad navigation in the app UI (engine/ui): focus starts on the
## first control, ui_down / d-pad walk every control down to the primary action, ui_accept presses,
## menu_back (Esc / pad B) leaves, ConfirmDialog traps focus, the launcher's and library's screens
## route back, and the hangar orbits / zooms from the right stick and triggers.
##   godot --headless --audio-driver Dummy --path game res://tests/ui_nav_check.tscn

const STEP_FRAMES := 2
## The menu's lobby entries: [kind, offline].
const LOBBY_ENTRIES := [["skirmish", true], ["extraction", true], ["vs", false], ["coop", false], ["campaign", false]]
const SavedGuard := preload("res://tests/saved_campaign_guard.gd")

var _fails := 0
var _pressed := {}
var _guard := SavedGuard.new()   # campaign pages autosave; the player's saves and settings are restored


func _ready() -> void:
	_guard.back_up()
	_check_actions_registered()
	await _check_frame_keyboard()
	await _check_frame_gamepad()
	await _check_confirm_dialog()
	await _check_launcher_routes()
	await _check_library_routes()
	await _check_campaign_pages_pad()
	await _check_hangar_pad()
	await _check_back_paths()
	_guard.restore()
	print("ui_nav_check: %d failures" % _fails)
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


func _send_pad_button(button: JoyButton) -> void:
	for pressed in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.button_index = button
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames()


func _send_pad_axis(axis: JoyAxis, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	Input.parse_input_event(ev)
	await _frames(1)


func _focus() -> Control:
	return get_viewport().gui_get_focus_owner()


func _focus_name() -> String:
	var f := _focus()
	if f == null:
		return "<none>"
	return "%s '%s'" % [f.get_class(), f.get("text") if f.get("text") != null else f.name]


func _counter(key: String) -> Callable:
	return func() -> void: _pressed[key] = int(_pressed.get(key, 0)) + 1


## A frame with a line edit, two buttons, a slider, Back and a primary action.
func _make_test_frame() -> ScreenFrame:
	var frame := ScreenFrame.new()
	frame.set_title("NAV TEST", "keyboard and gamepad")
	frame.content.add_child(OptionRow.new("Name", Widgets.line_edit("x")))
	frame.content.add_child(Widgets.button("One", _counter("one")))
	frame.content.add_child(Widgets.button("Two", _counter("two")))
	frame.content.add_child(OptionRow.new("Level", Widgets.slider(0, 10, 5)).with_value_readout())
	frame.set_back("Back", _counter("back"))
	frame.set_primary("Go", _counter("primary"))
	add_child(frame)
	return frame


# ------------------------------------------------------------------ checks

func _check_actions_registered() -> void:
	for action in ["menu_back", "ui_accept", "ui_down", "orbit", "zoom_in", "zoom_out", "orbit_left"]:
		_expect(InputMap.has_action(action), "action %s registered" % action)


func _check_frame_keyboard() -> void:
	_pressed.clear()
	var frame := _make_test_frame()
	await _frames()
	_expect(_focus() is LineEdit, "first control focused on open (%s)" % _focus_name())
	var visited := []
	for i in 4:   # line edit -> One -> Two -> slider -> primary
		await _send_action("ui_down")
		visited.append(_focus_name())
	print("      ui_down walk: ", visited)
	_expect(_focus() == frame.primary_button, "ui_down reaches the primary action (%s)" % _focus_name())
	await _send_action("ui_accept")
	_expect(_pressed.get("primary", 0) == 1, "ui_accept presses the primary action")
	await _send_action("ui_left")
	_expect(_focus() == frame.back_button, "ui_left from primary moves to Back")
	await _send_action("ui_up")
	_expect(_focus() is HSlider, "ui_up from the footer returns to the content (%s)" % _focus_name())
	await _send_action("menu_back")
	_expect(_pressed.get("back", 0) == 1, "menu_back presses Back")
	frame.queue_free()
	await _frames()


func _check_frame_gamepad() -> void:
	_pressed.clear()
	var frame := _make_test_frame()
	await _frames()
	await _send_pad_button(JOY_BUTTON_DPAD_DOWN)
	_expect(_focus() is Button and (_focus() as Button).text == "One", "d-pad down moves focus (%s)" % _focus_name())
	await _send_pad_button(JOY_BUTTON_A)
	_expect(_pressed.get("one", 0) == 1, "pad A presses the focused button")
	await _send_pad_axis(JOY_AXIS_LEFT_Y, 1.0)
	await _send_pad_axis(JOY_AXIS_LEFT_Y, 0.0)
	await _frames()
	_expect(_focus() is Button and (_focus() as Button).text == "Two", "left stick down moves focus (%s)" % _focus_name())
	await _send_pad_button(JOY_BUTTON_B)
	_expect(_pressed.get("back", 0) == 1, "pad B (menu_back) leaves the screen")
	frame.queue_free()
	await _frames()


func _check_confirm_dialog() -> void:
	_pressed.clear()
	var frame := _make_test_frame()
	await _frames()
	ConfirmDialog.ask(frame, "Really?", _counter("confirmed"), "Do it", Widgets.DANGER)
	await _frames()
	_expect(_focus() is Button and (_focus() as Button).text == "Cancel", "danger dialog focuses Cancel (%s)" % _focus_name())
	await _send_action("ui_down")
	await _send_action("ui_down")
	_expect(_is_in_dialog(frame), "focus stays inside the dialog (%s)" % _focus_name())
	await _send_action("menu_back")
	_expect(_pressed.get("back", 0) == 0 and not _has_dialog(frame), "menu_back closes the dialog, not the screen")
	ConfirmDialog.ask(frame, "Really?", _counter("confirmed"), "Do it")
	await _frames()
	_expect(_focus() is Button and (_focus() as Button).text == "Do it", "plain dialog focuses Confirm")
	await _send_action("ui_accept")
	_expect(_pressed.get("confirmed", 0) == 1 and not _has_dialog(frame), "ui_accept confirms")
	await _check_three_choice_dialog(frame)
	frame.queue_free()
	await _frames()


## Swap / Clear / Cancel (rebinding conflicts): the extra answer sits between Cancel and confirm,
## focus walks all three and the extra answer runs its own action.
func _check_three_choice_dialog(frame: ScreenFrame) -> void:
	var d := ConfirmDialog.ask(frame, "Conflict", _counter("swap"), "Swap")
	d.add_choice("Clear", _counter("clear"), Widgets.DANGER)
	await _frames()
	await _send_action("ui_left")
	_expect(_focus() is Button and (_focus() as Button).text == "Clear", "ui_left from Swap reaches the extra answer (%s)" % _focus_name())
	await _send_action("ui_accept")
	_expect(_pressed.get("clear", 0) == 1 and _pressed.get("swap", 0) == 0 and not _has_dialog(frame), "the extra answer runs its action and closes")


func _has_dialog(frame: Node) -> bool:
	return frame.get_children().any(func(c: Node) -> bool: return c is ConfirmDialog and not c.is_queued_for_deletion())


func _is_in_dialog(frame: Node) -> bool:
	for c in frame.get_children():
		if c is ConfirmDialog and c.is_ancestor_of(_focus()):
			return true
	return false


func _check_launcher_routes() -> void:
	var launcher: Launcher = load("res://launcher.tscn").instantiate()
	add_child(launcher)
	await _frames(4)
	_expect(launcher.current_name == "menu", "launcher opens on the menu")
	_expect(_focus() != null and launcher.is_ancestor_of(_focus()), "launcher menu has focus (%s)" % _focus_name())
	for page in ["browser", "options", "new_campaign", "saves"]:
		launcher.go(page)
		await _frames(3)
		_expect(_focus() != null and launcher.current.is_ancestor_of(_focus()), "%s: first control focused (%s)" % [page, _focus_name()])
		_expect(_walks_to_footer(launcher.current), "%s: every control links down to the footer" % page)
		await _send_action("menu_back")
		_expect(launcher.current_name == "menu", "%s: menu_back returns to the menu (now %s)" % [page, launcher.current_name])
	for entry in LOBBY_ENTRIES:
		launcher.open_lobby(entry[0], entry[1])
		await _frames(4)
		_expect(launcher.current_name == "lobby" and _focus() != null and launcher.current.is_ancestor_of(_focus()), "%s lobby: first control focused (%s)" % [entry[0], _focus_name()])
		await _send_action("menu_back")
		_expect(launcher.current_name == "menu" and Net.roster.is_empty(), "%s lobby: menu_back leaves to the menu (now %s)" % [entry[0], launcher.current_name])
	Net.stop_discovery()
	launcher.queue_free()
	await _frames()


## Following focus_neighbor_bottom from the first control reaches the primary / Back button.
func _walks_to_footer(screen: ScreenFrame) -> bool:
	var c := _focus()
	for i in 200:
		if c == screen.primary_button or c == screen.back_button:
			return true
		var next := c.get_node_or_null(c.focus_neighbor_bottom) as Control
		if next == null or next == c:
			return false
		c = next
	return false


## New campaign by gamepad: d-pad down from the name reaches the campaign choices, A picks one; the
## killed-in-action prompt opens on Replay, pad B is Quit to main menu.
func _check_campaign_pages_pad() -> void:
	var launcher: Launcher = load("res://launcher.tscn").instantiate()
	add_child(launcher)
	await _frames(4)
	launcher.go("new_campaign")
	await _frames(3)
	_expect(_focus() is LineEdit, "new campaign: the pilot name is focused first (%s)" % _focus_name())
	await _send_pad_button(JOY_BUTTON_DPAD_DOWN)
	await _send_pad_button(JOY_BUTTON_DPAD_DOWN)
	var box := _focus() as CheckBox
	_expect(box != null, "new campaign: d-pad down reaches the second campaign choice (%s)" % _focus_name())
	if box != null and not box.disabled:
		await _send_pad_button(JOY_BUTTON_A)
		_expect(box.button_pressed, "new campaign: pad A chooses it")
	_expect(_walks_to_footer(launcher.current), "new campaign: every control links down to the footer")
	Session.start_stage_campaign("es1")
	Session.last_result = {"success": false, "pilot_killed": true}
	Net.stop_discovery()
	launcher.queue_free()
	await _frames()
	launcher = await _open_launcher_scene("")
	launcher.go("killed")
	await _frames(3)
	_expect(_focus() == launcher.current.primary_button, "killed prompt: Replay mission is focused (%s)" % _focus_name())
	await _send_pad_button(JOY_BUTTON_B)
	await _frames(4)
	_expect(_scene_is_library() and Session.campaign == null, "killed prompt: pad B quits to the main menu (the library)")
	await _close_scene()


func _check_library_routes() -> void:
	var library: Library = load("res://library.tscn").instantiate()
	add_child(library)
	await _frames(4)
	_expect(library.current_name == "home", "library opens on home")
	_expect(_focus() != null and library.is_ancestor_of(_focus()), "library home has focus (%s)" % _focus_name())
	_expect(_walks_to_footer(library.current), "library home links down to the footer")
	library.go("options", {"home": "home"})
	await _frames(3)
	await _send_action("menu_back")
	_expect(library.current_name == "home", "options: menu_back returns home")
	await _send_action("menu_back")
	_expect(_has_dialog(library.current), "home: menu_back asks before quitting")
	await _send_action("menu_back")
	_expect(not _has_dialog(library.current), "quit question closed with menu_back")
	library.queue_free()
	await _frames()


func _check_hangar_pad() -> void:
	var view := HangarView.new()
	view.size = Vector2(640, 480)
	add_child(view)
	await _frames(3)
	view.show_herc("es1:RAPTOR")
	await _frames(3)
	var yaw := view.bay.orbit_yaw
	var zoom := view.bay.zoom
	await _send_pad_axis(JOY_AXIS_RIGHT_X, 1.0)
	await _send_pad_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	await _frames(10)
	await _send_pad_axis(JOY_AXIS_RIGHT_X, 0.0)
	await _send_pad_axis(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	_expect(not is_equal_approx(view.bay.orbit_yaw, yaw), "right stick orbits the hangar (yaw %.2f -> %.2f)" % [yaw, view.bay.orbit_yaw])
	_expect(view.bay.zoom > zoom, "right trigger zooms in (%.2f -> %.2f)" % [zoom, view.bay.zoom])
	view.queue_free()


# ------------------------------------------------------------------ Back paths (docs/MENU_MAP.md)

## The launcher as the app opens it from the library (Library.open_launcher): the current scene, meta start_mode.
func _open_launcher_scene(start_mode: String) -> Launcher:
	Session.front_end = "res://library.tscn"
	var launcher: Launcher = load("res://launcher.tscn").instantiate()
	if start_mode != "":
		launcher.set_meta("start_mode", start_mode)
	get_tree().root.add_child(launcher)
	get_tree().current_scene = launcher
	await _frames(4)
	return launcher


func _scene_is_library() -> bool:
	return get_tree().current_scene is Library


func _close_scene() -> void:
	Net.stop_discovery()
	var scene := get_tree().current_scene
	if scene != null and scene != self:
		scene.queue_free()
	get_tree().current_scene = self
	await _frames()


## menu_back from `launcher` (now on page `from`) lands on `expected` (a launcher page, or "library").
func _expect_back(launcher: Launcher, from: String, expected: String) -> void:
	await _send_action("menu_back")
	await _frames(4)
	var landed := "library" if _scene_is_library() else (launcher.current_name if is_instance_valid(launcher) else "?")
	_expect(landed == expected, "%s -> Back -> %s (landed on %s)" % [from, expected, landed])


## Every Back path of the menu map: Back returns to the screen the player came from; from a page the library
## opened (Arena / versus, Host, Join, campaign pages, the launcher's own menu) that is the library.
func _check_back_paths() -> void:
	for entry in [["arena", "lobby"], ["host", "lobby"], ["coop", "lobby"], ["coop_campaign", "lobby"],
			["join", "browser"], ["new_campaign", "new_campaign"], ["load", "saves"], ["menu", "menu"]]:
		var launcher := await _open_launcher_scene(entry[0])
		_expect(launcher.current_name == entry[1], "library %s opens %s (%s)" % [entry[0], entry[1], launcher.current_name])
		await _expect_back(launcher, "library %s: %s" % [entry[0], entry[1]], "library")
		_expect(Net.roster.is_empty(), "library %s: Back closed the session" % entry[0])
		await _close_scene()
	var launcher := await _open_launcher_scene(Launcher.MENU_START_MODE)
	for page in ["browser", "options", "new_campaign", "saves", "training"]:
		launcher.go(page, {"pack": "tribes"} if page == "training" else {})
		await _frames(3)
		await _expect_back(launcher, "menu > %s" % page, "menu")
	launcher.go("new_campaign")
	await _frames(2)
	launcher.go("saves", {"mode": "load"})
	await _frames(2)
	await _expect_back(launcher, "menu > new campaign > saves", "new_campaign")
	await _expect_back(launcher, "menu > new campaign", "menu")
	await _check_lobby_back(launcher)
	await _check_campaign_back(launcher)
	await _expect_back(launcher, "menu", "library")
	await _close_scene()


## Host LAN game > lobby > Leave returns to the menu.
func _check_lobby_back(launcher: Launcher) -> void:
	launcher.open_lobby("vs")
	await _frames(3)
	if launcher.current_name != "lobby":
		_expect(false, "menu > Host LAN game opens the lobby (port busy?)")
		return
	await _expect_back(launcher, "menu > lobby (Leave)", "menu")
	_expect(not Net.is_online(), "Leave closed the LAN session")


## Campaign: lobby > Save game > Back returns to the lobby; lobby > Hangar > Back returns to the lobby.
func _check_campaign_back(launcher: Launcher) -> void:
	Session.start_stage_campaign("es1")
	Session.last_result = {}
	launcher.show_started_campaign()
	await _frames(3)
	_expect(launcher.current_name == "lobby" and MatchFlow.is_solo_campaign(Net.settings), "a started campaign opens its offline lobby (%s)" % launcher.current_name)
	launcher.go("saves", {"mode": "save", "return_to": "lobby"})
	await _frames(2)
	await _expect_back(launcher, "lobby > saves", "lobby")
	launcher.open_hangar("lobby")
	await _frames(3)
	await _expect_back(launcher, "lobby > hangar", "lobby")
	Session.clear_campaign()
	Net.leave()   # the session ended under the lobby: the launcher goes back to the menu it was opened from
	await _frames(2)
	_expect(launcher.current_name == "menu", "the lobby came from the menu: the stack leads back there (%s)" % launcher.current_name)

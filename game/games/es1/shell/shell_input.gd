class_name ShellInput
extends RefCounted
## Turns input into shell actions, through the SiegeInput actions (docs/CODING_STANDARDS.md §2):
##   ui_click (mouse left)        press / release the control under the cursor
##   orbit (mouse right) + drag   turn the hub's 3D hangar bay; right stick (orbit_*) too
## While the app's Hangar screen is open over the shell, it handles all input.
##   menu_scroll_up / _down       wheel: scroll the menu's first list
##   ui_up / ui_down              scroll the highlighted list (arrow keys with nothing highlighted:
##                                the dialog's first list, as in the original), else move the highlight
##   ui_left / ui_right           move the highlight between buttons (gamepad / keyboard)
##   ui_accept                    the highlighted control, else the dialog's Enter hotkey
##   menu_back                    the dialog's Esc hotkey, else close the popup
##   debug_toggle (F10)           the developer launcher
## Text entry and the dialogs' own hotkeys (DOS scan codes) are the one documented exception that
## reads raw keys: ShellMenu.text_input() and ShellMenu.hotkey_for_key().
## While a sequence runs any press skips it, menu_back / ui_cancel skips the rest of the chain.

var shell: EsShell


func _init(p_shell: EsShell) -> void:
	shell = p_shell


func handle(event: InputEvent) -> void:
	if shell.screen == null or shell.hangar.is_open():
		return   # the Hangar screen over the shell takes its own input
	if event is InputEventMouseMotion:
		_handle_motion(event)
	elif event.is_action_pressed("debug_toggle"):
		shell.switch_scene(EsShell.LAUNCHER_SCENE)
	elif shell.busy:
		_handle_skip(event)
	elif shell.top() != null:
		_handle_menu(shell.top(), event)


func _handle_motion(event: InputEventMouseMotion) -> void:
	if Input.is_action_pressed("orbit") and not Input.is_action_pressed("ui_click"):
		shell.hangar.apply_mouse_orbit(event.relative)
	shell.screen.cursor_pos = shell.screen.to_virtual(event.position)
	var m := shell.top()
	if m and not shell.busy:
		m.mouse_move(shell.screen.cursor_pos)


## Any press skips the running sequence piece; menu_back / ui_cancel skips the whole chain.
func _handle_skip(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	shell.skip_requested = true
	if event.is_action_pressed("menu_back") or event.is_action_pressed("ui_cancel"):
		shell.abort_requested = true
	shell.get_viewport().set_input_as_handled()


func _handle_menu(m: ShellMenu, event: InputEvent) -> void:
	if event is InputEventMouseButton and event.is_action("ui_click"):
		_handle_click(m, event)
	elif event.is_action_pressed("menu_scroll_up"):
		m.scroll(m.first_list(), -1)
	elif event.is_action_pressed("menu_scroll_down"):
		m.scroll(m.first_list(), 1)
	elif event is InputEventKey and event.pressed and _handle_dialog_key(m, event):
		return
	elif event.is_action_pressed("ui_accept"):
		_accept(m)
	elif event.is_action_pressed("menu_back"):
		_back(m)
	else:
		_handle_navigation(m, event)


func _handle_click(m: ShellMenu, event: InputEventMouseButton) -> void:
	var p := shell.screen.to_virtual(event.position)
	shell.screen.cursor_pos = p
	if event.pressed:
		var c := m.mouse_down(p)
		if not c.is_empty():
			shell.commands.select(m, c)
	else:
		var b := m.mouse_up(p)
		if not b.is_empty():
			shell.activate(m, b)


## Keys typed into the focused edit box and the dialog's scan-code hotkeys; true when consumed.
func _handle_dialog_key(m: ShellMenu, event: InputEventKey) -> bool:
	if m.text_input(event):
		return true
	if m.focus >= 0 and event.is_action_pressed("ui_accept"):
		_accept(m)
		return true
	var hk := m.hotkey_for_key(event)
	if hk.is_empty():
		return false
	shell.activate(m, hk)
	return true


## ui_accept: OK while typing into an edit box, else the highlighted control, else the button the
## dialog binds to Enter.
func _accept(m: ShellMenu) -> void:
	var c := m.highlighted()
	if m.focus >= 0:
		shell.activate(m, m.find(EsShell.OK_ID))
	elif c.is_empty():
		shell.activate(m, m.hotkey_for_scan(ShellMenu.SCAN_ENTER))
	elif int(c.type) == ShellMenu.T_BUTTON:
		shell.activate(m, c)
	else:
		var pressed := m.press_highlighted()
		if not pressed.is_empty():
			shell.commands.select(m, pressed)


## menu_back: the button the dialog binds to Esc, else close the popup.
func _back(m: ShellMenu) -> void:
	var hk := m.hotkey_for_scan(ShellMenu.SCAN_ESCAPE)
	if not hk.is_empty():
		shell.activate(m, hk)
	elif shell.stack.size() > 1:
		shell.close_popup()


func _handle_navigation(m: ShellMenu, event: InputEvent) -> void:
	var dir := Vector2i.ZERO
	if event.is_action_pressed("ui_up", true):
		dir = Vector2i.UP
	elif event.is_action_pressed("ui_down", true):
		dir = Vector2i.DOWN
	elif event.is_action_pressed("ui_left", true):
		dir = Vector2i.LEFT
	elif event.is_action_pressed("ui_right", true):
		dir = Vector2i.RIGHT
	if dir == Vector2i.ZERO:
		return
	var list := m.highlighted_list()
	if list.is_empty() and m.hover < 0 and event is InputEventKey:
		list = m.first_list()   # original: the arrow keys scroll the dialog's list
	if dir.y != 0 and not list.is_empty():
		m.scroll(list, dir.y)
	else:
		m.move_highlight(dir)

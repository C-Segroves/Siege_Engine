extends Node
## Headless check of the shared lobby / loadout widgets: the theme variations and the narrow-width constant,
## CreditsBadge, ItemTooltip (hover, delayed focus, menu_info pin), ModalSheet (menu_back closes, menu_primary,
## focus trap and return) and OptionRow.make_readonly.
##   godot --headless --audio-driver Dummy --path game res://tests/ui_kit_check.tscn

const VARIATIONS := ["CreditsLabel", "CardPanel", "CardPanelSelected", "BadgeNotAllowed", "BadgeAtRisk", "BadgeLost",
	"TabButton", "ReadyDot", "ReadyDotOff", "Tooltip"]

var _fails := 0


func _ready() -> void:
	_check_theme()
	_check_credits_badge()
	_check_readonly_row()
	await _check_tooltip()
	await _check_modal_sheet()
	print("ui_kit_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


func _press(action: String) -> void:
	for pressed in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames()


# ------------------------------------------------------------------ theme and plain widgets

func _check_theme() -> void:
	var theme := ThemeDB.get_project_theme()
	var fresh: Theme = load("res://engine/ui/siege_theme.gd").make_theme()
	for name in VARIATIONS:
		_expect(fresh.get_type_variation_base(name) != &"", "theme (built) has variation %s" % name)
		_expect(theme.get_type_variation_base(name) != &"", "project theme (siege_theme.tres) has variation %s" % name)
	_expect(Widgets.metric("narrow_width") == 900, "Siege/narrow_width is 900")


func _check_credits_badge() -> void:
	_expect(CreditsBadge.make_text(1240) == "CR 1,240", "credits text groups thousands (%s)" % CreditsBadge.make_text(1240))
	_expect(CreditsBadge.make_text(0) == "CR 0" and CreditsBadge.make_text(999) == "CR 999", "small amounts have no separator")
	_expect(CreditsBadge.make_text(1234567) == "CR 1,234,567", "millions group twice")
	var wallet := [50]
	var badge := CreditsBadge.new(10)
	add_child(badge)
	_expect(badge.text() == "CR 10" and badge.focus_mode == Control.FOCUS_NONE, "badge shows its value and never takes focus")
	badge.bind_source(func() -> int: return wallet[0])
	_expect(badge.text() == "CR 50", "bind_source reads the balance")
	wallet[0] = 75
	badge.refresh()
	_expect(badge.text() == "CR 75", "refresh follows the source")
	badge.queue_free()


func _check_readonly_row() -> void:
	var row := OptionRow.make_readonly("Map", "Raindance")
	add_child(row)
	_expect(row.control is Label and (row.control as Label).text == "Raindance", "make_readonly shows the value as a Label")
	_expect(row.control.focus_mode == Control.FOCUS_NONE, "a read-only row takes no focus")
	row.queue_free()


# ------------------------------------------------------------------ tooltip

func _check_tooltip() -> void:
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(host)
	var tip := ItemTooltip.new()
	host.add_child(tip)
	var a := Widgets.button("Mortar", func() -> void: pass)
	var b := Widgets.button("Disc", func() -> void: pass)
	var box := VBoxContainer.new()
	box.add_child(a)
	box.add_child(b)
	host.add_child(box)
	tip.watch(a, func() -> Dictionary: return {"title": "Mortar", "lines": ["8 kg"], "price": "Price 3,000 cr",
		"warning": "Not allowed: medium armour only"})
	tip.watch(b, func() -> Dictionary: return {"title": "Disc"})
	await _frames()
	_expect(ItemTooltip.make_lines({"title": "T", "lines": ["x"], "price": "p", "warning": "w"}) == ["T", "x", "p", "w"],
		"plate lines are title, lines, price, warning")
	a.mouse_entered.emit()
	_expect(tip.is_shown_for(a), "hover shows the plate at once")
	a.mouse_exited.emit()
	_expect(not tip.visible, "leaving hides it")
	a.grab_focus()
	await _frames()
	_expect(not tip.visible, "focus alone shows nothing before the delay")
	await get_tree().create_timer(ItemTooltip.FOCUS_DELAY_S + 0.15).timeout
	_expect(tip.is_shown_for(a), "focus shows the plate after %.1f s" % ItemTooltip.FOCUS_DELAY_S)
	b.grab_focus()
	await _frames()
	_expect(not tip.visible, "moving focus hides it")
	await _press("menu_info")
	_expect(tip.pinned and tip.is_shown_for(b), "menu_info pins the focused item's plate")
	a.grab_focus()
	await _frames()
	_expect(tip.pinned and tip.is_shown_for(a), "a pinned plate follows the focus at once")
	await _press("menu_info")
	_expect(not tip.pinned and tip.visible, "menu_info again unpins (the plate stays until focus leaves)")
	_expect(tip.global_position.x >= 0.0 and tip.global_position.y >= 0.0, "the plate is never placed off the top left of the viewport")
	host.queue_free()
	await _frames()


# ------------------------------------------------------------------ modal sheet

func _check_modal_sheet() -> void:
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(host)
	var behind := Widgets.button("Behind", func() -> void: pass)
	host.add_child(behind)
	behind.grab_focus()
	var counts := {"done": 0, "closed": 0}
	var sheet := ModalSheet.open(host, "OPERATOR SETUP")
	var inside := Widgets.button("Inside", func() -> void: pass)
	sheet.body.add_child(inside)
	sheet.set_primary("Done", func() -> void: counts.done += 1)
	sheet.closed.connect(func() -> void: counts.closed += 1)
	await _frames(3)
	_expect(get_viewport().gui_get_focus_owner() == inside, "the first control in the sheet takes focus")
	behind.grab_focus()
	await _frames()
	_expect(sheet.is_ancestor_of(get_viewport().gui_get_focus_owner()), "focus cannot leave the sheet")
	await _press("menu_primary")
	_expect(counts.done == 1 and sheet.is_open, "menu_primary presses the primary action")
	var dialog := ConfirmDialog.ask(host, "Sure?", func() -> void: pass)
	await _frames(3)
	_expect(dialog.is_ancestor_of(get_viewport().gui_get_focus_owner()), "a dialog opened over the sheet keeps its own focus")
	await _press("menu_back")
	_expect(not is_instance_valid(dialog) or dialog.is_queued_for_deletion(), "menu_back closes the dialog first")
	_expect(sheet.is_open, "the sheet stays open under it")
	await _press("menu_back")
	_expect(counts.closed == 1 and not is_instance_valid(sheet), "menu_back closes the sheet")
	await _frames(2)
	_expect(behind.has_focus(), "focus returns to the control that opened it")
	host.queue_free()

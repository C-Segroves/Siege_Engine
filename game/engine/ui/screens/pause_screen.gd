extends RoutedScreen
## The in-battle menu's page (BattleMenu): Resume (primary), Options, Abort mission / Leave match and
## Quit to main menu. menu_back and menu_pause (Esc, pad B / Start) resume.

const QUIT_QUESTION := "Quit to the main menu? The running battle is lost."


func open(_args: Dictionary) -> void:
	set_page_title(str(_actions().get("page", "paused")))
	use_shaded_background()
	set_primary("Resume", _resume)
	content.add_child(Widgets.button("Options", func() -> void: router.go("options", {"home": "pause"})))
	content.add_child(Widgets.button(str(_actions().get("leave_text", "Leave match")), _ask_leave, Widgets.DANGER))
	content.add_child(Widgets.button("Quit to main menu", _ask_quit, Widgets.DANGER))
	content.add_child(Widgets.paragraph(str(_actions().get("note", "")), "DimLabel"))


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event) or UiActions.is_pressed(event, "menu_pause"):
		get_viewport().set_input_as_handled()
		_resume()


func _actions() -> Dictionary:
	return (router as BattleMenu).actions


func _resume() -> void:
	(router as BattleMenu).run_action("on_resume")


func _ask_leave() -> void:
	ConfirmDialog.ask(self, str(_actions().get("leave_question", "")),
		func() -> void: (router as BattleMenu).run_action("on_leave"),
		str(_actions().get("leave_text", "Leave match")), Widgets.DANGER)


func _ask_quit() -> void:
	ConfirmDialog.ask(self, QUIT_QUESTION, func() -> void: (router as BattleMenu).run_action("on_quit"),
		"Quit", Widgets.DANGER)

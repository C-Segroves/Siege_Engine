extends LauncherScreen
## Starsiege stage of the saga: choose the Human or the Cybrid campaign (Save game: the Save / Load screen).

const SIDES := [["human", "Human campaign"], ["cybrid", "Cybrid campaign"]]


func open(_args: Dictionary) -> void:
	set_page_title("saga  -  Starsiege")
	MenuMusic.play_for_pack(MenuMusic.STARSIEGE)
	set_back("Save and quit to menu", _save_and_quit)
	content.add_child(Widgets.label("STARSIEGE", "HeaderLabel"))
	content.add_child(Widgets.paragraph("The war has changed. Choose your side:"))
	for side in SIDES:
		content.add_child(Widgets.button(side[1], func() -> void: _choose(side[0])))
	content.add_child(Widgets.button("Save game", func() -> void: router.go("saves", {"mode": "save", "return_to": "saga_choice"})))


func _choose(side: String) -> void:
	Session.saga.choose(side)
	Session.campaign = Session.saga.campaign
	Session.autosave()
	launcher().show_campaign()


func _save_and_quit() -> void:
	Session.autosave()
	Session.clear_campaign()
	launcher().go_main_menu()

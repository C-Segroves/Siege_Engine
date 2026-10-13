extends LauncherScreen
## Launcher main menu: pilot name, campaigns, the extraction mode's stash and solo raid (needs a Tribes pack), (Continue campaign: the newest save that can go on, loaded only
## when chosen; New campaign: pilot name and the saga or one game's campaign; Load game: the Save / Load
## screen; SaveGames is the store), the Tribes / Tribes 2 training missions, skirmish / armory, LAN, tools,
## options, Quit (asked first). Back returns to the front end that opened the launcher and says which one.

const INTRO_MOVIE := "video/flic/intro3.ogv"
const SHAPE_VIEWER := "res://tools/shape_viewer.tscn"
const LIBRARY := "res://library.tscn"
const QUIT_QUESTION := "Quit Siege Engine?"


func open(_args: Dictionary) -> void:
	set_page_title("main menu")
	MenuMusic.play_app_hub()
	var full := not launcher().multiplayer_only
	set_back(launcher().make_home_label(), launcher().leave_to_front_end)
	set_primary("Skirmish / armory", func() -> void: router.go("armory"))
	content.add_child(NameRow.new("Pilot name"))
	_add_campaign_section(full)
	if ExtractionRules.is_available():
		content.add_child(Widgets.section("Extraction"))
		_add(Widgets.button("Extraction raid (stash, shop, solo raid)", func() -> void: router.go("extraction")))
	content.add_child(Widgets.section("LAN"))
	_add(Widgets.button("Host LAN game", func() -> void: router.go("host")))
	_add(Widgets.button("Join LAN game", func() -> void: router.go("browser")))
	content.add_child(Widgets.section("More"))
	if full:
		_add(Widgets.button("Play intro", func() -> void: MoviePlayer.play(self, INTRO_MOVIE)))
		_add(Widgets.button("Shape viewer", func() -> void: get_tree().change_scene_to_file(SHAPE_VIEWER)))
		_add(Widgets.button("Library (import discs / content)", func() -> void: get_tree().change_scene_to_file(LIBRARY)))
	_add(Widgets.button("Options", func() -> void: router.go("options", {"home": "menu"})))
	_add(Widgets.button("Quit", _ask_quit, Widgets.DANGER))


func _add(c: Control) -> void:
	content.add_child(c)


## Continue / New campaign / Load game (the multiplayer-only menu's New campaign offers Earthsiege's only).
func _add_campaign_section(full: bool) -> void:
	content.add_child(Widgets.section("Campaign"))
	var newest := SaveGames.find_newest_continuable()
	if not newest.is_empty():
		var cont := Widgets.button("Continue campaign", _continue_campaign)
		cont.tooltip_text = SaveGames.make_row_text(newest)
		_add(cont)
	_add(Widgets.button("New campaign", func() -> void: router.go("new_campaign")))
	_add(Widgets.button("Load game", func() -> void: router.go("saves", {"mode": "load"})))
	if full:
		_add_training_buttons()


## Tribes / Tribes 2 training missions (the "training" screen), for each pack that has them installed.
func _add_training_buttons() -> void:
	for pack in TribesMissionRuntime.PACKS:
		if not TribesMissionRuntime.list_missions(pack).is_empty():
			_add(Widgets.button("%s training" % Packs.pack_name(pack), func() -> void: router.go("training", {"pack": pack})))


func _continue_campaign() -> void:
	if not launcher().continue_newest():
		set_status("The saved campaign could not be read.")


func _ask_quit() -> void:
	ConfirmDialog.ask(self, QUIT_QUESTION, func() -> void: get_tree().quit(), "Quit", Widgets.DANGER)

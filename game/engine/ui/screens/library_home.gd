extends RoutedScreen
## Library home: import discs, switch each game's content on/off, soundtracks, and play: the campaigns
## (Continue / New campaign / Load game open the launcher's campaign pages), Host / Join a LAN game, co-op, the
## original Earthsiege.

const SHAPE_VIEWER := "res://tools/shape_viewer.tscn"
const ES1_SHELL := "res://es1_shell.tscn"
const ES1_SHELL_DATA := "shell/shell.json"
const PACK_GRID_COLUMNS := 3
const FILE_DIALOG_RATIO := 0.7
const PERCENT := 100.0

var _bar: ProgressBar


func open(_args: Dictionary) -> void:
	set_page_title("library")
	MenuMusic.play_app_hub()
	set_back("Quit", _ask_quit)
	var can_play := not Packs.pilotable().is_empty()
	set_primary("Arena / versus", func() -> void: _library().open_launcher("arena")).disabled = not can_play
	_add_import_section()
	_add_packs_section()
	_add_soundtrack_section()
	_add_campaign_section()
	_add_play_section(can_play)
	_follow_imports()


func _library() -> Library:
	return router as Library


func _ask_quit() -> void:
	ConfirmDialog.ask(self, "Quit Siege Engine?", func() -> void: get_tree().quit(), "Quit", Widgets.DANGER)


# ------------------------------------------------------------------ import

func _add_import_section() -> void:
	content.add_child(Widgets.section("Import"))
	var pick := Widgets.button("Import disc (.iso) ...", _pick_discs)
	pick.disabled = not ImportQueue.is_available()
	var hint := "Tip: drag .iso files onto this window. Multi-disc games: import all discs together."
	if WebPlatform.is_active():
		hint = WebPlatform.NO_IMPORT_TEXT
	elif not ImportQueue.is_available():
		hint = "The importer was not found next to the app."
	content.add_child(Widgets.row([pick, Widgets.paragraph(hint, "DimLabel")]))
	_bar = ProgressBar.new()
	_bar.visible = _library().imports.is_busy()
	content.add_child(_bar)


func _follow_imports() -> void:
	var imports := _library().imports
	imports.status_changed.connect(set_status)
	imports.progress_changed.connect(_show_progress)
	imports.import_finished.connect(_on_import_finished)


func _on_import_finished(ok: bool, _pack: String) -> void:
	if ok:
		router.replace("home")


func _show_progress(fraction: float) -> void:
	_bar.visible = fraction >= 0.0
	_bar.value = fraction * PERCENT


func _pick_discs() -> void:
	var fd := _make_file_dialog(FileDialog.FILE_MODE_OPEN_FILES)
	fd.filters = PackedStringArray(["*.iso, *.cue, *.bin ; Disc images"])
	fd.files_selected.connect(func(paths: PackedStringArray) -> void: _library().imports.enqueue_discs(paths))
	fd.popup_centered_ratio(FILE_DIALOG_RATIO)


func _make_file_dialog(mode: FileDialog.FileMode) -> FileDialog:
	var fd := FileDialog.new()
	fd.file_mode = mode
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	add_child(fd)
	return fd


# ------------------------------------------------------------------ packs

func _add_packs_section() -> void:
	var packs := Packs.packs.keys()
	var heading := "Your library" if not packs.is_empty() else "Your library is empty - import a disc to begin."
	content.add_child(Widgets.section(heading))
	for p in packs:
		_add_pack_card(p)


func _add_pack_card(pack: String) -> void:
	var card := Widgets.card(content)
	var title := Widgets.label("%s   (%s)" % [Packs.pack_name(pack), pack])
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var remove := Widgets.small_button("Remove", func() -> void: _ask_remove(pack), Widgets.DANGER)
	if WebPlatform.is_active():
		remove.disabled = true
		remove.tooltip_text = WebPlatform.NO_REMOVE_TEXT
	card.add_child(Widgets.row([title, remove]))
	if GameReleases.make_status(pack) != GameReleases.TESTED:
		card.add_child(Widgets.paragraph(GameReleases.make_status_text(pack) + " See Tested game versions.", "StatusLabel"))
	var contents := Packs.pack_contents(pack)
	if contents.is_empty():
		card.add_child(Widgets.label("(no playable content decoded yet)", "DimLabel"))
		return
	var grid := GridContainer.new()
	grid.columns = PACK_GRID_COLUMNS
	card.add_child(grid)
	for kind in Packs.CONTENT_KINDS:
		if contents.has(kind):
			grid.add_child(_content_toggle(pack, kind, int(contents[kind])))


func _content_toggle(pack: String, kind: String, count: int) -> CheckBox:
	var cb := Widgets.check_box("%s (%d)" % [Packs.CONTENT_KINDS[kind], count], Packs.is_enabled(pack, kind))
	cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cb.toggled.connect(func(on: bool) -> void: Packs.set_enabled(pack, kind, on))
	return cb


func _ask_remove(pack: String) -> void:
	var text := "Remove the imported data for %s?\n(Your original disc is not touched; you can import it again.)" % Packs.pack_name(pack)
	ConfirmDialog.ask(self, text, func() -> void: _remove(pack), "Remove", Widgets.DANGER)


func _remove(pack: String) -> void:
	ImportQueue.remove_pack(pack)
	router.replace("home")


# ------------------------------------------------------------------ soundtracks

func _add_soundtrack_section() -> void:
	content.add_child(Widgets.section("Soundtracks"))
	var flow := HFlowContainer.new()
	content.add_child(flow)
	var add := Widgets.small_button("Add soundtrack folder ...", _pick_soundtrack_folder)
	add.disabled = not ImportQueue.is_available()
	flow.add_child(add)
	var all := Soundtracks.all()
	for p in all:
		var text := "%s (%d)" % [all[p].name, all[p].tracks.size()]
		flow.add_child(Widgets.small_button(text, func() -> void: router.go("jukebox", {"pack": p})))
	if all.is_empty():
		content.add_child(Widgets.label("No music yet - add a folder of ripped soundtrack files (MP3/FLAC/WAV).", "DimLabel"))


func _pick_soundtrack_folder() -> void:
	var fd := _make_file_dialog(FileDialog.FILE_MODE_OPEN_DIR)
	fd.dir_selected.connect(func(dir: String) -> void: _library().imports.start_soundtracks(dir))
	fd.popup_centered_ratio(FILE_DIALOG_RATIO)


# ------------------------------------------------------------------ play

func _add_campaign_section() -> void:
	content.add_child(Widgets.section("Campaign"))
	var newest := SaveGames.find_newest_continuable()
	if not newest.is_empty():
		var cont := Widgets.button("Continue campaign", func() -> void: _library().open_launcher("continue"))
		cont.tooltip_text = SaveGames.make_row_text(newest)
		content.add_child(cont)
	var any_campaign := MatchFlow.make_new_campaign_choices().any(func(c: Dictionary) -> bool: return bool(c.playable))
	var new_campaign := Widgets.button("New campaign", func() -> void: _library().open_launcher("new_campaign"))
	new_campaign.disabled = not any_campaign
	content.add_child(new_campaign)
	content.add_child(Widgets.button("Load game", func() -> void: _library().open_launcher("load")))


func _add_play_section(can_play: bool) -> void:
	content.add_child(Widgets.section("Play"))
	var host := Widgets.button("Host LAN game", func() -> void: _library().open_launcher("host"))
	host.disabled = not can_play
	content.add_child(host)
	var join := Widgets.button("Join LAN game", func() -> void: _library().open_launcher(Launcher.JOIN_START_MODE))
	join.disabled = not can_play
	content.add_child(join)
	var coop := Widgets.button("Co-op missions (LAN)", func() -> void: _library().open_launcher("coop"))
	coop.disabled = not can_play
	content.add_child(coop)
	if WebPlatform.is_active():
		_disable_lan_buttons([host, join, coop])
	var more := Widgets.button("Skirmish, training, extraction ...", func() -> void: _library().open_launcher(Launcher.MENU_START_MODE))
	more.disabled = not can_play
	content.add_child(more)
	if Packs.packs.has("es1") and FileAccess.file_exists(Assets.path(ES1_SHELL_DATA, "es1")):
		content.add_child(Widgets.button("Metaltech: Earthsiege (original game)", _play_es1))
	var viewer := Widgets.button("Shape viewer", func() -> void: get_tree().change_scene_to_file(SHAPE_VIEWER))
	viewer.disabled = Packs.packs.is_empty()
	content.add_child(viewer)
	content.add_child(Widgets.button("Options", func() -> void: router.go("options", {"home": "home"})))
	content.add_child(Widgets.button("Tested game versions", func() -> void: router.go("versions")))


func _play_es1() -> void:
	Session.front_end = ES1_SHELL
	get_tree().change_scene_to_file(ES1_SHELL)


## Browser build: no LAN play (WebPlatform); says why next to the buttons.
func _disable_lan_buttons(buttons: Array) -> void:
	for b: Button in buttons:
		b.disabled = true
		b.tooltip_text = WebPlatform.NO_LAN_TEXT
	content.add_child(Widgets.paragraph(WebPlatform.NO_LAN_TEXT, "DimLabel"))

class_name LibraryHome
extends RoutedScreen
## Library home, in three tabs (TabPages). Play: the campaigns (Continue / New campaign / Load game open the launcher's
## campaign pages), Host LAN game (the standard lobby: the host picks co-op, the campaign, skirmish, training, extraction or
## any versus game mode there; alone it is a solo game against bots), Host online game (the same, also listed on the master
## server) and Join. Your library: import discs, switch each
## game's content on/off, and soundtracks. Options & tools: Play intro, the shape viewer, Run dedicated server (a headless
## server on this PC), Options (the pilot name, the master server address), Tested game versions. Leaving a match returns here on the Play tab (Session.front_end_tab). The tab last
## shown is kept while the app runs; with nothing imported the library tab opens first.

const SHAPE_VIEWER := "res://tools/shape_viewer.tscn"
const INTRO_MOVIE := "video/flic/intro3.ogv"
const PACK_GRID_COLUMNS := 3
const FILE_DIALOG_RATIO := 0.7
const PERCENT := 100.0
const TAB_PLAY := "play"
const TAB_LIBRARY := "library"
const TAB_TOOLS := "tools"
const HOST_TEXT := "Host LAN game"
const JOIN_TEXT := "Join LAN game"
const HOST_ONLINE_TEXT := "Host online game"
const NO_MASTER_TEXT := "Set the master server address first: Options & tools > Options > Online."

static var _last_tab := ""

var _bar: ProgressBar


func open(_args: Dictionary) -> void:
	set_page_title("library")
	MenuMusic.play_app_hub()
	set_back("Quit", _ask_quit)
	var can_play := not Packs.pilotable().is_empty()
	var primary := set_primary(HOST_TEXT, func() -> void: _library().open_launcher("host"))
	primary.disabled = not can_play or WebPlatform.is_active()
	var tabs := TabPages.new()
	content.add_child(tabs)
	var play := tabs.add_page(TAB_PLAY, "Play")
	var library := tabs.add_page(TAB_LIBRARY, "Your library")
	var tools := tabs.add_page(TAB_TOOLS, "Options & tools")
	_add_campaign_section(play)
	_add_play_section(play, can_play)
	_add_import_section(library)
	_add_packs_section(library)
	_add_soundtrack_section(library)
	_add_tools_section(tools)
	tabs.tab_changed.connect(func(id: String) -> void: _last_tab = id)
	tabs.apply_tab(make_start_tab())
	_follow_imports()


## The tab to open on: automation's `--tab=play|library|tools`, else the last one shown, else Play, or Your library while
## nothing is imported.
static func make_start_tab() -> String:
	var asked := ScreenRouter.arg_value("tab")
	if asked != "":
		return asked
	if Session.front_end_tab != "":
		_last_tab = Session.front_end_tab
		Session.front_end_tab = ""
	if _last_tab != "":
		return _last_tab
	return TAB_LIBRARY if Packs.packs.is_empty() else TAB_PLAY


func _library() -> Library:
	return router as Library


func _ask_quit() -> void:
	ConfirmDialog.ask(self, "Quit Siege Engine?", func() -> void:
		LocalServer.stop()
		get_tree().quit(), "Quit", Widgets.DANGER)


# ------------------------------------------------------------------ import

func _add_import_section(page: VBoxContainer) -> void:
	page.add_child(Widgets.section("Import"))
	var pick := Widgets.button("Import disc (.iso) ...", _pick_discs)
	pick.disabled = not ImportQueue.is_available()
	var hint := "Tip: drag .iso files onto this window. Multi-disc games: import all discs together."
	if WebPlatform.is_active():
		hint = WebPlatform.NO_IMPORT_TEXT
	elif not ImportQueue.is_available():
		hint = "The importer was not found next to the app."
	page.add_child(Widgets.row([pick, Widgets.paragraph(hint, "DimLabel")]))
	_bar = ProgressBar.new()
	_bar.visible = _library().imports.is_busy()
	page.add_child(_bar)


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

func _add_packs_section(page: VBoxContainer) -> void:
	var packs := Packs.packs.keys()
	var heading := "Games" if not packs.is_empty() else "Your library is empty - import a disc to begin."
	page.add_child(Widgets.section(heading))
	for p in packs:
		_add_pack_card(page, p)


func _add_pack_card(page: VBoxContainer, pack: String) -> void:
	var card := Widgets.card(page)
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

func _add_soundtrack_section(page: VBoxContainer) -> void:
	page.add_child(Widgets.section("Soundtracks"))
	var flow := HFlowContainer.new()
	page.add_child(flow)
	var add := Widgets.small_button("Add soundtrack folder ...", _pick_soundtrack_folder)
	add.disabled = not ImportQueue.is_available()
	flow.add_child(add)
	var all := Soundtracks.all()
	for p in all:
		var text := "%s (%d)" % [all[p].name, all[p].tracks.size()]
		flow.add_child(Widgets.small_button(text, func() -> void: router.go("jukebox", {"pack": p})))
	if all.is_empty():
		page.add_child(Widgets.label("No music yet - add a folder of ripped soundtrack files (MP3/FLAC/WAV).", "DimLabel"))


func _pick_soundtrack_folder() -> void:
	var fd := _make_file_dialog(FileDialog.FILE_MODE_OPEN_DIR)
	fd.dir_selected.connect(func(dir: String) -> void: _library().imports.start_soundtracks(dir))
	fd.popup_centered_ratio(FILE_DIALOG_RATIO)


# ------------------------------------------------------------------ play

func _add_campaign_section(page: VBoxContainer) -> void:
	page.add_child(Widgets.section("Campaign"))
	var newest := SaveGames.find_newest_continuable()
	if not newest.is_empty():
		var cont := Widgets.button("Continue campaign", func() -> void: _library().open_launcher("continue"))
		cont.tooltip_text = SaveGames.make_row_text(newest)
		page.add_child(cont)
	var any_campaign := MatchFlow.make_new_campaign_choices().any(func(c: Dictionary) -> bool: return bool(c.playable))
	var new_campaign := Widgets.button("New campaign", func() -> void: _library().open_launcher("new_campaign"))
	new_campaign.disabled = not any_campaign
	page.add_child(new_campaign)
	page.add_child(Widgets.button("Load game", func() -> void: _library().open_launcher("load")))


## Host LAN game opens the standard lobby, where the host picks the mode (every versus game mode, co-op, the co-op campaign,
## extraction, training), the map and the bots; with nobody joining it is a solo game against bots. Join opens the LAN browser.
func _add_play_section(page: VBoxContainer, can_play: bool) -> void:
	page.add_child(Widgets.section("Play"))
	var host := Widgets.button(HOST_TEXT, func() -> void: _library().open_launcher("host"))
	host.disabled = not can_play
	page.add_child(host)
	var host_online := Widgets.button(HOST_ONLINE_TEXT, func() -> void: _library().open_launcher("host_online"))
	host_online.disabled = not can_play or not OnlineSettings.has_master()
	host_online.tooltip_text = "Host a game and list it on your master server so others can find it." if OnlineSettings.has_master() else NO_MASTER_TEXT
	page.add_child(host_online)
	var join := Widgets.button("Join online game" if WebPlatform.is_active() else JOIN_TEXT, func() -> void: _library().open_launcher(Launcher.JOIN_START_MODE))
	join.disabled = not can_play
	page.add_child(join)
	if WebPlatform.is_active():
		_disable_lan_buttons(page, [host, host_online])


func _add_tools_section(page: VBoxContainer) -> void:
	page.add_child(Widgets.section("Tools"))
	var intro := Widgets.button("Play intro", func() -> void: MoviePlayer.play(self, INTRO_MOVIE))
	intro.disabled = not FileAccess.file_exists(Assets.path(INTRO_MOVIE))
	page.add_child(intro)
	var viewer := Widgets.button("Shape viewer", func() -> void: get_tree().change_scene_to_file(SHAPE_VIEWER))
	viewer.disabled = Packs.packs.is_empty()
	page.add_child(viewer)
	var server := Widgets.button("Run dedicated server...", func() -> void: ServerSheet.open(self))
	server.disabled = Packs.pilotable().is_empty() or WebPlatform.is_active()
	server.tooltip_text = "Starts a headless server on this PC that others can join by IP; stop it from the same sheet."
	page.add_child(server)
	page.add_child(Widgets.button("Options", func() -> void: router.go("options", {"home": "home"})))
	page.add_child(Widgets.button("Tested game versions", func() -> void: router.go("versions")))


## Browser build: no LAN play (WebPlatform); says why next to the buttons.
func _disable_lan_buttons(page: VBoxContainer, buttons: Array) -> void:
	for b: Button in buttons:
		b.disabled = true
		b.tooltip_text = WebPlatform.NO_LAN_TEXT
	page.add_child(Widgets.paragraph(WebPlatform.NO_LAN_TEXT, "DimLabel"))

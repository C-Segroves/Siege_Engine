extends RoutedScreen
## About / tested game versions: the release each installed game was imported from (pack.json "release") and
## whether the Siege Engine was tested with it (GameReleases), then the table of tested releases. A pack imported
## before releases were recorded offers Identify: the importer reads only the disc's executable (identify-release).

const TABLE_COLUMNS := 4
const FILE_DIALOG_RATIO := 0.7

var _importer: DiscImporter


func open(_args: Dictionary) -> void:
	set_page_title("tested game versions")
	set_back("Back", router.back)
	content.add_child(Widgets.paragraph("Siege Engine reads the game data from your own discs. Each import records "
		+ "which release the disc holds; the releases below are the ones the engine was tested with.", "DimLabel"))
	_add_installed_section()
	_add_tested_section()


func _add_installed_section() -> void:
	content.add_child(Widgets.section("Your games"))
	if Packs.packs.is_empty():
		content.add_child(Widgets.label("No games imported yet.", "DimLabel"))
	for pack in Packs.packs:
		_add_pack_card(str(pack))


func _add_pack_card(pack: String) -> void:
	var card := Widgets.card(content)
	card.add_child(Widgets.label(Packs.pack_name(pack)))
	var status := GameReleases.make_status(pack)
	var variation := "DimLabel" if status == GameReleases.TESTED else "StatusLabel"   # amber: a gentle warning
	card.add_child(Widgets.paragraph(GameReleases.make_status_text(pack), variation))
	var release := GameReleases.pack_release(pack)
	if not release.is_empty() and status != GameReleases.UNIDENTIFIED:
		card.add_child(Widgets.paragraph("%s   disc %s %s" % [GameReleases.make_exe_text(release),
			release.get("label", ""), release.get("mastered", "")], "DimLabel"))
	if status == GameReleases.UNIDENTIFIED and DiscImporter.available():
		card.add_child(_make_identify_button(pack))


## "Identify from <image>" when pack.json names the disc image it came from, else a disc image picker.
func _make_identify_button(pack: String) -> Button:
	var iso := GameReleases.source_disc_path(pack)
	if iso != "":
		return Widgets.small_button("Identify from %s" % iso.get_file(), func() -> void: _identify(pack, iso))
	return Widgets.small_button("Identify from disc image ...", func() -> void: _pick_disc(pack))


func _pick_disc(pack: String) -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.filters = PackedStringArray(["*.iso, *.cue, *.bin ; Disc images"])
	fd.file_selected.connect(func(path: String) -> void: _identify(pack, path))
	add_child(fd)
	fd.popup_centered_ratio(FILE_DIALOG_RATIO)


func _identify(pack: String, iso: String) -> void:
	if _importer != null and _importer.is_busy():
		return
	_importer = DiscImporter.new()
	add_child(_importer)
	_importer.progress.connect(func(_f: float, message: String) -> void: set_status(message))
	_importer.finished.connect(_on_identified)
	set_status("Identifying %s from %s ..." % [Packs.pack_name(pack), iso.get_file()])
	_importer.start_identify_release(pack, iso)


func _on_identified(ok: bool, _pack: String, message: String) -> void:
	if ok:
		router.replace("versions")
	else:
		set_status(message)


func _add_tested_section() -> void:
	content.add_child(Widgets.section("Tested versions (%s)" % GameReleases.tested_on()))
	var grid := GridContainer.new()
	grid.columns = TABLE_COLUMNS
	content.add_child(grid)
	for heading in ["Game", "Version", "Patch", "Result"]:
		grid.add_child(Widgets.label(heading, "DimLabel"))
	for e: Dictionary in GameReleases.tested_releases():
		for text in [e.get("name", ""), e.get("version", ""), e.get("patch", ""), e.get("result", "")]:
			var cell := Widgets.label(str(text))
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(cell)

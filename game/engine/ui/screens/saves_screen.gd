extends LauncherScreen
## Save / Load: every campaign save of the shared store (SaveGames; the original Earthsiege shell's careers
## and backups included), newest first, each with its name, kind, campaign, mission, date and playtime.
## args: {"mode": "save" | "load", "return_to": screen Back opens (default "menu")}.
##   save  a name field and Save (an existing name asks before it is overwritten); a saved game's row
##         overwrites it (asked first). Saving happens between missions only: this screen is reached from
##         the briefing and the saga's side choice, never from the in-battle menu.
##   load  a row loads its save and opens the campaign; finished campaigns and saves of games that are not
##         installed are shown but cannot be loaded.
## Every row has Delete (asked first).

const MODE_SAVE := "save"
const MODE_LOAD := "load"
const NO_SAVES := "No saved games yet."
const OVERWRITE_QUESTION := "A save called '%s' already exists. Overwrite it?"
const DELETE_QUESTION := "Delete the save '%s'? This cannot be undone."

var _mode := MODE_LOAD
var _return_to := "menu"
var _name_edit: LineEdit


func open(args: Dictionary) -> void:
	_mode = str(args.get("mode", MODE_LOAD))
	_return_to = str(args.get("return_to", "menu"))
	set_page_title("save game" if _mode == MODE_SAVE else "load game")
	if _mode == MODE_SAVE:
		MenuMusic.play_for_campaign("briefing")
	else:
		MenuMusic.play_app_hub()
	set_back("Back", router.back)
	if _mode == MODE_SAVE:
		_add_save_row()
		set_primary("Save", func() -> void: _ask_save(_name_edit.text.strip_edges()))
	else:
		set_primary("New campaign", func() -> void: router.go("new_campaign"))
	_add_save_list()


func _add_save_row() -> void:
	_name_edit = Widgets.line_edit(Session.pilot_name, "Save name")
	_name_edit.text_submitted.connect(func(t: String) -> void: _ask_save(t.strip_edges()))
	content.add_child(OptionRow.new("Save name", _name_edit))


func _add_save_list() -> void:
	content.add_child(Widgets.section("Saved games"))
	var entries := SaveGames.list_entries()
	if entries.is_empty():
		content.add_child(Widgets.label(NO_SAVES, "DimLabel"))
	for e in entries:
		content.add_child(_make_row(e))


## [save / load button  |  Delete]
func _make_row(entry: Dictionary) -> HBoxContainer:
	var text := SaveGames.make_row_text(entry)
	var main := Widgets.button(text, func() -> void: _choose(entry))
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if _mode == MODE_LOAD:
		var block := SaveGames.make_block_reason(entry)
		main.disabled = block != ""
		if block != "":
			main.text = text.replace("\n", "  (%s)\n" % block)
	else:
		main.disabled = str(entry.get("kind", "")) != SaveGames.KIND_MANUAL
	var delete := Widgets.small_button("Delete", func() -> void: _ask_delete(entry), Widgets.DANGER)
	return Widgets.row([main, delete])


func _choose(entry: Dictionary) -> void:
	if _mode == MODE_SAVE:
		_ask_save(str(entry.get("name", "")))
	else:
		_load(str(entry.id))


func _load(id: String) -> void:
	if Session.load_save(id):
		launcher().show_campaign()
	else:
		set_status("This save cannot be loaded.")


## Saves under `save_name`, asking first when a save of that name exists.
func _ask_save(save_name: String) -> void:
	if save_name == "":
		set_status("Enter a name for the save.")
		return
	if SaveGames.exists(SaveGames.make_manual_id(save_name)):
		ConfirmDialog.ask(self, OVERWRITE_QUESTION % save_name, func() -> void: _save(save_name), "Overwrite", Widgets.DANGER)
	else:
		_save(save_name)


func _save(save_name: String) -> void:
	var ok := Session.save_manual(save_name) != ""
	router.replace("saves", {"mode": _mode, "return_to": _return_to}).set_status(
		("Saved '%s'." if ok else "Could not save '%s'.") % save_name)


func _ask_delete(entry: Dictionary) -> void:
	var save_name := str(entry.get("name", ""))
	ConfirmDialog.ask(self, DELETE_QUESTION % save_name, func() -> void: _delete(entry), "Delete", Widgets.DANGER)


func _delete(entry: Dictionary) -> void:
	SaveGames.delete(str(entry.id))
	router.replace("saves", {"mode": _mode, "return_to": _return_to}).set_status("Deleted '%s'." % str(entry.get("name", "")))

extends LauncherScreen
## New campaign: the pilot (and save) name and which campaign to fly - the saga or one game's campaign
## (MatchFlow.make_new_campaign_choices), each with a short description; campaigns whose game is not
## installed are shown but cannot be chosen. Start writes the pilot's autosave at once (asking first when
## that pilot already has an unfinished autosave of the same campaign) and opens the campaign.
## The multiplayer-only launcher (the original shell's MULTIPLAYER) offers Earthsiege's campaign only.

const NOT_INSTALLED := "  (not installed)"
const RESTART_QUESTION := "%s already flies a %s campaign (autosaved). Start a new one?\nIts autosave is replaced; named saves are kept."

var _name_edit: LineEdit
var _choices: Array = []
var _boxes: Array[CheckBox] = []


func open(_args: Dictionary) -> void:
	set_page_title("new campaign")
	MenuMusic.play_app_hub()
	set_back("Back", router.back)
	set_primary("Start campaign", _ask_start)
	_name_edit = Widgets.line_edit(Net.player_name, SaveGames.DEFAULT_PILOT)
	content.add_child(OptionRow.new("Pilot name", _name_edit))
	content.add_child(Widgets.section("Campaign"))
	_add_choices()


func _add_choices() -> void:
	var group := ButtonGroup.new()
	for choice in MatchFlow.make_new_campaign_choices():
		if launcher().multiplayer_only and choice.pack != MatchFlow.FIRST_CAMPAIGN_PACK:
			continue
		var box := Widgets.check_box(str(choice.text) + ("" if choice.playable else NOT_INSTALLED), false)
		box.button_group = group
		box.disabled = not choice.playable
		content.add_child(box)
		content.add_child(Widgets.paragraph(str(choice.description), "DimLabel"))
		_choices.append(choice)
		_boxes.append(box)
	for box in _boxes:
		if not box.disabled:
			box.button_pressed = true
			break


## The chosen campaign ({} when none can be played).
func chosen() -> Dictionary:
	for i in _boxes.size():
		if _boxes[i].button_pressed and not _boxes[i].disabled:
			return _choices[i]
	return {}


func _ask_start() -> void:
	var choice := chosen()
	var pilot := _name_edit.text.strip_edges()
	if choice.is_empty():
		set_status("No campaign can be played: import its game first.")
		return
	if pilot == "":
		set_status("Enter the pilot's name.")
		return
	var id := SaveGames.make_autosave_id(str(choice.key), pilot)
	var existing := SaveGames.read(id)
	if not existing.is_empty() and not bool(SaveGames.make_entry(id, existing).get("finished", false)):
		ConfirmDialog.ask(self, RESTART_QUESTION % [pilot, str(choice.text)], func() -> void: _start(choice, pilot),
			"Start over", Widgets.DANGER)
	else:
		_start(choice, pilot)


func _start(choice: Dictionary, pilot: String) -> void:
	Net.player_name = pilot
	Session.start_new_campaign(choice, pilot)
	launcher().show_campaign()

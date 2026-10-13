extends LauncherScreen
## Pre-mission briefing: briefing text, objectives, and the Herc to take - one of the campaign's
## garage (built, scrapped and armed in the Hangar screen) or the Herc the mission issues (Earthsiege 2,
## Starsiege), which is chosen first. Back from the hangar, the garage's selected Herc is chosen.
## Save game opens the Save / Load screen (saving happens here, between missions); Launch writes the
## "before mission" restore point a killed pilot replays from; Back autosaves and leaves the campaign.

## The talking heads go under the mission heading.
const TALK_INDEX := 1

var _garage_picker: GaragePicker


func open(args: Dictionary) -> void:
	set_page_title("briefing")
	MenuMusic.play_for_campaign("briefing")
	set_back("Save and quit to menu", _save_and_quit)
	set_primary("Launch mission", _launch)
	var text := Session.briefing()
	content.add_child(Widgets.section(MatchFlow.make_mission_heading()))
	content.add_child(Widgets.paragraph(String(text.get("briefing", ""))))
	var objectives: Array = text.get("objectives", []) if text.get("objectives") is Array else []
	if not objectives.is_empty():
		content.add_child(Widgets.section("Objectives"))
		content.add_child(Widgets.paragraph("- " + "\n- ".join(PackedStringArray(objectives))))
	_garage_picker = GaragePicker.new(show_hangar(), Session.garage(), Session.mission_herc(),
		func() -> void: launcher().open_hangar("briefing"))
	content.add_child(_garage_picker)
	content.add_child(Widgets.button("Save game", func() -> void: router.go("saves", {"mode": "save", "return_to": "briefing"})))
	if args.get("from_hangar", false):
		_garage_picker.select_garage()
	if CampaignPresentation.take_first_showing(CampaignPresentation.MOMENT_BRIEFING, MatchFlow.make_mission_heading()):
		_present_mission({"mission": Session.current_mission()})


## The campaign's briefing movies, then its talking heads above the briefing text (once per mission).
func _present_mission(context: Dictionary) -> void:
	var c: Object = Session.campaign
	await MoviePlayer.play_all(self, CampaignPresentation.make_movies(c, CampaignPresentation.MOMENT_BRIEFING, context))
	if is_inside_tree():
		ShellTalkPanel.add_to(content, CampaignPresentation.make_talks(c, CampaignPresentation.MOMENT_BRIEFING, context), TALK_INDEX)


func _launch() -> void:
	var e := _garage_picker.entry()
	if not Session.coop:
		Session.save_restore_point({"vehicle": str(e.vehicle), "loadout": e.loadout, "garage": e.get("garage", {})})
	launcher().start_battle(MatchFlow.make_mission_config(str(e.vehicle), e.loadout, e.get("garage", {})))


func _save_and_quit() -> void:
	Session.autosave()
	Session.clear_campaign()
	launcher().go_main_menu()


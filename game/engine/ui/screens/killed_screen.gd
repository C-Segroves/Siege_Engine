extends LauncherScreen
## The pilot was killed in a campaign mission (Session.must_replay): like the originals the mission is not
## counted. Replay reloads the restore point written at launch and flies the mission again in the same Herc;
## Quit to main menu leaves the campaign at its last save. Earthsiege plays its death song (GO.EXE 0x3bc94),
## the other games their menu music. The prompt is each game's own (CampaignPresentation "killed_prompt").

const HEADER := "KILLED IN ACTION"


func open(_args: Dictionary) -> void:
	set_page_title("killed in action")
	var pack := Session.campaign_pack(Session.campaign) if Session.campaign != null else ""
	MenuMusic.play_pilot_killed(pack)
	focus_primary_first = true
	set_back("Quit to main menu", _quit)
	set_primary("Replay mission", _replay)
	content.add_child(Widgets.label(HEADER, "HeaderLabel"))
	content.add_child(Widgets.paragraph(str(CampaignPresentation.of(Session.campaign).killed_prompt)))
	content.add_child(Widgets.paragraph(MatchFlow.make_mission_heading(), "DimLabel"))
	MoviePlayer.play_all(self, CampaignPresentation.make_movies(Session.campaign, CampaignPresentation.MOMENT_KILLED))


## Back to the restore point, then the same mission again (the campaign lobby when the launch was not recorded).
func _replay() -> void:
	MatchFlow.replay_mission(launcher())


## The campaign stays at its last save.
func _quit() -> void:
	Session.last_result = {}
	Session.clear_campaign()
	launcher().go_main_menu()

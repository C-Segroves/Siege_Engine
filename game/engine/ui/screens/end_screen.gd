extends LauncherScreen
## End of a campaign or the saga (victory / game over). args: {"text": message, "replay": a lost campaign
## offers to replay its last mission from the restore point, like the originals (MatchFlow.make_campaign_lost_page)}.


func open(args: Dictionary) -> void:
	set_page_title("campaign over")
	if Session.campaign != null:
		MenuMusic.play_campaign_end(Session.campaign_pack(Session.campaign), Session.campaign.is_victory())
	if bool(args.get("replay", false)):
		focus_primary_first = true
		set_primary("Replay mission", func() -> void: MatchFlow.replay_mission(launcher()))
		set_back("Main menu", _leave)
	else:
		set_primary("Main menu", _leave)
		set_back("Back", _leave)
	content.add_child(Widgets.label(str(args.get("text", "")), "HeaderLabel"))
	if Session.campaign != null:
		var moment := CampaignPresentation.MOMENT_VICTORY if Session.campaign.is_victory() else CampaignPresentation.MOMENT_DEFEAT
		MoviePlayer.play_all(self, CampaignPresentation.make_movies(Session.campaign, moment))


func _leave() -> void:
	Session.campaign = null
	launcher().go_main_menu()

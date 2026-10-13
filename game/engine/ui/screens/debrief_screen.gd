extends LauncherScreen
## Debriefing after a campaign mission: result and text. The result is recorded (and autosaved) as the
## screen opens, so a finished mission is never lost; Continue goes on with the campaign. A campaign that
## flies a failed mission again (Starsiege) offers Replay mission instead, from the restore point.


## The talking heads go under the headline.
const TALK_INDEX := 1


func open(_args: Dictionary) -> void:
	set_page_title("debriefing")
	MenuMusic.play_for_campaign("debrief")
	set_back("Main menu", func() -> void: launcher().go_main_menu())
	var r := Session.last_result
	if not r.get("success", false) and Session.replays_failed_missions() and Session.has_restore_point():
		set_primary("Replay mission", func() -> void: MatchFlow.replay_mission(launcher()))
	else:
		set_primary("Continue", _continue)
	content.add_child(Widgets.label(MissionOutcome.make_headline(r), "HeaderLabel"))
	content.add_child(Widgets.paragraph(String(r.get("text", ""))))
	_present_result(Session.campaign, {"result": r})
	MatchFlow.apply_mission_result()


## The campaign's debriefing movies, then its talking heads under the headline.
func _present_result(c: Object, context: Dictionary) -> void:
	await MoviePlayer.play_all(self, CampaignPresentation.make_movies(c, CampaignPresentation.MOMENT_DEBRIEF, context))
	if is_inside_tree():
		ShellTalkPanel.add_to(content, CampaignPresentation.make_talks(c, CampaignPresentation.MOMENT_DEBRIEF, context), TALK_INDEX)


func _continue() -> void:
	var next := MatchFlow.make_next_after_debrief()
	if next.screen == "end":
		router.replace("end", {"text": next.text, "replay": next.get("replay", false)})
	elif next.screen == "lobby":
		router.replace("lobby")
	else:
		launcher().show_campaign()

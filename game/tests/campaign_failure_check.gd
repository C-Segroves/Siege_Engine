extends Node
## What a failed or aborted campaign mission does in each game, matched to the originals (playtest E2):
##   Godot --headless --audio-driver Dummy --path game res://tests/campaign_failure_check.tscn
## * Earthsiege: the campaign moves on to the slot's failure variant (GO.EXE 0x159e9 / 0x141d0); a mission
##   counts as failed when its debriefing code is above the type's threshold, even if its objective was met.
## * Earthsiege 2: a failed ordinary mission moves on, a failed must-win mission loses the war (VSHELL
##   0x412dc7); the lost war offers to replay the mission from the restore point.
## * Starsiege: a failed mission is flown again; the debriefing offers Replay mission (restore point).
## The player's saves are backed up and restored (SavedCampaignGuard).

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
## Earthsiege campaign C0: slot 3 plays 3A after a won slot 2, 3B after a lost one (btlset_0.dat).
const ES1_FAILURE_SLOT := 3
const RESCUE_MISSION_TYPE := 5
const RESCUE_HEAVY_DAMAGE_CODE := 4
const TEST_PILOT := "E2 Tester"

var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	var guard := SavedCampaignGuard.new()
	guard.back_up()
	_check_es1_moves_on()
	_check_es1_failure_threshold()
	_check_es2_must_win()
	_check_starsiege_replays()
	_check_lost_war_replay_page()
	Session.clear_campaign()
	guard.restore()
	print("campaign_failure_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _check_es1_moves_on() -> void:
	print("Earthsiege: a failed mission moves on to the failure variant")
	var c := Campaign.start(0, 7)
	for i in ES1_FAILURE_SLOT - 1:
		c.record_result(true)
	var flown := c.current_mission()
	c.record_result(false)
	_expect(c.current_mission() != flown and c.slot == ES1_FAILURE_SLOT, "the campaign goes on to slot %d (%s)" % [ES1_FAILURE_SLOT, c.current_mission()])
	_expect(c.current_mission().ends_with("3B"), "the slot plays its failure variant 3B")


func _check_es1_failure_threshold() -> void:
	print("Earthsiege: the debriefing code decides success (GO.EXE 0x159e9)")
	var rt := MissionRuntime.new()
	rt.m = {"header": {"mission_type": RESCUE_MISSION_TYPE}, "texts": {"debriefings": ["", "", "", "", "", "", "", ""]}}
	_expect(rt._is_failure_code(RESCUE_HEAVY_DAMAGE_CODE), "a rescue won with heavy damage (code 4) counts as failed")
	_expect(not rt._is_failure_code(MissionRuntime.CODE_SUCCESS_BASE), "a rescue won with light damage counts as won")
	_expect(rt._failure_code(0) == 5 and rt._failure_code(MissionRuntime.DAMAGE_HERC_LOST) == 8, "failure codes are the last four debriefings (5..8)")
	rt.free()


func _check_es2_must_win() -> void:
	print("Earthsiege 2: ordinary missions move on, must-win missions lose the war")
	var c := CampaignES2.start(1, 7)
	var flown := c.current_mission()
	c.record_result(false)
	_expect(not c.is_over() and c.current_mission() != flown, "a failed ordinary mission moves on (%s -> %s)" % [flown, c.current_mission()])
	while c.slot < c.campaign_missions().size() - 1:
		c.record_result(true)
	c.record_result(false)
	_expect(c.is_game_over(), "failing the career's last mission loses the war")
	c.replay()
	_expect(not c.is_over(), "replay() goes back to before the lost mission")


func _check_starsiege_replays() -> void:
	print("Starsiege: a failed mission is flown again")
	Session.clear_campaign()
	Session.pilot_name = TEST_PILOT
	Session.start_stage_campaign("starsiege", "human")
	if Session.campaign == null:
		print("  skip: no Starsiege pack")
		return
	var flown: String = Session.campaign.current_mission()
	Session.save_restore_point({})
	Session.last_result = {"success": false, "vars": PackedInt32Array()}
	Session.finish_mission()
	_expect(Session.campaign.current_mission() == flown, "the failed mission is next again (%s)" % flown)
	_expect(Session.replays_failed_missions(), "the campaign reports that it replays failed missions")
	_expect(Session.has_restore_point(), "the restore point to replay from exists")
	Session.replay_from_restore_point()
	_expect(Session.campaign != null and Session.campaign.current_mission() == flown, "Replay mission reloads the restore point")


func _check_lost_war_replay_page() -> void:
	print("Earthsiege 2: the lost war offers Replay mission")
	Session.clear_campaign()
	Session.pilot_name = TEST_PILOT
	Session.start_stage_campaign("es2")
	if Session.campaign == null:
		print("  skip: no Earthsiege 2 pack")
		return
	_expect(not Session.replays_failed_missions(), "Earthsiege 2 moves on after an ordinary failure")
	Session.save_restore_point({})
	var page := MatchFlow.make_campaign_lost_page()
	_expect(page.screen == "end" and bool(page.get("replay", false)), "the game-over page offers to replay from the restore point")

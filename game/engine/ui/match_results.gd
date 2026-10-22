class_name MatchResults
extends ScreenRouter
## The results screen after every match, in every game and mode (its page is
## engine/ui/screens/results_screen.gd). `summary` is the battle's BattleSummary dictionary.
##   Continue -> the front end the battle was started from (Session.front_end_scene(): launcher -
##               which opens the campaign debriefing or the LAN lobby -, the original shell, library)
##   Rematch  -> skirmish / versus / co-op: the same match again (LAN: only the host, for everybody)
## On LAN it follows the session: a match the host starts begins here too, and the host leaving
## returns to the front end with that message.
##   MatchResults.open_in_place_of(battle, summary)
## A LAN pilot is paid the credits the host's summary awards him (ResultsAward, EconomyNet) before the page opens; `award` holds
## what he was paid ({} when nothing) and `credits_after` his new balance.

const SCREENS := {"results": "res://engine/ui/screens/results_screen.gd"}

var summary := {}
var award := {}
var credits_after := 0


## Replaces `old_scene` (the finished battle) with the results screen for `p_summary`.
static func open_in_place_of(old_scene: Node, p_summary: Dictionary) -> MatchResults:
	var results := MatchResults.new()
	results.name = "MatchResults"
	results.summary = p_summary
	ScreenRouter.replace_current_scene(old_scene.get_tree(), results, old_scene)
	return results


func _ready() -> void:
	super()
	Net.game_starting.connect(start_battle)
	Net.session_ended.connect(_on_session_ended)
	pay_award()
	go("results")


func make_screen_paths() -> Dictionary:
	return SCREENS


## Pays the local pilot what this match earned him into his operator profile. Offline matches, dedicated servers and raids
## (paid on extraction) pay nothing here.
func pay_award() -> void:
	if not Net.is_online() or Net.dedicated:
		return
	award = ResultsAward.for_pilot(summary, Net.player_name)   # the host made it (BattleSummary); this machine only pays it
	if award.is_empty():
		return
	var economy := EconomyNet.new()
	economy.name = "EconomyNet"
	economy.authority = LocalProfileAuthority.new(Net.player_name)
	add_child(economy)
	economy.send_award(Net.my_id(), award)
	credits_after = OperatorProfile.load_for(Net.player_name).credits


## True when this peer may start a rematch.
func can_rematch() -> bool:
	if not bool(summary.get("rematch", false)):
		return false
	return Net.is_host() if Net.is_online() else true


func rematch() -> void:
	if Net.is_online():
		MatchFlow.start_hosted_match()   # every peer's results screen receives game_starting
	else:
		start_battle((summary.get("rematch_config", {}) as Dictionary).duplicate(true))


## Starts a battle with `cfg` (a rematch, or the LAN host starting the next match).
func start_battle(cfg: Dictionary) -> void:
	var scene_path := str(summary.get("battle_scene", ""))
	if scene_path == "" or not ResourceLoader.exists(scene_path):
		push_error("MatchResults: no battle scene to start ('%s')" % scene_path)
		return
	var battle: Node = load(scene_path).instantiate()
	battle.set("config", cfg)
	replace_with(battle)


func continue_to_front_end() -> void:
	Session.show_play_tab()
	get_tree().change_scene_to_file(Session.front_end_scene())


func _on_session_ended(reason: String) -> void:
	Session.front_end_status = reason
	continue_to_front_end()

class_name RaidResultExit
extends Node
## A pilot of a persistent raid (a dedicated extraction server) whose raid is over - extracted, or killed in action: the world
## goes on without him. He sees the banner for a few seconds (config "results_hold_s", the server's results_hold_seconds), then leaves
## the server and gets a results screen; Continue returns to the party, or to the main menu without one.
## (A LAN raid ends for everybody together, with the match results.)
##   RaidResultExit.begin(director, result, stacks, money)     the director's _raid_result on a client

const NODE_NAME := "ResultExit"
const HOLD_KEY := "results_hold_s"
const DEFAULT_HOLD_SECONDS := 5.0
const MAX_HAUL_LINES := 14

var director: ExtractionDirector
var summary := {}


static func begin(p_director: ExtractionDirector, result: String, stacks: Array, money: int) -> void:
	if p_director.battle.has_node(NODE_NAME):
		return
	var node := RaidResultExit.new()
	node.name = NODE_NAME
	node.director = p_director
	node.summary = make_summary(p_director.battle, result, stacks, money)
	p_director.battle.add_child(node)


func _ready() -> void:
	var hold := float(director.battle.config.get(HOLD_KEY, DEFAULT_HOLD_SECONDS))
	get_tree().create_timer(hold).timeout.connect(_leave)


func _leave() -> void:
	if not is_inside_tree():
		return
	Net.leave_quiet()
	MatchResults.open_in_place_of(director.battle, summary)


## The results screen's data (BattleSummary form) for a pilot whose raid ended with `result` (ExtractionDirector.STATUS_*).
## `stacks` and `money` are his haul (extracted) or what his insured slot kept (killed).
static func make_summary(battle: Battle, result: String, stacks: Array, money: int) -> Dictionary:
	var extracted := result == ExtractionDirector.STATUS_EXTRACTED
	var inventory := ExtractionInventory.new()
	inventory.apply_merge(stacks)
	inventory.money = money
	var lines := PackedStringArray(stacks.slice(0, MAX_HAUL_LINES).map(func(s: Array) -> String: return ExtractionItems.make_stack_text(str(s[0]), int(s[1]))))
	var haul := "%s%s" % [ExtractionRules.make_money_text(money) + "\n" if money > 0 else "", "\n".join(lines)]
	var text := ("You extracted with %s worth of loot.\n%s" % [ExtractionRules.make_money_text(inventory.make_value()), haul]) if extracted \
		else ("Everything you carried is lost.%s" % ("\nYour insured slot kept:\n" + haul if not stacks.is_empty() else ""))
	return {"mode": ExtractionRules.MODE, "headline": "EXTRACTED" if extracted else "KILLED IN ACTION", "winner": "", "text": text,
		"seconds": battle.match_seconds(), "pilots": [], "enemies_destroyed": 0, "salvage": [], "losses": [], "campaign": false,
		"aborted": false, "rematch": false, "rematch_config": {}, "awards": {},
		"battle_scene": battle.scene_file_path if battle.scene_file_path != "" else BattleSummary.DEFAULT_BATTLE_SCENE}

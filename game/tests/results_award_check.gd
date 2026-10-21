extends Node
## The credits a match pays (docs/design/lobby_loadout_economy.md sections 2.5, 5.4 and 7.2): BattleStats counts what the
## goals need on the host (assists, vehicle and bot kills, damage, time alive, flags), the host makes every pilot's award
## from those numbers (ResultsAward.make_all) and sends it in the summary, so each goal kind pays when met and not
## otherwise and a client holds exactly the award the host made.
##   godot --headless --audio-driver Dummy --path game res://tests/results_award_check.tscn

const SETTINGS := {"mode": "vs", "game_mode": "ctf"}
const PILOT := "Ace"
## Goal id -> the row field that completes it.
const GOAL_FIELDS := {"kills10": "kills", "kills20": "kills", "vehicles3": "vehicle_kills", "survive": "survived",
	"objectives2": "objectives", "flag2": "flag_captures"}

var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	_check_every_goal_kind()
	_check_ledger_rates()
	_check_host_and_client_agree()
	_check_battle_stats()
	print("results_award_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _summary(row_stats := {}) -> Dictionary:
	var row := {"name": PILOT, "team": 0, "kills": 0, "deaths": 0, "player": true, "survived": false}
	row.merge(row_stats, true)
	return {"mode": "vs", "seconds": 300.0, "winner": "Red", "pilots": [row]}


func _goal_lines(award: Dictionary) -> Array:
	return (award.get("lines", []) as Array).filter(func(l: Dictionary) -> bool: return str(l.text).begins_with("Goal:"))


func _total(row_stats: Dictionary, picked := []) -> int:
	return int(ResultsAward.make(_summary(row_stats), SETTINGS, PILOT, picked).get("total", 0))


## The credits goal `id` adds when the pilot picked it and his row is `row_stats`.
func _goal_pay(id: String, row_stats: Dictionary) -> int:
	return _total(row_stats, [id]) - _total(row_stats)


func _find_goal(board: Array, id: String) -> Dictionary:
	for g in board:
		if g.id == id:
			return g
	return {}


func _check_every_goal_kind() -> void:
	print("goals:")
	var board := LobbyGoals.make_board(SETTINGS)
	for id in GOAL_FIELDS:
		var goal := _find_goal(board, id)
		_expect(not goal.is_empty(), "the board of a CTF match offers %s" % id)
		if goal.is_empty():
			continue
		var field: String = GOAL_FIELDS[id]
		var met_row := {field: true if field == "survived" else int(goal.count)}
		var short_row := {field: false if field == "survived" else int(goal.count) - 1}
		_expect(_goal_pay(id, met_row) == int(goal.reward), "%s pays %d cr when met" % [id, int(goal.reward)])
		_expect(_goal_pay(id, short_row) == 0, "%s pays nothing when not met" % id)
	var unpicked := ResultsAward.make(_summary({"kills": 30, "vehicle_kills": 9, "survived": true}), SETTINGS, PILOT, [])
	_expect(_goal_lines(unpicked).is_empty(), "a goal he did not pick pays nothing")
	_expect(GoalBoard.is_done({"kind": "assists", "count": 3}, {"assists": 3}) and not GoalBoard.is_done({"kind": "assists", "count": 3}, {"assists": 2}),
		"an assists goal reads the assists stat")
	_expect(GoalBoard.is_done({"kind": "damage", "count": 500}, {"damage": 600}) and GoalBoard.is_done({"kind": "seconds_alive", "count": 120}, {"seconds_alive": 130.0}),
		"damage and time alive goals read their stats")
	_expect(GoalBoard.is_done({"kind": "extractions", "count": 1}, {"extractions": 1}), "an extractions goal reads the extractions stat")


func _check_ledger_rates() -> void:
	print("rates:")
	var row := EconomyRules.make_earn_row(EconomyRules.make_mode_key(SETTINGS))
	var base := _total({})
	_expect(_total({"vehicle_kills": 2}) - base == 2 * int(row.per_vehicle_kill), "vehicle kills pay per_vehicle_kill")
	_expect(_total({"assists": 3}) - base == 3 * int(row.per_assist), "assists pay per_assist")
	_expect(_total({"objectives": 2}) - base == 2 * int(row.per_objective), "objectives pay per_objective")
	var human := _total({"kills": 4}) - base
	var bots := _total({"kills": 4, "bot_kills": 4}) - base
	_expect(human == 4 * int(row.per_kill) and bots < human and bots > 0, "bot kills pay less than pilot kills and are not paid twice")


func _check_host_and_client_agree() -> void:
	print("host and client:")
	var summary := _summary({"kills": 12, "survived": true, "assists": 2})
	summary.pilots.append({"name": "Other", "team": 1, "kills": 1, "deaths": 3, "player": true, "survived": false})
	var picked := {PILOT: ["kills10", "survive"], "Other": ["kills10"]}
	summary["awards"] = ResultsAward.make_all(summary, SETTINGS, picked)
	_expect((summary.awards as Dictionary).has(PILOT) and (summary.awards as Dictionary).has("Other"), "the host makes an award for every pilot row")
	var wire: Dictionary = bytes_to_var(var_to_bytes(summary))   # what the _finish rpc carries
	_expect(ResultsAward.for_pilot(wire, PILOT) == ResultsAward.for_pilot(summary, PILOT), "the client holds the host's award as made")
	_expect(_goal_lines(ResultsAward.for_pilot(wire, PILOT)).size() == 2, "his two picked goals are in his award")
	_expect(_goal_lines(ResultsAward.for_pilot(wire, "Other")).is_empty(), "another pilot's award is his own")
	_expect(ResultsAward.for_pilot(wire, "Nobody").is_empty(), "a name the host did not award gets nothing")
	_expect(ResultsAward.for_pilot({"pilots": summary.pilots}, PILOT).is_empty(), "a summary without the host's awards pays nothing")


func _check_battle_stats() -> void:
	print("battle stats:")
	var battle := Battle.new()
	var stats := BattleStats.new(battle)
	var me := _herc(1, PILOT, 0)
	var friend := _herc(2, "Friend", 0)
	var bot := _herc(3, "Bot", 1, true)
	var target := _herc(4, "Target", 1)
	for h in [me, friend, bot, target]:
		battle.vehicles[h.net_id] = h
		stats.watch(h)
	target.components[0].hp = 60.0
	target.damaged.emit(target, me)
	target.components[0].hp = 40.0
	target.damaged.emit(target, friend)
	target.destroyed.emit(target, friend)
	bot.components[0].hp = 10.0
	bot.damaged.emit(bot, me)
	bot.destroyed.emit(bot, me)
	var mine := stats.make_stats(PILOT)
	_expect(int(mine.damage) == 130 and int(mine.assists) == 1, "damage dealt %d and an assist for the pilot who hurt the target first" % int(mine.damage))
	_expect(int(mine.bot_kills) == 1 and int(mine.vehicle_kills) == 1, "a bot's vehicle destroyed counts as a bot kill and a vehicle kill")
	var friends := stats.make_stats("Friend")
	_expect(int(friends.vehicle_kills) == 1 and int(friends.assists) == 0 and int(friends.bot_kills) == 0, "the killer's own damage is no assist")
	stats.update(2.5)
	_expect(is_equal_approx(float(stats.make_stats(PILOT).seconds_alive), 2.5) and float(stats.make_stats("Bot").seconds_alive) == 0.0, "time alive counts living human pilots")
	me.alive = false
	stats.update(1.0)
	_expect(is_equal_approx(float(stats.make_stats(PILOT).seconds_alive), 2.5), "a dead pilot's clock stops")
	stats.note_extraction(PILOT)
	_expect(int(stats.make_stats(PILOT).extractions) == 1, "an extraction is counted")
	for h in [me, friend, bot, target]:
		h.free()
	battle.free()


func _herc(id: int, pilot_name: String, team: int, is_ai := false) -> Herc:
	var h := Herc.new()
	h.net_id = id
	h.display_name = pilot_name
	h.team = team
	h.components = [{"name": "body", "hp": 100.0, "max": 100.0, "fatal": true, "parent": -1}]
	if is_ai:
		h.set_meta("ai", true)
	return h

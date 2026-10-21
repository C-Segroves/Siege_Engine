class_name ResultsAward
extends RefCounted
## What the match just played pays each pilot (docs/design/lobby_loadout_economy.md sections 2.5 and 7.2). The HOST makes
## every award when the match ends (make_all, from its own BattleStats numbers and the goals each pilot picked in the lobby)
## and sends them in the match summary under "awards"; a client only reads his own (for_pilot) and his machine pays it into
## his operator profile (EconomyNet), so no client computes, or can raise, his own award.
## Solo matches pay nothing, and a raid is paid on extraction with what it carried out, not here.

const MODE_BY_SUMMARY := {"vs": "vs", "coop": "coop", "mission": "campaign"}


## The awards of every pilot row of `summary`: {pilot name: award}, a pilot whose match pays nothing is left out.
## `picked_by_pilot` holds the lobby goals each picked ({name: [ids]}), `mission_success` the campaign mission's result.
static func make_all(summary: Dictionary, settings: Dictionary, picked_by_pilot: Dictionary, mission_success := false) -> Dictionary:
	var awards := {}
	for row in summary.get("pilots", []):
		var pilot_name := str(row.get("name", ""))
		var award := make(summary, settings, pilot_name, picked_by_pilot.get(pilot_name, []), mission_success)
		if not award.is_empty():
			awards[pilot_name] = award
	return awards


## The award the host made for `pilot_name` ({} when the match pays him nothing).
static func for_pilot(summary: Dictionary, pilot_name: String) -> Dictionary:
	return (summary.get("awards", {}) as Dictionary).get(pilot_name, {})


## The award {total, lines: [{text, amount}]} of pilot `pilot_name`, or {} when this match pays him nothing.
## `picked_ids` are the lobby goals he picked, `mission_success` the campaign mission's result.
static func make(summary: Dictionary, settings: Dictionary, pilot_name: String, picked_ids: Array, mission_success := false) -> Dictionary:
	var summary_mode := str(summary.get("mode", ""))
	if bool(settings.get("solo", false)) or MODE_BY_SUMMARY.get(summary_mode, "") != str(settings.get("mode", "")):
		return {}
	var row := _find_row(summary, pilot_name)
	if row.is_empty():
		return {}
	var stats := make_stats(summary, row, make_won(summary, row, settings, mission_success))
	var done := LobbyGoals.make_done(LobbyGoals.make_board(settings), picked_ids, stats)
	var award := CreditsLedger.make_award(EconomyRules.make_mode_key(settings), make_ledger_stats(stats), done, false)
	return award if int(award.total) > 0 else {}


## The stats of one pilot row for the goals: kills include the bot kills.
static func make_stats(summary: Dictionary, row: Dictionary, won: bool) -> Dictionary:
	var stats := {"seconds": float(summary.get("seconds", 0.0)), "won": won}
	for key in ["kills", "bot_kills", "vehicle_kills", "assists", "objectives", "flag_captures", "damage", "extractions"]:
		stats[key] = int(row.get(key, 0))
	stats["seconds_alive"] = float(row.get("seconds_alive", 0.0))
	stats["survived"] = bool(row.get("survived", false))
	return stats


## True when the pilot's side won: a mission by its result, a team match when the winner is his team's name, a free for all
## when the winner is his name, co-op when the match names a winner.
## The same for the ledger, which pays bot kills at their own rate: `kills` leaves them out.
static func make_ledger_stats(stats: Dictionary) -> Dictionary:
	return stats.merged({"kills": maxi(int(stats.get("kills", 0)) - int(stats.get("bot_kills", 0)), 0)}, true)


static func make_won(summary: Dictionary, row: Dictionary, settings: Dictionary, mission_success: bool) -> bool:
	var winner := str(summary.get("winner", ""))
	if str(summary.get("mode", "")) == "mission":
		return mission_success
	if str(settings.get("mode", "")) == "coop":
		return winner != ""
	var team_name := TeamList.make_team_name(int(row.get("team", 0)), LobbySettings.make_map_config(settings))
	return winner != "" and (winner == str(row.get("name", "")) or winner == team_name)


static func _find_row(summary: Dictionary, pilot_name: String) -> Dictionary:
	for row in summary.get("pilots", []):
		if bool(row.get("player", false)) and str(row.get("name", "")) == pilot_name:
			return row
	return {}

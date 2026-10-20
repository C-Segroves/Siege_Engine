class_name ResultsAward
extends RefCounted
## What the match just played pays the local pilot (docs/design/lobby_loadout_economy.md sections 2.5 and 7.2). Every peer
## holds the host's match summary (BattleSummary), so each makes his own award from his row of it with the credits ledger,
## plus the goals he picked in the lobby; the pilot's own machine then pays it into his operator profile (EconomyNet).
## Solo matches pay nothing, and a raid is paid on extraction with what it carried out, not here.

const MODE_BY_SUMMARY := {"vs": "vs", "coop": "coop", "mission": "campaign"}


## The award {total, lines: [{text, amount}]} of pilot `pilot_name`, or {} when this match pays him nothing.
## `picked_ids` are the lobby goals he picked, `mission_success` the campaign mission's result.
static func make(summary: Dictionary, settings: Dictionary, pilot_name: String, picked_ids: Array, mission_success := false) -> Dictionary:
	var summary_mode := str(summary.get("mode", ""))
	if bool(settings.get("solo", false)) or MODE_BY_SUMMARY.get(summary_mode, "") != str(settings.get("mode", "")):
		return {}
	var row := _find_row(summary, pilot_name)
	if row.is_empty():
		return {}
	var stats := {"seconds": float(summary.get("seconds", 0.0)), "kills": int(row.get("kills", 0)), "bot_kills": 0, "vehicle_kills": 0,
		"assists": 0, "objectives": 0, "won": make_won(summary, row, settings, mission_success)}
	var done := LobbyGoals.make_done(LobbyGoals.make_board(settings), picked_ids, stats)
	var award := CreditsLedger.make_award(EconomyRules.make_mode_key(settings), stats, done, false)
	return award if int(award.total) > 0 else {}


## True when the pilot's side won: a mission by its result, a team match when the winner is his team's name, a free for all
## when the winner is his name, co-op when the match names a winner.
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

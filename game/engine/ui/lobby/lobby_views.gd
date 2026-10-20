class_name LobbyViews
extends RefCounted
## The plain-data views the lobby screen hands its widgets (docs/design/lobby_loadout_economy.md section 5): the team picker
## choices of the local card and the goals pane's view. Pure functions of the session state they are given.


## [{team, name}] the local pilot may pick in a team match: Unassigned, then every team of the match ([] otherwise).
static func make_team_choices(settings: Dictionary) -> Array:
	if not LobbySettings.is_team_match(settings):
		return []
	var out := [{"team": TeamAssignment.UNASSIGNED, "name": TeamList.UNASSIGNED_NAME}]
	var map_config := LobbySettings.make_map_config(settings)
	for team in LobbySettings.make_team_count(settings):
		out.append({"team": team, "name": TeamList.make_team_name(team, map_config)})
	return out


## The view of TaskListPane.show_goals for pilot `my_id`: the board, his picks (`picked_override` while his last click is on
## its way to the host), the limit and the teammates' picks.
static func make_goals_view(settings: Dictionary, roster: Dictionary, my_id: int, raid_profile: ExtractionProfile, picked_override: Variant) -> Dictionary:
	var entry: Dictionary = roster.get(my_id, {})
	var squad := LobbyModel.make_squad_peers(roster, settings, my_id)
	var raid := ExtractionRules.is_extraction(settings)
	var picked: Array = picked_override if picked_override != null else LobbyGoals.make_picked_ids(entry, settings)
	return {"board": LobbyGoals.make_board(settings, raid_profile), "picked": picked, "max": LobbyGoals.make_max_picks(settings),
		"teammates": LobbyGoals.make_teammate_picks(settings, roster, squad, my_id),
		"squad_mode": LobbySettings.is_team_match(settings) or LobbyModel.is_cooperative(settings) or (raid and squad.size() > 1),
		"is_host": Net.is_host(), "rerollable": not raid}

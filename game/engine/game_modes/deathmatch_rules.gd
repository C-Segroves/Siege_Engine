class_name DeathmatchRules
extends GameModeRules
## Deathmatch and team deathmatch (Starsiege DM_ maps: every pilot for himself, or teams when the server plays
## in teams; Tribes 1 / 2 Deathmatch; the remake's mode on every map). A kill scores for the killer (and his team);
## first to score_limit wins, else the best score at the time limit (Tribes Deathmatch has no score limit).


func _on_kill(victim: Dictionary, killer: Dictionary) -> void:
	if not team_based or GameModeRules.is_suicide(victim, killer) or is_teamkill(victim, killer):
		if not team_based and not GameModeRules.is_suicide(victim, killer):
			check_player_limit(str(killer.key))
		return
	score.add_team(int(killer.team), _num("score_per_kill", 1.0))
	check_team_limit(int(killer.team))

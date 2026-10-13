class_name DefendDestroyRules
extends GameModeRules
## Defend and Destroy (Tribes 1 objectives.cs: every object with a scoreValue; Tribes 2 DnDGame.cs) and Starsiege
## WAR (WAR_Martian_Standoff: each base's generators and HQ):
##   * destroying an enemy objective scores its value (x score_per_objective) for the destroying team and player;
##     a team destroying its own gives the points to every other team;
##   * WAR: the first team to destroy structures_to_win enemy structures wins;
##   * otherwise the match ends when a team has lost all its objectives or a team reaches score_limit; at the time
##     limit each surviving objective first scores for its owner (Tribes 1), then the best team wins.

var _destroyed_by := {}     # team -> enemy objectives it destroyed


func _on_setup() -> void:
	var kinds: Array = settings.get("objective_kinds", [ModeObject.KIND_OBJECTIVE])
	for o in objects.values():
		if not (o.kind in kinds) or o.team < 0:
			objects.erase(o.id)


func apply_destroyed(object_id: int, by: Dictionary) -> void:
	var o: ModeObject = objects.get(object_id)
	if over or o == null or o.state == ModeObject.DESTROYED:
		return
	o.state = ModeObject.DESTROYED
	var points := o.value * _num("score_per_objective", 1.0)
	var by_team := int(by.get("team", -1))
	if by.is_empty() or by_team == o.team:
		for t in teams:
			if t != o.team:
				score.add_team(t, points)
	else:
		score.add_team(by_team, points)
		score.add_player(str(by.key), points)
		_destroyed_by[by_team] = int(_destroyed_by.get(by_team, 0)) + 1
	announce("%s of %s destroyed." % [_objective_name(o), make_team_name(o.team)])
	_changed()
	_check_end(by_team)


func _check_end(by_team: int) -> void:
	var needed := int(_num("structures_to_win", 0.0))
	if needed > 0 and int(_destroyed_by.get(by_team, 0)) >= needed:
		finish("%s destroyed the enemy base!" % make_team_name(by_team), make_team_name(by_team))
		return
	if by_team >= 0:
		check_team_limit(by_team)
	for t in teams:
		if not over and make_standing(t).is_empty():
			finish_by_score("All objectives of %s are destroyed." % make_team_name(t))


## `team`'s objectives still standing.
func make_standing(team: int) -> Array:
	return objects.values().filter(func(o: ModeObject) -> bool:
		return o.team == team and o.state != ModeObject.DESTROYED)


func _on_time_limit() -> void:
	for t in teams:
		for o in make_standing(t):
			score.add_team(t, o.value * _num("score_per_objective", 1.0))
	super()


func _objective_name(o: ModeObject) -> String:
	return o.name if o.name != "" else (o.datablock if o.datablock != "" else "objective %d" % o.id)


func make_hud_lines(viewer: Dictionary) -> PackedStringArray:
	var lines := super(viewer)
	for t in teams:
		var total := objects.values().filter(func(o: ModeObject) -> bool: return o.team == t).size()
		lines.append("%s objectives standing: %d / %d" % [make_team_name(t), make_standing(t).size(), total])
	return lines

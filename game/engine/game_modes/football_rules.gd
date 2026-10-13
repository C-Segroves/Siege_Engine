class_name FootballRules
extends GameModeRules
## Starsiege Football (Starsiege_Football.cs): two teams, one ball, a goal box at each end of the field.
##   * the ball is held by a Herc, never on the ground: the first Herc in the match gets it; killing the carrier
##     hands it to the killer (a team kill gives it to a random opponent of the carrier);
##   * carrying it into the enemy goal box scores a touchdown: the team gets score_per_goal, the carrier
##     score_per_player_goal; everybody respawns (request "respawn_all") and the team that conceded gets the ball;
##   * entering a goal box without the ball or leaving the field (out-of-bounds boxes) is a foul: the Herc is destroyed
##     (request "kill"); max_fouls fouls are announced as a penalty;
##   * the killer of the carrier scores score_per_carrier_kill; first team to score_limit (default
##     goals_to_win touchdowns) wins;
##   * fumble (vehicle::onAttacked): every hit on the carrier by another Herc hands the attacker the ball with
##     fumble_chance (he scores score_per_fumble_takeup);
##   * the max_fouls-th foul sends the Herc to its team's penalty box for penalty_s (addFoul, sendToPenaltyBox):
##     request "penalty" (the battle destroys it, it comes back in the box on a penalty team that never gets the
##     ball), then "penalty_end" (back on its team, destroyed again to respawn on the field).

var fouls := {}            # player key -> fouls
var _ball_id := 0
var _give_to_team := -1    # after a touchdown: the team that conceded gets the ball
var _in_box := {}          # player key -> true while inside a box he was penalised for
var rng := RandomNumberGenerator.new()
## player key -> [net id, elapsed when the penalty ends]
var penalized := {}


func _on_setup() -> void:
	var goals := objects_of(ModeObject.KIND_GOAL)
	var middle := Vector3.ZERO
	for g in goals:
		middle += g.pos / maxf(goals.size(), 1)
	var ball := ModeObject.new()
	ball.id = objects.keys().max() + 1 if not objects.is_empty() else 1
	ball.kind = ModeObject.KIND_BALL
	ball.home = middle
	ball.pos = middle
	objects[ball.id] = ball
	_ball_id = ball.id
	if not settings.has("score_limit"):
		settings["score_limit"] = _num("goals_to_win", 6.0) * _num("score_per_goal", 1.0)


func make_ball() -> ModeObject:
	return objects.get(_ball_id)


func apply_touch(player: Dictionary, object_id: int) -> void:
	var ball := make_ball()
	if not over and object_id == _ball_id and ball.state != ModeObject.CARRIED and bool(player.get("alive", true)):
		_give(ball, player)


func _give(ball: ModeObject, player: Dictionary) -> void:
	pick_up(ball, player)
	announce("%s has the ball." % player.key)
	_changed()


func _on_kill(victim: Dictionary, killer: Dictionary) -> void:
	var ball := make_ball()
	if ball.state != ModeObject.CARRIED or ball.carrier != int(victim.get("id", 0)):
		return
	ball.state = ModeObject.HOME
	ball.carrier = ModeObject.NO_CARRIER
	if not killer.is_empty() and not GameModeRules.is_suicide(victim, killer) and not is_teamkill(victim, killer):
		score.add_player(str(killer.key), _num("score_per_carrier_kill", 1.0))
		_give(ball, killer)
		return
	_give_to_team = _make_other_team(int(victim.get("team", 0)))


func apply_hit(victim: Dictionary, attacker: Dictionary) -> void:
	var ball := make_ball()
	if over or attacker.is_empty() or ball.state != ModeObject.CARRIED or ball.carrier != int(victim.get("id", 0)):
		return
	if GameModeRules.is_suicide(victim, attacker) or rng.randf() >= _num("fumble_chance", 0.0):
		return
	announce("%s fumbles the ball!" % make_label(str(victim.key)))
	score.add_player(str(attacker.key), _num("score_per_fumble_takeup", 0.0))
	_give(ball, attacker)


func is_penalized(key: String) -> bool:
	return penalized.has(key)


func _apply_penalty_ends() -> void:
	for key in penalized.keys():
		var entry: Array = penalized[key]
		if elapsed >= float(entry[1]):
			penalized.erase(key)
			announce("%s leaves the penalty box." % make_label(str(key)))
			requests.append({"kind": "penalty_end", "id": int(entry[0])})
			_changed()


func _on_tick(_delta: float) -> void:
	_apply_penalty_ends()
	follow_carriers()
	var ball := make_ball()
	if ball.state != ModeObject.CARRIED:
		_hand_out(ball)
	for p in players.values():
		if over or not bool(p.get("alive", true)) or is_penalized(str(p.key)):
			continue
		_check_boxes(p, ball)


## A free ball goes to a player of the team owed it, else to the first player.
func _hand_out(ball: ModeObject) -> void:
	var pool := players.values().filter(func(p: Dictionary) -> bool:
		return bool(p.get("alive", true)) and not is_penalized(str(p.key)) and int(p.team) in teams \
			and (_give_to_team < 0 or int(p.team) == _give_to_team))
	if pool.is_empty():
		return
	_give_to_team = -1
	_give(ball, pool[rng.randi() % pool.size()])


func _check_boxes(p: Dictionary, ball: ModeObject) -> void:
	var key := str(p.key)
	var carrying := ball.state == ModeObject.CARRIED and ball.carrier == int(p.id)
	var box := _make_box_at(p.pos)
	if box == null:
		_in_box.erase(key)
		return
	if carrying and box.kind == ModeObject.KIND_GOAL and box.team != int(p.team):
		_touchdown(p, box)
	elif not carrying and not _in_box.has(key):
		_in_box[key] = true
		_foul(p, box)


func _make_box_at(at: Vector3) -> ModeObject:
	for o in objects.values():
		if (o.kind == ModeObject.KIND_GOAL or o.kind == ModeObject.KIND_OUT_OF_BOUNDS) and o.is_over_footprint(at):
			return o
	return null


func _touchdown(p: Dictionary, goal: ModeObject) -> void:
	var ball := make_ball()
	return_home(ball)
	score.add_team(int(p.team), _num("score_per_goal", 1.0))
	score.add_player(str(p.key), _num("score_per_player_goal", 1.0))
	announce("TOUCHDOWN! %s scores for %s." % [p.key, make_team_name(int(p.team))])
	_give_to_team = goal.team
	requests.append({"kind": "respawn_all"})
	_changed()
	check_team_limit(int(p.team))


func _foul(p: Dictionary, box: ModeObject) -> void:
	var key := str(p.key)
	fouls[key] = int(fouls.get(key, 0)) + 1
	var what := "out of bounds" if box.kind == ModeObject.KIND_OUT_OF_BOUNDS else "in the goal without the ball"
	announce("Foul: %s %s (%d)." % [key, what, int(fouls[key])])
	if int(fouls[key]) >= int(_num("max_fouls", 3.0)):
		announce("%s goes to the penalty box." % key)
		fouls[key] = 0
		penalized[key] = [int(p.id), elapsed + _num("penalty_s", 60.0)]
		var rect: Array = settings.get("penalty_boxes", {}).get(str(int(p.team)), [])
		requests.append({"kind": "penalty", "id": int(p.id), "team": int(p.team), "box": rect})
	else:
		requests.append({"kind": "kill", "id": int(p.id)})
	_changed()


func _make_other_team(team: int) -> int:
	for t in teams:
		if t != team:
			return t
	return team


func make_extra_state() -> Dictionary:
	return {"fouls": fouls.duplicate(), "ball": _ball_id, "penalized": penalized.duplicate()}


func apply_extra_state(d: Dictionary) -> void:
	fouls = d.get("fouls", {}).duplicate()
	_ball_id = int(d.get("ball", _ball_id))
	penalized = d.get("penalized", {}).duplicate()


func make_hud_lines(viewer: Dictionary) -> PackedStringArray:
	var lines := super(viewer)
	var ball := make_ball()
	if ball != null:
		lines.append("Ball: %s" % (make_player_name(ball.carrier) if ball.state == ModeObject.CARRIED else "loose"))
	return lines

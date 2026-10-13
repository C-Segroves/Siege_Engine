class_name CaptureHoldRules
extends GameModeRules
## Capture and Hold (Tribes 1 TowerSwitch, objectives.cs; Tribes 2 FlipFlop, CnHGame.cs):
##   * touching a switch your team does not hold claims it for your team;
##   * after capture_delay_s still held (Tribes 2: the capture timer; Tribes 1: 0, at once) the claim counts: the team
##     scores team_capture_points, the claimer score_per_capture;
##   * from then on the holding team scores every hold_interval_s: the switch's points_per_minute share (Tribes 1
##     deltaTeamScore per minute) or hold_points;
##   * first team to score_limit (else switches x score_limit_per_switch) wins, else the best at the time limit;
##   * Tribes 1 TowerSwitch::timeLimitCheckPoints: a switch still held hold_bonus_s after its capture (no other
##     claim since) gives its claimer score_per_hold_bonus;
##   * the switch's group (turrets, stations) changes team with it (GameModeResources, every peer);
##   * defence bonuses (GameModeRules._apply_defend_bonuses).

var _claimer := {}     # switch id -> player key of the claim in progress
var _hold_bonus := {}  # switch id -> [claims count, elapsed when due, claimer key]


func apply_touch(player: Dictionary, object_id: int) -> void:
	var o: ModeObject = objects.get(object_id)
	if over or o == null or o.kind != ModeObject.KIND_SWITCH or not bool(player.get("can_touch", true)):
		return
	if o.owner_team == int(player.team):
		return
	o.owner_team = int(player.team)
	o.timer = _num("capture_delay_s", 0.0)
	o.hold_time = 0.0
	o.claims += 1
	_claimer[o.id] = str(player.key)
	if _num("hold_bonus_s", 0.0) > 0.0:
		_hold_bonus[o.id] = [o.claims, elapsed + _num("hold_bonus_s", 0.0), str(player.key)]
	announce("%s claims %s for %s." % [player.key, _switch_name(o), make_team_name(o.owner_team)])
	if o.timer <= 0.0:
		_confirm(o)
	_changed()


func _confirm(o: ModeObject) -> void:
	o.timer = 0.0
	score.add_team(o.owner_team, _num("team_capture_points", 0.0))
	score.add_player(str(_claimer.get(o.id, "")), _num("score_per_capture", 0.0))
	announce("%s holds %s." % [make_team_name(o.owner_team), _switch_name(o)])
	check_team_limit(o.owner_team)


func _on_tick(delta: float) -> void:
	_apply_hold_bonuses()
	for o in objects_of(ModeObject.KIND_SWITCH):
		if o.owner_team < 0:
			continue
		if o.timer > 0.0:
			o.timer -= delta
			if o.timer <= 0.0:
				_confirm(o)
				_changed()
			continue
		_apply_hold(o, delta)


func _apply_hold_bonuses() -> void:
	for id in _hold_bonus.keys():
		var due: Array = _hold_bonus[id]
		if elapsed < float(due[1]):
			continue
		_hold_bonus.erase(id)
		var o: ModeObject = objects.get(id)
		if o != null and o.claims == int(due[0]):
			score.add_player(str(due[2]), _num("score_per_hold_bonus", 0.0))
			announce("%s receives a bonus for holding %s." % [make_label(str(due[2])), _switch_name(o)])
			_changed()


func _apply_hold(o: ModeObject, delta: float) -> void:
	var interval := maxf(_num("hold_interval_s", 1.0), 0.01)
	o.hold_time += delta
	while o.hold_time >= interval and not over:
		o.hold_time -= interval
		var points := o.points_per_minute * interval / SECONDS_PER_MINUTE if o.points_per_minute > 0.0 \
			else _num("hold_points", 1.0)
		score.add_team(o.owner_team, points)
		_changed()
		check_team_limit(o.owner_team)


## score_limit, else switches x score_limit_per_switch (Tribes 2 getScoreLimit).
func check_team_limit(team: int) -> void:
	if not settings.has("score_limit") and settings.has("score_limit_per_switch"):
		settings["score_limit"] = objects_of(ModeObject.KIND_SWITCH).size() * _num("score_limit_per_switch", 0.0)
	super(team)


func _switch_name(o: ModeObject) -> String:
	return o.name if o.name != "" else "switch %d" % o.id


func make_hud_lines(viewer: Dictionary) -> PackedStringArray:
	var lines := super(viewer)
	var held := {}
	var claims := PackedStringArray()
	for o in objects_of(ModeObject.KIND_SWITCH):
		var holder := "free" if o.owner_team < 0 else make_team_name(o.owner_team)
		held[holder] = int(held.get(holder, 0)) + 1
		if o.timer > 0.0:
			claims.append("%s claiming %s (%d s)" % [holder, _switch_name(o), ceili(o.timer)])
	var parts := PackedStringArray()
	for holder in held:
		parts.append("%s %d" % [holder, held[holder]])
	lines.append("Switches: %s" % ", ".join(parts))
	lines.append_array(claims)
	return lines

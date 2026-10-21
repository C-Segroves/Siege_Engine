class_name CtfRules
extends GameModeRules
## Capture the Flag (Tribes 1 objectives.cs, Tribes 2 CTFGame.cs, Starsiege CTFstdLib.cs; docs/formats/game_modes.md):
##   * touching the enemy flag takes it (its stand or where it lies); a rider in a Tribes vehicle cannot touch;
##   * bringing it to your own flag (or your stand / base trigger) captures it, but only while your own flag is at
##     home (home_capture_required): team score_per_team_flag_cap, the carrier score_per_player_flag_cap;
##   * a killed carrier drops the flag; it returns home after flag_return_s, or at once when a team mate touches it
##     (score_per_flag_return) or when drop_returns_home (Starsiege: the flag is never on the ground);
##   * carrier_time_s (Starsiege $flagTime): a flag carried that long goes back home;
##   * the killer of an enemy carrier gets score_per_carrier_kill;
##   * first team to score_limit captures wins, else the most captures at the time limit;
##   * stalemate (Tribes 2 CTFGame beginStalemate): every flag away from home for stalemate_s reveals the carriers
##     for stalemate_reveal_s, then hides them for stalemate_every_s, and so on until a flag goes home;
##   * defence bonuses (GameModeRules._apply_defend_bonuses). Tribes 2's escort assist is not scored: its script
##     clears the "damaged the carrier" mark the moment it sets it (CTFGame.cs, a schedule evaluated at once).

## True while the carriers are revealed (a stalemate); the peers see it in the state.
var revealed := false
var stalemate := false
var _stalemate_t := 0.0


func apply_touch(player: Dictionary, object_id: int) -> void:
	var o: ModeObject = objects.get(object_id)
	if over or o == null or not bool(player.get("can_touch", true)) or not bool(player.get("alive", true)):
		return
	var own := o.team == int(player.team)
	if o.kind == ModeObject.KIND_FLAG:
		if own:
			_touch_own_flag(player, o)
		elif o.is_takeable():
			pick_up(o, player)
			announce("%s took the %s flag." % [player.key, make_team_name(o.team)])
			_changed()
	elif o.kind == ModeObject.KIND_STAND and own:
		_try_capture(player)


func _touch_own_flag(player: Dictionary, flag: ModeObject) -> void:
	if flag.state == ModeObject.HOME:
		_try_capture(player)
	elif flag.state == ModeObject.DROPPED:
		return_home(flag)
		score.add_player(str(player.key), _num("score_per_flag_return", 1.0))
		score.add_event(str(player.key), ModeScore.EVENT_FLAG_RETURN)
		announce("%s returned the %s flag." % [player.key, make_team_name(flag.team)])
		_changed()


func _try_capture(player: Dictionary) -> void:
	var carried := make_carried(int(player.id)).filter(func(o: ModeObject) -> bool:
		return o.kind == ModeObject.KIND_FLAG and o.team != int(player.team))
	if carried.is_empty() or (bool(settings.get("home_capture_required", true)) and not _is_home(int(player.team))):
		return
	for flag in carried:
		return_home(flag)
		score.add_team(int(player.team), _num("score_per_team_flag_cap", 1.0))
		score.add_player(str(player.key), _num("score_per_player_flag_cap", 1.0))
		score.add_event(str(player.key), ModeScore.EVENT_FLAG_CAPTURE)
		announce("%s captured the %s flag for %s!" % [player.key, make_team_name(flag.team), make_team_name(int(player.team))])
	_changed()
	check_team_limit(int(player.team))


## True when `team`'s flag is at home (a team without a flag counts as home).
func _is_home(team: int) -> bool:
	for flag in objects_of(ModeObject.KIND_FLAG):
		if flag.team == team and flag.state != ModeObject.HOME:
			return false
	return true


func _on_kill(victim: Dictionary, killer: Dictionary) -> void:
	var carried := make_carried(int(victim.get("id", 0)))
	if carried.is_empty():
		return
	if not killer.is_empty() and not GameModeRules.is_suicide(victim, killer) \
			and carried.any(func(o: ModeObject) -> bool: return o.team == int(killer.team)):
		score.add_player(str(killer.key), _num("score_per_carrier_kill", 1.0))
	var return_s := 0.0 if bool(settings.get("drop_returns_home", false)) else _num("flag_return_s", 45.0)
	for flag in drop_carried(victim, return_s):
		announce("%s dropped the %s flag." % [victim.get("key", "?"), make_team_name(flag.team)])


func _on_tick(delta: float) -> void:
	follow_carriers()
	for flag in make_returned(ModeObject.KIND_FLAG, delta):
		announce("The %s flag was returned to base." % make_team_name(flag.team))
		_changed()
	_apply_carrier_time(delta)
	_apply_stalemate(delta)


func _apply_stalemate(delta: float) -> void:
	var start := _num("stalemate_s", 0.0)
	var flags := objects_of(ModeObject.KIND_FLAG)
	if start <= 0.0 or flags.size() < 2:
		return
	if flags.any(func(f: ModeObject) -> bool: return f.state == ModeObject.HOME):
		if stalemate:
			stalemate = false
			revealed = false
			announce("The stalemate is broken.")
			_changed()
		_stalemate_t = 0.0
		return
	_stalemate_t += delta
	if not stalemate:
		if _stalemate_t >= start:
			stalemate = true
			_set_revealed(true)
			announce("Stalemate! The flag carriers are revealed.")
		return
	if _stalemate_t >= (_num("stalemate_reveal_s", 6.0) if revealed else _num("stalemate_every_s", 15.0)):
		_set_revealed(not revealed)


func _set_revealed(on: bool) -> void:
	revealed = on
	_stalemate_t = 0.0
	_changed()


func make_extra_state() -> Dictionary:
	return {"revealed": revealed, "stalemate": stalemate}


func apply_extra_state(d: Dictionary) -> void:
	revealed = bool(d.get("revealed", false))
	stalemate = bool(d.get("stalemate", false))


## Starsiege $flagTime: a flag carried too long goes home (the carrier keeps his Herc).
func _apply_carrier_time(delta: float) -> void:
	var limit := _num("carrier_time_s", NO_LIMIT)
	if limit <= NO_LIMIT:
		return
	for flag in objects_of(ModeObject.KIND_FLAG):
		if flag.state != ModeObject.CARRIED:
			continue
		flag.timer += delta
		if flag.timer >= limit:
			return_home(flag)
			announce("Time is up: the %s flag returns to its base." % make_team_name(flag.team))
			_changed()


func make_hud_lines(viewer: Dictionary) -> PackedStringArray:
	var lines := super(viewer)
	for flag in objects_of(ModeObject.KIND_FLAG):
		lines.append("%s flag: %s" % [make_team_name(flag.team), make_flag_status(flag)])
	if revealed:
		lines.append("Stalemate: the flag carriers are revealed")
	return lines


func make_flag_status(flag: ModeObject) -> String:
	match flag.state:
		ModeObject.CARRIED:
			return "taken by %s" % make_player_name(flag.carrier)
		ModeObject.DROPPED:
			return "dropped (%d s)" % ceili(flag.timer)
	return "at home"


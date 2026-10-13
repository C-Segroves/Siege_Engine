class_name FindRetrieveRules
extends GameModeRules
## Find and Retrieve (Tribes 1 objectives.cs; FogOfWar, Mudslide ...): neutral flags lie around the map, each team
## has flag stands at its base.
##   * touching a free flag takes it; bringing it to an empty stand of your team places it there: the team scores the
##     flag's value (Tribes scoreValue), the carrier too;
##   * an enemy may take a placed flag off your stand: your team loses its value again;
##   * a killed carrier drops the flag, which returns to where it started after flag_return_s;
##   * first team to score_limit wins, else the best at the time limit.


func apply_touch(player: Dictionary, object_id: int) -> void:
	var o: ModeObject = objects.get(object_id)
	if over or o == null or not bool(player.get("can_touch", true)) or not bool(player.get("alive", true)):
		return
	if o.kind == ModeObject.KIND_FLAG and o.team < 0:
		_take(player, o)
	elif o.kind == ModeObject.KIND_STAND and o.team == int(player.team) and o.held_object == 0:
		_place(player, o)


func _take(player: Dictionary, flag: ModeObject) -> void:
	if not flag.is_takeable() or (flag.state == ModeObject.PLACED and flag.owner_team == int(player.team)):
		return
	if flag.state == ModeObject.PLACED:
		for stand in objects_of(ModeObject.KIND_STAND):
			if stand.held_object == flag.id:
				stand.held_object = 0
		score.add_team(flag.owner_team, -flag.value)
		announce("%s took a flag from %s's base." % [player.key, make_team_name(flag.owner_team)])
	else:
		announce("%s has a flag." % player.key)
	flag.owner_team = ModeObject.NEUTRAL
	pick_up(flag, player)
	_changed()


func _place(player: Dictionary, stand: ModeObject) -> void:
	var carried := make_carried(int(player.id))
	if carried.is_empty():
		return
	var flag: ModeObject = carried[0]
	flag.state = ModeObject.PLACED
	flag.carrier = ModeObject.NO_CARRIER
	flag.pos = stand.pos
	flag.owner_team = int(player.team)
	stand.held_object = flag.id
	score.add_team(int(player.team), flag.value)
	score.add_player(str(player.key), flag.value)
	announce("%s brought a flag home for %s." % [player.key, make_team_name(int(player.team))])
	_changed()
	check_team_limit(int(player.team))


func _on_kill(victim: Dictionary, _killer: Dictionary) -> void:
	for flag in drop_carried(victim, _num("item_return_s", _num("flag_return_s", 45.0))):
		announce("%s dropped a flag." % victim.get("key", "?"))


func _on_tick(delta: float) -> void:
	follow_carriers()
	for flag in make_returned(ModeObject.KIND_FLAG, delta):
		announce("A dropped flag returned to its place.")
		_changed()


func make_hud_lines(viewer: Dictionary) -> PackedStringArray:
	var lines := super(viewer)
	var flags := objects_of(ModeObject.KIND_FLAG)
	for t in teams:
		var held := flags.filter(func(f: ModeObject) -> bool: return f.state == ModeObject.PLACED and f.owner_team == t)
		lines.append("%s holds %d of %d flags" % [make_team_name(t), held.size(), flags.size()])
	return lines

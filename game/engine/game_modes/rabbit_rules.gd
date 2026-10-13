class_name RabbitRules
extends GameModeRules
## Rabbit (Tribes 2 RabbitGame.cs): one flag on the map.
##   * whoever touches the free flag takes it and is the rabbit (a grab scores score_per_grab);
##   * the rabbit scores hold_points for every hold_interval_s he keeps it (held time adds up over grabs);
##   * killing the rabbit is a kill like any other; he drops the flag, which returns to its place after flag_return_s;
##   * first to score_limit wins, else the best score at the time limit.

var _held := {}        # player key -> seconds held, not yet scored


func apply_touch(player: Dictionary, object_id: int) -> void:
	var o: ModeObject = objects.get(object_id)
	if over or o == null or o.kind != ModeObject.KIND_FLAG or not o.is_takeable():
		return
	if not bool(player.get("can_touch", true)) or not bool(player.get("alive", true)):
		return
	pick_up(o, player)
	score.add_player(str(player.key), _num("score_per_grab", 1.0))
	announce("%s is the rabbit!" % player.key)
	_changed()
	check_player_limit(str(player.key))


func _on_kill(victim: Dictionary, _killer: Dictionary) -> void:
	for flag in drop_carried(victim, _num("flag_return_s", 45.0)):
		announce("The rabbit %s is down!" % make_label(str(victim.get("key", "?")), victim))


func _on_tick(delta: float) -> void:
	follow_carriers()
	for flag in make_returned(ModeObject.KIND_FLAG, delta):
		announce("The flag returned to its place.")
		_changed()
	var rabbit := make_rabbit_key()
	if rabbit == "":
		return
	var interval := maxf(_num("hold_interval_s", 15.0), 0.01)
	_held[rabbit] = float(_held.get(rabbit, 0.0)) + delta
	while float(_held[rabbit]) >= interval and not over:
		_held[rabbit] = float(_held[rabbit]) - interval
		score.add_player(rabbit, _num("hold_points", 1.0))
		_changed()
		check_player_limit(rabbit)


## The rabbit's key ("" when nobody carries the flag).
func make_rabbit_key() -> String:
	for flag in objects_of(ModeObject.KIND_FLAG):
		if flag.state == ModeObject.CARRIED:
			return make_player_name(flag.carrier)
	return ""


func make_hud_lines(viewer: Dictionary) -> PackedStringArray:
	var lines := super(viewer)
	var rabbit := make_rabbit_key()
	lines.append("Rabbit: %s" % (rabbit if rabbit != "" else "nobody - grab the flag!"))
	return lines

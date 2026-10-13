class_name BountyRules
extends GameModeRules
## Bounty (Tribes 2 BountyGame.cs): every player hunts one target, picked at random among the players he has not
## eliminated yet.
##   * killing your target: score_per_target_kill, he is eliminated for you, your streak grows (from streak_size on
##     every target kill adds streak - streak_size + 1) and you get a new target;
##   * killing the player hunting you: nothing; killing a bystander: score_per_bystander_kill, your streak ends and
##     one player you eliminated comes back into your pool;
##   * a suicide counts as a target kill for everyone hunting the victim (and score_per_suicide for him);
##   * the first player with nobody left to hunt gets score_completion_bonus and wins; else the best at the time limit.

var targets := {}        # hunter key -> target key
var eliminated := {}     # hunter key -> [keys]
var streaks := {}        # hunter key -> int
var rng := RandomNumberGenerator.new()


func _on_setup() -> void:
	if settings.has("seed"):
		rng.seed = int(settings.seed)


func _apply_kill_score(victim: Dictionary, killer: Dictionary) -> void:
	if GameModeRules.is_suicide(victim, killer):
		score.add_player(str(victim.get("key", "")), _num("score_per_suicide", -1.0))


func _on_kill(victim: Dictionary, killer: Dictionary) -> void:
	var v := str(victim.get("key", ""))
	streaks[v] = 0
	if GameModeRules.is_suicide(victim, killer):
		for hunter in targets.keys():
			if targets[hunter] == v:
				_credit_target(hunter, v)
		return
	var k := str(killer.key)
	if targets.get(k, "") == v:
		_credit_target(k, v)
	elif targets.get(v, "") == k:
		announce("%s fought off his hunter %s." % [make_label(k, killer), make_label(v, victim)])
	else:
		_punish_bystander(k)


func _credit_target(hunter: String, target: String) -> void:
	score.add_player(hunter, _num("score_per_target_kill", 1.0))
	var done: Array = eliminated.get(hunter, [])
	done.append(target)
	eliminated[hunter] = done
	streaks[hunter] = int(streaks.get(hunter, 0)) + 1
	var size := int(_num("streak_size", 3.0))
	if int(streaks[hunter]) >= size:
		score.add_player(hunter, float(int(streaks[hunter]) - size + 1))
	targets.erase(hunter)
	announce("%s collected the bounty on %s." % [make_label(hunter), make_label(target)])


func _punish_bystander(killer: String) -> void:
	score.add_player(killer, _num("score_per_bystander_kill", -1.0))
	streaks[killer] = 0
	var done: Array = eliminated.get(killer, [])
	if not done.is_empty():
		done.remove_at(rng.randi() % done.size())
	announce("%s killed a bystander." % make_label(killer))


func _on_tick(_delta: float) -> void:
	for key in players.keys():
		if over:
			return
		if targets.has(key) and players.has(targets[key]):
			continue
		_assign_target(key)


func _assign_target(hunter: String) -> void:
	var done: Array = eliminated.get(hunter, [])
	var pool := players.keys().filter(func(k: String) -> bool: return k != hunter and not done.has(k))
	if pool.is_empty():
		targets.erase(hunter)
		if not done.is_empty() and players.size() > 1:
			score.add_player(hunter, _num("score_completion_bonus", 5.0))
			finish("%s eliminated every target!" % hunter, hunter)
		return
	targets[hunter] = pool[rng.randi() % pool.size()]
	_changed()


func make_extra_state() -> Dictionary:
	return {"targets": targets.duplicate(), "streaks": streaks.duplicate()}


func apply_extra_state(d: Dictionary) -> void:
	targets = d.get("targets", {}).duplicate()
	streaks = d.get("streaks", {}).duplicate()


func make_hud_lines(viewer: Dictionary) -> PackedStringArray:
	var lines := super(viewer)
	if not viewer.is_empty():
		lines.append("Your target: %s" % targets.get(str(viewer.key), "-"))
		lines.append("Streak: %d" % int(streaks.get(str(viewer.key), 0)))
	return lines

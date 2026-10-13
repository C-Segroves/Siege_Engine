class_name SiegeRules
extends GameModeRules
## Siege (Tribes 2 SiegeGame.cs): two halves. One team attacks, the other defends the base switch.
##   * an attacker touching the switch ends the half: the attackers' time is how long it took;
##   * the first half lasts round_time_s; the second half lasts as long as the first capture took (or round_time_s
##     when the first attackers failed); attackers who run out of time get no time;
##   * at halftime the sides swap (the battle respawns everybody: request "respawn_all"; the new attackers start at
##     the attackers' side), the switch belongs to the new defenders;
##   * the faster capture wins; a team that captured beats one that did not; no captures (or equal times) is a draw.

const FIRST_HALF := 1
const SECOND_HALF := 2

var offense := 0
var half := FIRST_HALF
var half_elapsed := 0.0
var capture_times := {}    # team -> seconds its capture took (absent: no capture)


func _on_setup() -> void:
	offense = int(settings.get("first_offense", teams[0] if not teams.is_empty() else 0))
	_reset_switches()


func make_defense() -> int:
	for t in teams:
		if t != offense:
			return t
	return offense


func _reset_switches() -> void:
	for o in objects_of(ModeObject.KIND_SWITCH):
		o.owner_team = make_defense()
		o.timer = 0.0


func apply_touch(player: Dictionary, object_id: int) -> void:
	var o: ModeObject = objects.get(object_id)
	if over or o == null or o.kind != ModeObject.KIND_SWITCH or int(player.team) != offense:
		return
	if not bool(player.get("can_touch", true)) or not bool(player.get("alive", true)):
		return
	capture_times[offense] = half_elapsed
	o.owner_team = offense
	announce("%s touched the switch: %s captured the base in %s!" % [player.key, make_team_name(offense),
		make_time_text(half_elapsed)])
	_end_half()


func _on_tick(delta: float) -> void:
	half_elapsed += delta
	if half_elapsed >= make_half_limit():
		announce("Time is up: %s did not capture the base." % make_team_name(offense))
		_end_half()


## Seconds the current half lasts.
func make_half_limit() -> float:
	var first := _num("round_time_s", 1200.0)
	if half == SECOND_HALF:
		for t in capture_times:
			if t != offense:
				return float(capture_times[t])
	return first


func _end_half() -> void:
	if half == FIRST_HALF:
		half = SECOND_HALF
		half_elapsed = 0.0
		offense = make_defense()
		_reset_switches()
		requests.append({"kind": "respawn_all"})
		announce("Halftime: the sides swap. %s now attacks." % make_team_name(offense))
		_changed()
		return
	_decide()


func _decide() -> void:
	var best := ModeScore.NO_TEAM
	var best_time := INF
	var tie := false
	for t in capture_times:
		var s := float(capture_times[t])
		if s < best_time:
			best = t
			best_time = s
			tie = false
		elif s == best_time:
			tie = true
	if best == ModeScore.NO_TEAM or tie:
		finish("Siege over: the match is a draw.", "")
		return
	score.add_team(best, 1.0)
	finish("Siege over: %s wins with the faster capture (%s)." % [make_team_name(best), make_time_text(best_time)],
		make_team_name(best))


func _on_time_limit() -> void:
	pass   # the halves keep their own clock


static func make_time_text(seconds: float) -> String:
	return "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]


func make_extra_state() -> Dictionary:
	return {"offense": offense, "half": half, "half_elapsed": half_elapsed, "capture_times": capture_times.duplicate()}


func apply_extra_state(d: Dictionary) -> void:
	offense = int(d.get("offense", 0))
	half = int(d.get("half", FIRST_HALF))
	half_elapsed = float(d.get("half_elapsed", 0.0))
	capture_times = {}
	for k in d.get("capture_times", {}):
		capture_times[int(k)] = float(d.capture_times[k])


func make_hud_lines(_viewer: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray([GameModes.label_for(mode_id), "Half %d: %s attacks" % [half, make_team_name(offense)]])
	lines.append("Time left %s" % make_time_text(maxf(make_half_limit() - half_elapsed, 0.0)))
	for t in capture_times:
		lines.append("%s captured in %s" % [make_team_name(t), make_time_text(capture_times[t])])
	return lines

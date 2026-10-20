class_name SurviveObjective
extends Objective
## Done after `seconds` of mission time pass (the player's death is a fail rule, not this objective's business).

var seconds := 0.0
var _elapsed := 0.0


func _init(p_id := "", p_text := "", p_seconds := 0.0) -> void:
	super(p_id, p_text)
	seconds = p_seconds


func make_time_left() -> float:
	return maxf(seconds - _elapsed, 0.0)


func _make_state(_world: MissionWorld, dt: float) -> State:
	_elapsed += dt
	return State.DONE if _elapsed >= seconds else state

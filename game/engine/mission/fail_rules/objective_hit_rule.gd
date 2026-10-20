class_name ObjectiveHitRule
extends FailRule
## Rules when an objective reaches a state: by default a failed objective loses the mission; with `success` and
## hit_state DONE the finished objective wins it.

var objective: Objective
var hit_state := Objective.State.FAILED
var success := false


func _init(p_code := 0, p_text := "", p_objective: Objective = null, p_hit_state := Objective.State.FAILED,
		p_success := false) -> void:
	super(p_code, p_text)
	objective = p_objective
	hit_state = p_hit_state
	success = p_success


func make_verdict(_world: MissionWorld, _dt: float) -> MissionVerdict:
	if objective == null or objective.state != hit_state:
		return null
	return MissionVerdict.make_win(code, text) if success else MissionVerdict.make_loss(code, text)

class_name TimeLimitRule
extends FailRule
## The mission is over after `seconds`: a loss, or a win for a survival limit (`success`).

var seconds := 0.0
var success := false
var _elapsed := 0.0


func _init(p_code := 0, p_text := "", p_seconds := 0.0, p_success := false) -> void:
	super(p_code, p_text)
	seconds = p_seconds
	success = p_success


func make_verdict(_world: MissionWorld, dt: float) -> MissionVerdict:
	_elapsed += dt
	if _elapsed < seconds:
		return null
	return MissionVerdict.make_win(code, text) if success else MissionVerdict.make_loss(code, text)

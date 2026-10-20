class_name DestroyObjective
extends Objective
## Done when every target is destroyed.

var targets: Array[String] = []


func _init(p_id := "", p_text := "", p_targets: Array[String] = []) -> void:
	super(p_id, p_text)
	targets = p_targets


func _make_state(world: MissionWorld, _dt: float) -> State:
	for t in targets:
		if not world.is_target_destroyed(t):
			return state
	return State.DONE

class_name KillCountObjective
extends Objective
## Done when the player's side has `count` kills against `group` ("" = any enemy).

var group := ""
var count := 1


func _init(p_id := "", p_text := "", p_group := "", p_count := 1) -> void:
	super(p_id, p_text)
	group = p_group
	count = p_count


func _make_state(world: MissionWorld, _dt: float) -> State:
	return State.DONE if world.get_kill_count(group) >= count else state

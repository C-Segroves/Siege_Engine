class_name ConditionObjective
extends Objective
## Done while a condition holds, open again when it stops holding. The other kinds latch DONE; this one follows the
## game's own test live (Earthsiege 1: "the protected unit is safe", "no hostile left"). `condition` is a Callable() -> bool.

var condition := Callable()


func _init(p_id := "", p_text := "", p_condition := Callable()) -> void:
	super(p_id, p_text)
	condition = p_condition


func apply_tick(_world: MissionWorld, _dt: float) -> bool:
	if state == State.PENDING:
		return false
	var next := State.DONE if condition.is_valid() and bool(condition.call()) else State.ACTIVE
	if next == state:
		return false
	state = next
	return true

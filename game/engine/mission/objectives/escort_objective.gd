class_name EscortObjective
extends Objective
## Bring the unit to the area: failed when it dies, done when it is inside.

var unit := ""
var area: AreaShape


func _init(p_id := "", p_text := "", p_unit := "", p_area: AreaShape = null) -> void:
	super(p_id, p_text)
	unit = p_unit
	area = p_area


func _make_state(world: MissionWorld, _dt: float) -> State:
	if not world.is_unit_alive(unit):
		return State.FAILED
	return State.DONE if area != null and area.is_inside(world.get_target_position(unit)) else state

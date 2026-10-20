class_name CarryObjective
extends Objective
## Bring the item to the area: done when the player carries it inside the area.

var item := ""
var area: AreaShape


func _init(p_id := "", p_text := "", p_item := "", p_area: AreaShape = null) -> void:
	super(p_id, p_text)
	item = p_item
	area = p_area


func _make_state(world: MissionWorld, _dt: float) -> State:
	if area != null and world.is_item_carried(item) and area.is_inside(world.get_player_position()):
		return State.DONE
	return state

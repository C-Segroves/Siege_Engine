class_name ReachObjective
extends Objective
## Done when the player is inside the area (a nav point, a waypoint).

var area: AreaShape


func _init(p_id := "", p_text := "", p_area: AreaShape = null) -> void:
	super(p_id, p_text)
	area = p_area


func _make_state(world: MissionWorld, _dt: float) -> State:
	return State.DONE if area != null and area.is_inside(world.get_player_position()) else state

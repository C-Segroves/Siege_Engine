class_name ProtectObjective
extends Objective
## Keep the units alive: failed when one dies, done when the mission releases it (apply_release) with all of them alive.
## The game turns it AT_RISK while the units are in danger (apply_risk).

var units: Array[String] = []
var _released := false
var _at_risk := false


func _init(p_id := "", p_text := "", p_units: Array[String] = []) -> void:
	super(p_id, p_text)
	units = p_units


## The danger passed or came: AT_RISK while true.
func apply_risk(on: bool) -> void:
	_at_risk = on


## The mission is over its protect phase: done when nothing was lost.
func apply_release() -> void:
	_released = true


func _make_state(world: MissionWorld, _dt: float) -> State:
	for u in units:
		if not world.is_unit_alive(u):
			return State.FAILED
	if _released:
		return State.DONE
	return State.AT_RISK if _at_risk else State.ACTIVE

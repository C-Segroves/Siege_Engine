class_name TribesElevator
extends TribesMover
## A Tribes 1 base elevator (scripts/moveable.cs Elevator::*): it waits at its first waypoint; a soldier of its
## team stepping on it (Elevator::onCollision) sends it up waypoint by waypoint, pausing at the ones in between when
## the mission sets stopWayUp (stopWayDown on the way down), WAIT seconds at the top (onLast), then back down; at
## the bottom it waits WAIT before it can be called again (onFirst). A "loop" elevator runs on its own. Without
## power it returns to its first waypoint (Elevator::onPower).

## Elevator::onFirst / onLast / onWaypoint: delayTime = getSimTime() + 1.5.
const WAIT := 1.5

var going_up := true
var _wait_t := 0.0


func _think(delta: float) -> void:
	if not powered:
		going_up = true
		send_goal(0, false)
		return
	if not is_at_goal():
		return
	_wait_t -= delta
	if _wait_t > 0.0:
		return
	if goal == 0 and going_up and not _is_called():
		return
	_step()


func _is_called() -> bool:
	return str(record.get("loop", "")) != "" or not find_users(is_on_deck).is_empty()


## Moves on to the next waypoint, turning round at the ends and pausing where the mission says so.
func _step() -> void:
	var last := waypoints.size() - 1
	if last <= 0:
		return
	var next := goal + (1 if going_up else -1)
	send_goal(clampi(next, 0, last), false)
	if goal == last:
		going_up = false
		_wait_t = WAIT
	elif goal == 0:
		going_up = true
		_wait_t = WAIT
	elif str(record.get("stopwayup" if going_up else "stopwaydown", "")) != "":
		_wait_t = WAIT

class_name WaypointChain
extends RefCounted
## An ordered list of points the player reaches one after the other (Earthsiege nav points, Aerial Assault waypoints).
## Reaching is a straight distance of at most `reach_radius` to the current point.

var points: Array[Vector3] = []
var reach_radius := 0.0
var index := 0


func _init(p_points: Array[Vector3], p_reach_radius: float) -> void:
	points = p_points
	reach_radius = p_reach_radius


func is_complete() -> bool:
	return index >= points.size()


## The point to go to now (the last one once complete).
func make_current() -> Vector3:
	return points[mini(index, points.size() - 1)] if not points.is_empty() else Vector3.ZERO


func make_remaining() -> int:
	return maxi(points.size() - index, 0)


## Moves on when `position` reached the current point; true when it did.
func apply_reach(position: Vector3) -> bool:
	if is_complete() or position.distance_to(points[index]) > reach_radius:
		return false
	index += 1
	return true

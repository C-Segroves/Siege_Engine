class_name PersonalWaypoints
extends RefCounted
## The local player's own waypoints, stuck on the command map and drawn on every compass and heading tape in a
## colour / shape of their own (the mission waypoint is HeadingFrame.make_current_waypoint). Local only: never
## sent over the network; cleared when a battle starts (CommandMap.open of a new battle keeps them, Battle exit
## calls clear).

const MAX := 3
const COLOR := Color(0.3, 0.85, 1.0)

static var points: Array[Vector3] = []


## Adds `p`; false when MAX are already placed.
static func add(p: Vector3) -> bool:
	if points.size() >= MAX:
		return false
	points.append(p)
	return true


static func remove(i: int) -> void:
	if i >= 0 and i < points.size():
		points.remove_at(i)


static func clear() -> void:
	points.clear()


## [{pos, label ("P1"), distance (m, flat)}] seen from `from`.
static func make_marks(from: Vector3) -> Array:
	var out := []
	for i in points.size():
		var d := points[i] - from
		out.append({"pos": points[i], "label": "P%d" % (i + 1), "distance": Vector2(d.x, d.z).length()})
	return out

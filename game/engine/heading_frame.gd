class_name HeadingFrame
extends RefCounted
## The one frame every radar, compass and heading tape draws in (playtest 2026-10-11 A6 / A7), for vehicles and
## soldiers alike: the view heading is the yaw of the pilot's view (Herc.sight_basis: chassis + torso twist; a
## flyer's nose, never its bank; a soldier's look). Compass degrees run clockwise from north = -Z (east = +X);
## radar offsets are metres in the view frame, x to the right and y toward the bottom of the scope (behind).

## {} when there is no waypoint.
const NO_WAYPOINT := {}


## View heading (rad, + = turned left, Godot's yaw) of `h`.
static func make_heading(h: Herc) -> float:
	var fwd := -h.sight_basis().z
	return atan2(-fwd.x, -fwd.z)


## Compass heading of `h` in degrees (0 north, 90 east).
static func make_heading_deg(h: Herc) -> float:
	return fposmod(-rad_to_deg(make_heading(h)), 360.0)


## Compass bearing (degrees) from `from` to `to`.
static func make_bearing_deg(from: Vector3, to: Vector3) -> float:
	var rel := to - from
	return fposmod(rad_to_deg(atan2(rel.x, -rel.z)), 360.0)


## Where `to` lies relative to a viewer at `from` looking along `heading` (rad): metres, x right, y behind.
static func make_radar_offset(from: Vector3, heading: float, to: Vector3) -> Vector2:
	var rel := to - from
	return Vector2(rel.x, rel.z).rotated(heading)


## Degrees from the view heading to the bearing of `to` (-180..180, + = to the right).
static func make_relative_bearing_deg(h: Herc, to: Vector3) -> float:
	return wrapf(make_bearing_deg(h.global_position, to) - make_heading_deg(h), -180.0, 180.0)


## The mission's current nav point (mission runtime nav_points / nav_index), else the nearest marker of group
## "nav_points": {pos, label}, or {} when there is none. `battle` may be null (no mission).
static func make_current_waypoint(h: Herc, battle: Node) -> Dictionary:
	var ms = battle.get("mission") if battle != null else null
	if ms and "nav_points" in ms and "nav_index" in ms:
		var i: int = ms.nav_index
		if i >= 0 and i < ms.nav_points.size():
			return {"pos": ms.nav_points[i], "label": str(i)}
		return NO_WAYPOINT
	var best := NO_WAYPOINT
	var best_d := INF
	for n in h.get_tree().get_nodes_in_group("nav_points"):
		var d := h.global_position.distance_to(n.global_position)
		if d < best_d:
			best_d = d
			best = {"pos": n.global_position, "label": str(n.get_meta("label", "1"))}
	return best

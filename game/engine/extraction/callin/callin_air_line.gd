class_name CallinAirLine
extends RefCounted
## The straight line an aircraft of an air call-in flies (a bombing run, a gunship's approach): it passes through the
## designated point along a flat direction, enters at the map edge (or the rule's distance, whichever is nearer) and
## leaves at the far edge. Pure geometry on the flat (x, z) plane; y is the caller of these functions' business.


## Metres from `point` along `sign` x `dir` (flat unit) to where the line leaves `rect`, at most `limit`. 0 when the
## point already lies outside the rect on that side.
static func make_edge_distance(rect: Rect2, point: Vector3, dir: Vector3, sign: float, limit: float) -> float:
	var t := limit
	var steps := [[point.x, dir.x, rect.position.x, rect.end.x], [point.z, dir.z, rect.position.y, rect.end.y]]
	for s in steps:
		var d: float = s[1] * sign
		if absf(d) < 1e-6:
			continue
		var edge: float = s[3] if d > 0.0 else s[2]
		t = minf(t, (edge - float(s[0])) / d)
	return maxf(t, 0.0)


## Where the aircraft appears: `back_m` behind `point` along the line, nearer when the map edge is (flat, y of point).
static func make_entry(rect: Rect2, point: Vector3, dir: Vector3, back_m: float) -> Vector3:
	return point - dir * make_edge_distance(rect, point, dir, -1.0, back_m)


## Where it leaves: `ahead_m` past `point`, nearer when the map edge is.
static func make_exit(rect: Rect2, point: Vector3, dir: Vector3, ahead_m: float) -> Vector3:
	return point + dir * make_edge_distance(rect, point, dir, 1.0, ahead_m)


## Metres along `dir` from `origin` to the foot of `p` on the line.
static func make_along(origin: Vector3, dir: Vector3, p: Vector3) -> float:
	return (p.x - origin.x) * dir.x + (p.z - origin.z) * dir.z


## Metres `p` is off the line from `origin` along `dir` (always >= 0).
static func make_cross(origin: Vector3, dir: Vector3, p: Vector3) -> float:
	return absf((p.x - origin.x) * dir.z - (p.z - origin.z) * dir.x)


## The impact points of a stick of `count` bombs `spacing` metres apart, centred on `point`, first to last along `dir`.
static func make_stick(point: Vector3, dir: Vector3, count: int, spacing: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for k in count:
		out.append(point + dir * (float(k) - float(count - 1) * 0.5) * spacing)
	return out


## Flat distance from `p` to the segment `a`..`b`.
static func make_segment_distance(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var ap := Vector2(p.x - a.x, p.z - a.z)
	var len2 := ab.length_squared()
	var t := clampf(ap.dot(ab) / len2, 0.0, 1.0) if len2 > 0.0 else 0.0
	return (ap - ab * t).length()


## The flat unit direction of heading `yaw` as the engine turns it (-Z forward).
static func make_direction_of_yaw(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## The heading (yaw) that faces flat direction `dir`.
static func make_yaw_of_direction(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)

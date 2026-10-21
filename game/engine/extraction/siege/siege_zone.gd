class_name SiegeZone
extends RefCounted
## The safe area of the siege: a circle that shrinks over the stages of the rules (safe_area.stages: [seconds, radius])
## towards the last exfil. Each circle lies inside the one before it: the centre slides from the map's centre to the last
## exfil by the share of the radius already given up. Pure geometry over the siege clock.

var centre_start := Vector2.ZERO
var centre_end := Vector2.ZERO
var stages: Array = []


static func make(p_centre_start: Vector2, p_centre_end: Vector2) -> SiegeZone:
	var z := SiegeZone.new()
	z.centre_start = p_centre_start
	z.centre_end = p_centre_end
	z.stages = CybridRules.section("safe_area").get("stages", [[0.0, 4400.0]])
	return z


## The radius `seconds` into the siege (linear between the stages; the last stage's after it).
func make_radius(seconds: float) -> float:
	if stages.is_empty():
		return INF
	if seconds <= float(stages[0][0]):
		return float(stages[0][1])
	for i in range(1, stages.size()):
		if seconds <= float(stages[i][0]):
			var span := float(stages[i][0]) - float(stages[i - 1][0])
			return lerpf(float(stages[i - 1][1]), float(stages[i][1]), (seconds - float(stages[i - 1][0])) / maxf(span, 0.001))
	return float(stages[-1][1])


func make_centre(seconds: float) -> Vector2:
	if stages.is_empty():
		return centre_start
	var first := float(stages[0][1])
	var last := float(stages[-1][1])
	var given_up := (first - make_radius(seconds)) / maxf(first - last, 0.001)
	return centre_start.lerp(centre_end, clampf(given_up, 0.0, 1.0))


## Metres of `p` (x, z) outside the circle at `seconds` (0 inside).
func make_overshoot(p: Vector3, seconds: float) -> float:
	return maxf(Vector2(p.x, p.z).distance_to(make_centre(seconds)) - make_radius(seconds), 0.0)


func is_inside(p: Vector3, seconds: float) -> bool:
	return make_overshoot(p, seconds) <= 0.0

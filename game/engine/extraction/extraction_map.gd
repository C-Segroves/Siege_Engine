class_name ExtractionMap
extends RefCounted
## Where things go on a raid's map (docs/design/extraction.md section 2), from the built world (MapBuilder result):
##   bounds      the map's playable area ("bounds" of the engine map schema), else a square round the origin
##   areas       loot areas: the map's buildings and stations first (farthest-point picks, at least
##               area_min_spacing_m apart), random ground points when the map has too few; faction squads guard them
##   zones       extraction zones on a ring inside the edges (edge_inset)
## Every point is on the ground (terrain height). The host makes the layout; peers get the points in the raid setup.

var battle: Battle
var rng: RandomNumberGenerator
var bounds_min := Vector2(-600, -600)
var bounds_max := Vector2(600, 600)
var areas: Array[Vector3] = []
var zones: Array[Vector3] = []


static func make(p_battle: Battle, built: Dictionary, p_rng: RandomNumberGenerator) -> ExtractionMap:
	var m := ExtractionMap.new()
	m.battle = p_battle
	m.rng = p_rng
	m._apply_bounds(built.get("map", {}) if built.get("map") is Dictionary else {})
	m.areas = m._make_areas(m._make_landmarks(built))
	m.zones = m._make_zones()
	return m


func _apply_bounds(map: Dictionary) -> void:
	var b = map.get("bounds")
	if b is Dictionary and (b.get("min") is Array) and (b.get("max") is Array):
		bounds_min = Vector2(float(b.min[0]), float(b.min[1]))
		bounds_max = Vector2(float(b.max[0]), float(b.max[1]))
		return
	var half := float(ExtractionRules.map_rules().get("fallback_half_size_m", 600.0))
	bounds_min = Vector2(-half, -half)
	bounds_max = Vector2(half, half)


func make_center() -> Vector2:
	return (bounds_min + bounds_max) * 0.5


## Half the size of the area inside the edge inset.
func make_inner_half() -> Vector2:
	return (bounds_max - bounds_min) * 0.5 * (1.0 - float(ExtractionRules.map_rules().get("edge_inset", 0.1)))


## `p` (x, z) on the ground.
func make_ground(p: Vector2) -> Vector3:
	return battle.infantry.make_on_ground(Vector3(p.x, 0.0, p.y))


func is_inside(p: Vector2) -> bool:
	var c := make_center()
	var h := make_inner_half()
	return absf(p.x - c.x) <= h.x and absf(p.y - c.y) <= h.y


## A random point inside the inset area, on the ground.
func make_random_point() -> Vector3:
	var c := make_center()
	var h := make_inner_half()
	return make_ground(c + Vector2(rng.randf_range(-h.x, h.x), rng.randf_range(-h.y, h.y)))


## Buildings and stations inside the play area (x, z).
func _make_landmarks(built: Dictionary) -> Array:
	var out := []
	var map: Dictionary = built.get("map", {}) if built.get("map") is Dictionary else {}
	for o in map.get("interiors", []):
		var p: Array = o.get("pos", [0, 0, 0])
		out.append(Vector2(float(p[0]), float(p[2])))
	for s in built.get("stations", []):
		var xf: Transform3D = s.xf
		out.append(Vector2(xf.origin.x, xf.origin.z))
	return out.filter(func(p: Vector2) -> bool: return is_inside(p))


func _make_areas(landmarks: Array) -> Array[Vector3]:
	var rules := ExtractionRules.map_rules()
	var wanted := int(rules.get("loot_areas", 6))
	var spacing := float(rules.get("area_min_spacing_m", 150.0))
	var picked: Array[Vector2] = []
	var pool := landmarks.duplicate()
	for i in 4 * wanted:
		var r := make_random_point()
		pool.append(Vector2(r.x, r.z))
	while picked.size() < wanted and not pool.is_empty():
		var best := _farthest(pool, picked)
		if not picked.is_empty() and _nearest_distance(best, picked) < spacing:
			break
		picked.append(best)
		pool.erase(best)
	var out: Array[Vector3] = []
	for p in picked:
		out.append(make_ground(p))
	return out


## Of `pool`, the point farthest from every point of `picked` (landmarks win ties: they come first).
static func _farthest(pool: Array, picked: Array[Vector2]) -> Vector2:
	if picked.is_empty():
		return pool[0]
	var best: Vector2 = pool[0]
	var best_d := -1.0
	for p in pool:
		var d := _nearest_distance(p, picked)
		if d > best_d:
			best_d = d
			best = p
	return best


static func _nearest_distance(p: Vector2, others: Array[Vector2]) -> float:
	var best := INF
	for o in others:
		best = minf(best, p.distance_to(o))
	return best


func _make_zones() -> Array[Vector3]:
	var n := int(ExtractionRules.map_rules().get("zones", 3))
	var c := make_center()
	var h := make_inner_half()
	var start := rng.randf() * TAU
	var out: Array[Vector3] = []
	for i in n:
		var a := start + TAU * i / maxf(n, 1)
		out.append(make_ground(c + Vector2(cos(a) * h.x, sin(a) * h.y)))
	return out


## The insertion point: of a few random points, the one farthest from the loot areas (away from the squads).
func make_drop_point() -> Vector3:
	var flat: Array[Vector2] = []
	for a in areas:
		flat.append(Vector2(a.x, a.z))
	var best := make_random_point()
	for i in 12:
		var p := make_random_point()
		if _nearest_distance(Vector2(p.x, p.z), flat) > _nearest_distance(Vector2(best.x, best.z), flat):
			best = p
	return best


## Where a transport for `target` appears: `distance` metres from it, out towards the nearest map edge.
func make_approach_point(target: Vector3, distance: float) -> Vector3:
	var out := Vector2(target.x, target.z) - make_center()
	if out.length() < 1.0:
		out = Vector2.RIGHT
	var p := Vector2(target.x, target.z) + out.normalized() * distance
	return Vector3(p.x, target.y, p.y)


## Index of the zone nearest `p`.
func find_nearest_zone(p: Vector3) -> int:
	var best := 0
	for i in zones.size():
		if zones[i].distance_to(p) < zones[best].distance_to(p):
			best = i
	return best

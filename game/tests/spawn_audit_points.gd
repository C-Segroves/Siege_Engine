extends RefCounted
## The spawn points of one built map for the spawn audit (spawn_audit_check.gd): every place the game can put a unit,
## taken from the real builders' results - MapBuilder (herc / pad / team / infantry spawns), ArenaBuilder (Battledrome
## starts), the extraction mode's layout (ExtractionMap zones, loot areas, drop points, the Varuna sites and their spawn
## areas) and the Cybrid siege's gates. A point is {kind, label, xf, hercs, soldier_on_ground}:
##   kind     "herc" | "pad" | "team N" | "infantry" | "arena" | "exfil" | "drop" | "squad_spot" | "squad_vehicle_spot" | "site_spot" |
##            "gate_place" (the places of the extraction mode: exfil zones, insertion points, spots round the loot areas and Varuna's
##            site spawn areas, round the siege's gates)
##   hercs    whether the game puts a Herc there (a vehicle pad is for the vehicles of its station and flyers, an infantry
##            drop point for soldiers only: a Herc failing there is "not for Hercs")
##   soldier_on_ground  the soldier starts at BattleInfantry.make_ground_point(xf) (bots, extraction) rather than at xf
##            (a respawn at a vehicle start)

## A pad is a Herc start too (the map has no other) when a Herc start lies this close.
const PAD_AS_START_M := 0.5
const DROP_SAMPLES := 6
## Soldiers' spots sampled round each loot area / site spawn area.
const SQUAD_SPOTS := 3
const GATE_DIRECTIONS := 8
const GATE_PLACES := 3
const SEED := 20261021

## The world's clearance, made once for all the spots of a map.
static var _clearance: SpawnClearance


## Every spawn point of the map `built` under `root` (MapBuilder.build's result).
static func collect(root: Node3D, built: Dictionary) -> Array:
	var out: Array = []
	var seen := {}
	_add_all(out, seen, "herc", built.get("herc_spawns", []), true, false)
	var ground_starts: Array = built.get("herc_spawns", [])
	for xf in built.get("pad_spawns", []):
		_add(out, seen, "pad", xf, ground_starts.any(func(g: Transform3D) -> bool: return g.origin.distance_to(xf.origin) < PAD_AS_START_M), false)
	var teams: Dictionary = built.get("team_spawns", {})
	for team in teams:
		_add_all(out, seen, "team %d" % int(team), teams[team], true, false)
	_add_all(out, seen, "infantry", built.get("infantry_spawns", []), false, true)
	return out


## The Battledrome arena starts (ArenaBuilder's pads, then its ring).
static func collect_arena(spawns: Array) -> Array:
	var out: Array = []
	_add_all(out, {}, "arena", spawns, true, false)
	return out


## The extraction mode's places on a built map: the exfil zones, the loot areas, a few insertion points and the siege gates.
static func collect_extraction(root: Node3D, built: Dictionary, bounds: MapBounds) -> Array:
	_clearance = SpawnClearance.make(root)
	var out: Array = []
	var seen := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var m := AuditMap.new()
	m.world = root
	m.rng = rng
	m._apply_bounds(built.get("map", {}))
	m.areas = m._make_listed_areas(built.map) if built.map.has("loot_areas") else m._make_areas(m._make_landmarks(built))
	m.zones = m._make_listed_zones(built.map) if built.map.has("exfil") else m._make_zones()
	for z in m.zones:
		_add(out, seen, "exfil", Transform3D(Basis(), z), false, true)
	for a in m.areas:
		_add_squad_spots(root, out, seen, rng, a, bounds)
	for i in DROP_SAMPLES:
		_add(out, seen, "drop", Transform3D(Basis(), m.make_drop_point()), false, true)
	_add_sites(root, out, seen, rng, built.map, bounds)
	_add_gates(root, out, seen, m, rng, bounds)
	return out


## Where a squad is set down round the loot area `area` (ExtractionSquads.make_place_around): SQUAD_SPOTS soldiers' spots and
## one vehicle's.
static func _add_squad_spots(root: Node3D, out: Array, seen: Dictionary, rng: RandomNumberGenerator, area: Vector3, bounds: MapBounds) -> void:
	var radius := float(ExtractionRules.map_rules().get("area_radius_m", 28.0))
	for k in SQUAD_SPOTS:
		_add(out, seen, "squad_spot", ExtractionSquads.make_place_around(root, rng, area, radius, false, bounds, _clearance), false, false)
	_add(out, seen, "squad_vehicle_spot", ExtractionSquads.make_place_around(root, rng, area, radius * ExtractionSquads.VEHICLE_SPREAD, true, bounds, _clearance), true, false)


## The Varuna sites: the spots round each spawn area where SiteSpawner sets its soldiers down (it fills them in through
## ExtractionSquads.spawn_site_soldier, the same placement as a squad's).
static func _add_sites(root: Node3D, out: Array, seen: Dictionary, rng: RandomNumberGenerator, map: Dictionary, bounds: MapBounds) -> void:
	var radius := float(ExtractionRules.map_rules().get("area_radius_m", 28.0))
	for s in map.get("sites", []):
		for a in s.get("spawn_areas", []):
			var centre := BattleInfantry.make_ground_point(root, Vector3(float(a[0]), 0.0, float(a[1])))
			for k in SQUAD_SPOTS:
				_add(out, seen, "site_spot", ExtractionSquads.make_place_around(root, rng, centre, radius, false, bounds, _clearance), false, false)


## The siege's gates on the map's edge (SiegeSpawner.make_gate's ring) and the spots round each where the wave is set down
## (SiegeSpawner._make_place: ExtractionSquads.make_place_around, level ground for a Herc).
static func _add_gates(root: Node3D, out: Array, seen: Dictionary, m: ExtractionMap, rng: RandomNumberGenerator, bounds: MapBounds) -> void:
	var w := CybridRules.section("waves")
	var half := (m.bounds_max - m.bounds_min) * 0.5 - Vector2.ONE * float(w.get("gate_inset_m", 90.0))
	var spread := float(w.get("gate_spread_m", 40.0))
	for i in GATE_DIRECTIONS:
		var a := TAU * i / GATE_DIRECTIONS
		var dir := Vector2(cos(a), sin(a))
		var edge := minf(half.x / maxf(absf(dir.x), 0.001), half.y / maxf(absf(dir.y), 0.001))
		var gate := m.make_ground(m.make_center() + dir * edge)
		for k in GATE_PLACES:
			_add(out, seen, "gate_place", ExtractionSquads.make_place_around(root, rng, gate, spread, false, bounds, _clearance), false, false)
			_add(out, seen, "gate_vehicle_place", ExtractionSquads.make_place_around(root, rng, gate, spread, true, bounds, _clearance), true, false)


static func _add_all(out: Array, seen: Dictionary, kind: String, list: Array, hercs: bool, ground: bool) -> void:
	for xf in list:
		_add(out, seen, kind, xf, hercs, ground)


static func _add(out: Array, seen: Dictionary, kind: String, xf: Transform3D, hercs: bool, ground: bool) -> void:
	var key := "%s|%d|%d|%d" % [kind, roundi(xf.origin.x * 20.0), roundi(xf.origin.y * 20.0), roundi(xf.origin.z * 20.0)]
	if seen.has(key):
		return
	seen[key] = true
	var label := "%s #%d" % [kind, out.filter(func(p: Dictionary) -> bool: return p.kind == kind).size() + 1]
	out.append({"kind": kind, "label": label, "xf": xf, "hercs": hercs, "soldier_on_ground": ground})


## ExtractionMap without a battle: the points are put on the ground of the world under test.
class AuditMap extends ExtractionMap:
	var world: Node3D

	func make_ground(p: Vector2) -> Vector3:
		return BattleInfantry.make_ground_point(world, Vector3(p.x, 0.0, p.y))

	func make_random_point() -> Vector3:
		var c := make_center()
		var h := make_inner_half()
		return make_ground(c + Vector2(rng.randf_range(-h.x, h.x), rng.randf_range(-h.y, h.y)))

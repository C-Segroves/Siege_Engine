class_name SensorTowers
extends RefCounted
## Turrets and com towers on the radar and the command map. Turrets (Tribes base turrets, Earthsiege "Gun tower"
## structures) and com towers (Tribes pulse sensors, Earthsiege "Radar tower" / "Listening post") are structures, not
## vehicles, so the radars list them here (make_radar_structures). A com tower is also a sensor: while it stands and
## works, every unit within its range is on the radar and command map of its owner's side (is_revealed_by; the Tribes
## sensor net keeps its own detection rules, so a unit its jammers hide stays hidden).

const GROUP := "com_towers"
const COM_TOWER_NAMES := ["Radar tower", "Listening post"]
const TURRET_NAMES := ["Gun tower"]
## Reach (m) of a com tower without a sensor spec of its own (Earthsiege towers).
const DEFAULT_RANGE_M := 1500.0
const CACHE_TEAMS := 64

static var _cache := {}
static var _cache_on := false
static var _tower_pos := PackedVector3Array()
static var _tower_range := PackedFloat32Array()
static var _tower_team := PackedInt32Array()
static var _reaching := {}   # unit instance id -> the indices of the active towers whose reach covers it (inside a cache scope)


static func is_turret(s: Node) -> bool:
	return s is TribesTurret or (s is Structure and TURRET_NAMES.has((s as Structure).display_name))


static func is_com_tower(s: Node) -> bool:
	if s is TribesBaseObject:
		var rules: Dictionary = (s as TribesBaseObject).spec.get("sensor", {}) if (s as TribesBaseObject).spec.get("sensor") is Dictionary else {}
		return not rules.is_empty() and not bool(rules.get("jams", false))
	return s is Structure and COM_TOWER_NAMES.has((s as Structure).display_name)


## Puts `s` in the com tower group when it is one (call once its spec / name is set).
static func apply_register(s: Node) -> void:
	if is_com_tower(s) and not s.is_in_group(GROUP):
		s.add_to_group(GROUP)


## True while the tower stands and works (a Tribes sensor needs power).
static func is_active(s: Node) -> bool:
	return is_instance_valid(s) and bool(s.get("alive")) and TribesBase.is_working(s)


static func make_range(s: Node) -> float:
	if s is TribesBaseObject:
		var rules = (s as TribesBaseObject).spec.get("sensor", {})
		if rules is Dictionary and float(rules.get("range", 0.0)) > 0.0:
			return float(rules.range)
	return DEFAULT_RANGE_M


## True when a working com tower on the viewer's side has `unit` within its range. Between begin_cache and end_cache the
## answer is remembered per side and unit (the radar rules ask once per viewer and unit, twice each, and a server with 64
## viewers asks about every bot); the towers cannot change inside such a scope.
static func is_revealed_by(viewer: Node, unit: Node) -> bool:
	if viewer == null or unit == null or not viewer.is_inside_tree() or not (unit is Node3D):
		return false
	var team := int(viewer.get("team"))
	var p: Vector3 = (unit as Node3D).global_position
	if not _cache_on:
		return _is_revealed_live(viewer.get_tree(), team, p)
	var key := unit.get_instance_id() * CACHE_TEAMS + (team & (CACHE_TEAMS - 1))
	if _cache.has(key):
		return _cache[key]
	var revealed := _is_revealed_by_reaching(team, unit.get_instance_id(), p)
	_cache[key] = revealed
	return revealed


## Starts remembering the answers of is_revealed_by (the towers are read once, now). Pair with end_cache.
static func begin_cache(tree: SceneTree) -> void:
	_cache_on = true
	_cache.clear()
	_reaching.clear()
	_build_active_towers(tree)


static func end_cache() -> void:
	_cache_on = false
	_cache.clear()
	_reaching.clear()


static func _is_revealed_live(tree: SceneTree, team: int, p: Vector3) -> bool:
	for t in tree.get_nodes_in_group(GROUP):
		if (t as Node3D).global_position.distance_to(p) > make_range(t):   # the cheap distance test first
			continue
		var t_team := int(t.get("team"))
		if (t_team == team or TeamRelations.is_allied(team, t_team)) and is_active(t):
			return true
	return false


## The working com towers (position, reach, side) as packed arrays, for a cache scope.
static func _build_active_towers(tree: SceneTree) -> void:
	_tower_pos.clear()
	_tower_range.clear()
	_tower_team.clear()
	for t in tree.get_nodes_in_group(GROUP):
		if is_active(t):
			_tower_pos.append((t as Node3D).global_position)
			_tower_range.append(make_range(t))
			_tower_team.append(int(t.get("team")))


## False when no working com tower (of any side) reaches `unit`: nobody's tower reveals it. Inside a cache scope only (the
## towers were read at begin_cache); outside one it answers true, "maybe", and the caller asks is_revealed_by.
static func is_reached_by_any(unit: Node3D) -> bool:
	return not make_reaching_towers(unit).is_empty() if _cache_on else true


## The indices (tower_team) of the working towers whose reach covers `unit`; inside a cache scope only (else empty).
static func make_reaching_towers(unit: Node3D) -> PackedInt32Array:
	if not _cache_on:
		return PackedInt32Array()
	var unit_id := unit.get_instance_id()
	if not _reaching.has(unit_id):
		_is_revealed_by_reaching(-1, unit_id, unit.global_position)
	return _reaching[unit_id]


## The side of the tower at `index` of make_reaching_towers.
static func make_tower_team(index: int) -> int:
	return _tower_team[index]


## _is_revealed_for_team with the towers that reach the unit found once per unit: a server with many sides (a free-for-all of
## 64 viewers) asks about each unit once per side, and almost every unit is out of every tower's reach.
static func _is_revealed_by_reaching(team: int, unit_id: int, p: Vector3) -> bool:
	var reaching: PackedInt32Array
	if _reaching.has(unit_id):
		reaching = _reaching[unit_id]
	else:
		reaching = PackedInt32Array()
		for i in _tower_pos.size():
			if _tower_pos[i].distance_to(p) <= _tower_range[i]:
				reaching.append(i)
		_reaching[unit_id] = reaching
	for i in reaching:
		if _tower_team[i] == team or TeamRelations.is_allied(team, _tower_team[i]):
			return true
	return false


static func _is_revealed_for_team(team: int, p: Vector3) -> bool:
	for i in _tower_pos.size():
		if _tower_pos[i].distance_to(p) <= _tower_range[i] and (_tower_team[i] == team or TeamRelations.is_allied(team, _tower_team[i])):
			return true
	return false


## Living turrets and com towers `viewer` may see as radar contacts (the displays clip them to the scope).
static func make_radar_structures(viewer: Node) -> Array:
	var out := []
	if viewer == null or not viewer.is_inside_tree() or not SensorLink.is_up(SensorLink.battle_of(viewer)):
		return out
	for s in viewer.get_tree().get_nodes_in_group(Structure.TARGET_GROUP):
		if bool(s.get("alive")) and not bool(s.get_meta(RadarContacts.HIDDEN_META, false)) and (is_turret(s) or is_com_tower(s)):
			out.append(s)
	return out

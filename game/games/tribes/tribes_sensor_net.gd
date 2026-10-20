class_name TribesSensorNet
extends RefCounted
## What each team's radar shows on a Tribes map (docs/TRIBES_BASE_EQUIPMENT.md section 2, "Radar"): a unit is on
## a team's radar when one of the team's sensors detects it, with the rules of the sensor's own data
## (base_equipment.json "sensor" blocks and "player_sensor"):
##   base sensors  working pulse sensors and turret sensors: within range, with a clear line when they need one
##                 (Tribes 1 castLOS, Tribes 2 detectsUsingLOS);
##   soldiers      Tribes 2 only: every soldier's PlayerSensor (detectRadius, LOS, within detectFOVPercent of his
##                 view); Tribes 1 soldiers carry no sensor, so their radar is the team's sensor network alone;
##   jammers       a unit with its sensor jammer pack on, or inside the range of its side's deployed jammer (Tribes 1
##                 supression), is seen only by sensors that detect jammed units (Tribes 2 detectsPassiveJammed: the
##                 soldiers' own eyes; Tribes 1 none). The Tribes 2 cloaking pack jams its wearer the same way, worn or
##                 not;
##   cloaks        a cloaked unit is seen by no sensor beyond its reveal range, except by motion sensors
##                 (detectsCloaked) while it moves at least their detectMinVelocity (CloakRules).
## Teammates and allies are always shown. Detection is refreshed every REFRESH_SECONDS on every peer.

const REFRESH_SECONDS := 0.25
## Line-of-sight checks aim at a unit's middle (metres above its origin).
const SIGHT_HEIGHT := 1.0

var player_sensor: Dictionary = {}
var _detected := {}          # team -> {instance id: true}
var _refresh_t := 0.0


static func make(p_player_sensor: Dictionary) -> TribesSensorNet:
	var net := TribesSensorNet.new()
	net.player_sensor = p_player_sensor
	return net


## True when `unit` shows on the radar of `team`.
func is_shown(team: int, unit: Node) -> bool:
	if TeamRelations.is_allied(team, int(unit.get("team"))):
		return true
	return (_detected.get(team, {}) as Dictionary).has(unit.get_instance_id())


## Recomputes what each team detects (every REFRESH_SECONDS).
func apply_refresh(tree: SceneTree, delta: float) -> void:
	_refresh_t -= delta
	if _refresh_t > 0.0:
		return
	_refresh_t = REFRESH_SECONDS
	var units := tree.get_nodes_in_group("vehicles").filter(func(v: Node) -> bool: return bool(v.get("alive")))
	var sensors := tree.get_nodes_in_group(TribesBase.SENSOR_GROUP).filter(
		func(s: TribesBaseObject) -> bool: return s.is_working())
	_detected.clear()
	for team in _make_teams(units):
		var seen := {}
		for u in units:
			if TeamRelations.is_hostile(team, int(u.team)) and _is_detected(team, u, sensors, units):
				seen[u.get_instance_id()] = true
		_detected[team] = seen


static func _make_teams(units: Array) -> Array:
	var teams := {}
	for u in units:
		teams[int(u.team)] = true
	return teams.keys()


func _is_detected(team: int, unit: Node3D, sensors: Array, units: Array) -> bool:
	var jammed := unit.has_meta(InfantryPack.META_JAM_RADIUS) or CloakRules.is_passive_jammed(unit) 		or _is_under_jammer(team, unit, sensors)
	for s in sensors:
		var o := s as TribesBaseObject
		var rules: Dictionary = o.spec.get("sensor", {})
		if bool(rules.get("jams", false)):
			continue
		if o.team == team and (not jammed or bool(rules.get("detects_jammed", false))) and _senses(o, rules, unit):
			return true
	if player_sensor.is_empty() or (jammed and not bool(player_sensor.get("detects_jammed", false))):
		return false
	for u in units:
		if int(u.team) == team and u is Herc and _soldier_sees(u, unit):
			return true
	return false


## Inside the range of a working jammer that is not `team`'s (Tribes 1 deployable sensor jammer: SensorData
## supression; it hides its own side from the enemy's sensors).
static func _is_under_jammer(team: int, unit: Node3D, sensors: Array) -> bool:
	for s in sensors:
		var o := s as TribesBaseObject
		var rules: Dictionary = o.spec.get("sensor", {})
		if bool(rules.get("jams", false)) and TeamRelations.is_hostile(team, o.team) and 				o.global_position.distance_to(unit.global_position) <= float(rules.get("range", 0.0)):
			return true
	return false


func _senses(o: Node3D, rules: Dictionary, unit: Node3D) -> bool:
	var to := unit.global_position + Vector3.UP * SIGHT_HEIGHT
	var distance := o.global_position.distance_to(to)
	if distance > float(rules.get("range", 0.0)) or CloakRules.is_hidden_from_sensor(unit, rules, distance):
		return false
	return not bool(rules.get("los", false)) or _has_sight(o, o.global_position + Vector3.UP * SIGHT_HEIGHT, unit)


func _soldier_sees(viewer: Herc, unit: Node3D) -> bool:
	var eye := viewer.global_position + Vector3.UP * SIGHT_HEIGHT
	var to := unit.global_position + Vector3.UP * SIGHT_HEIGHT - eye
	if to.length() > float(player_sensor.get("range", 0.0)) or CloakRules.is_hidden_from_sensor(unit, player_sensor, to.length()):
		return false
	if bool(player_sensor.get("fov_only", false)):
		var half := deg_to_rad(float(player_sensor.get("fov_deg", 90.0)) * float(player_sensor.get("fov_percent", 1.0))) * 0.5
		if (-viewer.aim_basis().z).angle_to(to) > half:
			return false
	return not bool(player_sensor.get("los", false)) or _has_sight(viewer, eye, unit)


static func _has_sight(from_node: Node3D, from: Vector3, unit: Node3D) -> bool:
	var exclude := [from_node.get_rid()] if from_node is CollisionObject3D else []
	var q := PhysicsRayQueryParameters3D.create(from, unit.global_position + Vector3.UP * SIGHT_HEIGHT, 0xFFFFFFFF, exclude)
	var hit := from_node.get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.collider == unit or (hit.collider is Node and unit.is_ancestor_of(hit.collider))

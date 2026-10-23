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
## Each sensor is a SensorSource (range, line of sight, view cone, cloak rules) and what a team detects is a ContactTable.

const REFRESH_SECONDS := 0.25

var player_sensor: SensorSource = null
var contacts := ContactTable.new()
var _refresh_t := 0.0


## `p_player_sensor`: the "player_sensor" block of the pack's base_equipment.json ({} = soldiers carry no sensor).
static func make(p_player_sensor: Dictionary) -> TribesSensorNet:
	var net := TribesSensorNet.new()
	if not p_player_sensor.is_empty():
		net.player_sensor = SensorSource.make_from_spec(p_player_sensor)
	return net


## True when `unit` shows on the radar of `team`.
func is_shown(team: int, unit: Node) -> bool:
	if TeamRelations.is_allied(team, int(unit.get("team"))):
		return true
	return contacts.is_detected(team, unit)


## Recomputes what each team detects (every REFRESH_SECONDS).
func apply_refresh(tree: SceneTree, delta: float) -> void:
	_refresh_t -= delta
	if _refresh_t > 0.0:
		return
	_refresh_t = REFRESH_SECONDS
	var units := tree.get_nodes_in_group("vehicles").filter(func(v: Node) -> bool: return bool(v.get("alive")))
	var sensors := _make_working_sensors(tree)
	var now := Time.get_ticks_msec()
	contacts.apply_clear()
	for team in _make_teams(units):
		contacts.apply_team(team)
		for u in units:
			if TeamRelations.is_hostile(team, int(u.team)) and _is_detected(team, u, sensors, units):
				contacts.apply_detected(team, u.get_instance_id(), now)
	contacts.apply_forget(now)


## The working base sensors as [TribesBaseObject, SensorSource] pairs (read from their specs once per refresh).
static func _make_working_sensors(tree: SceneTree) -> Array:
	var out := []
	for s in tree.get_nodes_in_group(TribesBase.SENSOR_GROUP):
		var o := s as TribesBaseObject
		if o.is_working():
			out.append([o, SensorSource.make_from_spec(o.spec.get("sensor", {}))])
	return out


static func _make_teams(units: Array) -> Array:
	var teams := {}
	for u in units:
		teams[int(u.team)] = true
	return teams.keys()


func _is_detected(team: int, unit: Node3D, sensors: Array, units: Array) -> bool:
	var jammed := unit.has_meta(InfantryPack.META_JAM_RADIUS) or CloakRules.is_passive_jammed(unit) 		or _is_under_jammer(team, unit, sensors)
	for pair in sensors:
		var o: TribesBaseObject = pair[0]
		var source: SensorSource = pair[1]
		if source.jams:
			continue
		if o.team == team and (not jammed or source.detects_jammed) and source.senses(o, unit):
			return true
	if player_sensor == null or (jammed and not player_sensor.detects_jammed):
		return false
	for u in units:
		if int(u.team) == team and u is Herc and player_sensor.senses(u, unit, -(u as Herc).aim_basis().z):
			return true
	return false


## Inside the range of a working jammer that is not `team`'s (Tribes 1 deployable sensor jammer: SensorData
## supression; it hides its own side from the enemy's sensors).
static func _is_under_jammer(team: int, unit: Node3D, sensors: Array) -> bool:
	for pair in sensors:
		var o: TribesBaseObject = pair[0]
		var source: SensorSource = pair[1]
		if source.jams and TeamRelations.is_hostile(team, o.team) and o.global_position.distance_to(unit.global_position) <= source.range_m:
			return true
	return false

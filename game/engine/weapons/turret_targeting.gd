class_name TurretTargeting
extends RefCounted
## How every game's base turret picks a target (Battledrome arena turret, Starsiege SSTurret, Tribes TribesTurret):
## the nearest targetable unit within range that the turret's own rules accept. The games differ only in data and
## predicates they plug in: who is hostile (Battledrome side, Starsiege SSTeams, TeamRelations), where a unit is
## aimed at, and the turret's arc / line-of-sight test.

const VEHICLES := "vehicles"
## Most a unit's aim point may sit from its origin (metres): the prefilter measures to the origin first.
const AIM_PAD_M := 6.0


## True for a unit a turret may shoot at all: alive, not dormant (downed, a transport), not stowed in a vehicle.
static func is_targetable(v: Node) -> bool:
	if not is_instance_valid(v) or not bool(v.get("alive")) or v.has_meta("dormant"):
		return false
	return not (v is Infantry and (v as Infantry).stowed)


## The nearest unit for a turret. spec: {from: Vector3 (distances are measured from here), range: metres,
## is_hostile: Callable(unit) -> bool, aim_point: Callable(unit) -> Vector3 (default the unit's origin),
## accepts: Callable(unit, aim point) -> bool (arc, line of sight; default every unit), sensor: the turret's sensor
## rules ({detects_cloaked, min_velocity}; a cloaked unit is hidden from it as CloakRules says)}. Null when none.
static func find_nearest(tree: SceneTree, spec: Dictionary) -> Node3D:
	var from: Vector3 = spec.from
	var hostile: Callable = spec.is_hostile
	var aim: Callable = spec.get("aim_point", Callable())
	var accepts: Callable = spec.get("accepts", Callable())
	var sensor: Dictionary = spec.get("sensor", {})
	var range_m := float(spec.range)
	var reach := range_m + float(spec.get("pad", AIM_PAD_M))
	var reach_sq := reach * reach
	var found := []   # [distance, unit, aim point] of the hostile units inside the range
	for v in tree.get_nodes_in_group(VEHICLES):
		# a cheap native distance test first: most units are far outside the range, and the predicates are script calls
		if from.distance_squared_to((v as Node3D).global_position) > reach_sq:
			continue
		if not is_targetable(v) or not hostile.call(v) or CloakRules.is_hidden_from_sensor(v, sensor, from.distance_to((v as Node3D).global_position)):
			continue
		var p: Vector3 = aim.call(v) if aim.is_valid() else (v as Node3D).global_position
		var d := from.distance_to(p)
		if d < range_m:
			found.append([d, v, p])
	# nearest first, so the arc / line-of-sight test (a physics ray) runs only until one unit passes it
	found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for f in found:
		if not accepts.is_valid() or accepts.call(f[1], f[2]):
			return f[1]
	return null

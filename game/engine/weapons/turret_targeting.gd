class_name TurretTargeting
extends RefCounted
## How every game's base turret picks a target (Battledrome arena turret, Starsiege SSTurret, Tribes TribesTurret):
## the nearest targetable unit within range that the turret's own rules accept. The games differ only in data and
## predicates they plug in: who is hostile (Battledrome side, Starsiege SSTeams, TeamRelations), where a unit is
## aimed at, and the turret's arc / line-of-sight test.

const VEHICLES := "vehicles"


## True for a unit a turret may shoot at all: alive, not dormant (downed, a transport), not stowed in a vehicle.
static func is_targetable(v: Node) -> bool:
	if not is_instance_valid(v) or not bool(v.get("alive")) or v.has_meta("dormant"):
		return false
	return not (v is Infantry and (v as Infantry).stowed)


## The nearest unit for a turret. spec: {from: Vector3 (distances are measured from here), range: metres,
## is_hostile: Callable(unit) -> bool, aim_point: Callable(unit) -> Vector3 (default the unit's origin),
## accepts: Callable(unit, aim point) -> bool (arc, line of sight; default every unit)}. Null when none.
static func find_nearest(tree: SceneTree, spec: Dictionary) -> Node3D:
	var from: Vector3 = spec.from
	var hostile: Callable = spec.is_hostile
	var aim: Callable = spec.get("aim_point", Callable())
	var accepts: Callable = spec.get("accepts", Callable())
	var best: Node3D = null
	var best_d := float(spec.range)
	for v in tree.get_nodes_in_group(VEHICLES):
		if not is_targetable(v) or not hostile.call(v):
			continue
		var p: Vector3 = aim.call(v) if aim.is_valid() else (v as Node3D).global_position
		var d := from.distance_to(p)
		if d < best_d and (not accepts.is_valid() or accepts.call(v, p)):
			best_d = d
			best = v
	return best

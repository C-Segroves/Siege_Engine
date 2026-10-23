class_name LineOfSight
extends RefCounted
## Whether a shooter or a sensor can see its target: nothing (terrain, buildings, other vehicles) on the straight line
## from the eye to the target point. The AI pilots (AIPilot, FlyerAI) hold fire and move when it is blocked
## (playtest 2026-10-11 A4: wingmen shot into hills); the sensors (SensorSource) need it where the originals cast a line.

## Every physics layer: terrain, structures and vehicles all block a shot.
const ALL_LAYERS := 0xFFFFFFFF


## True when the line from `from` to `to` reaches `target` (or its own colliders) before anything else.
## `shooter`'s own body (when it has one) is ignored.
static func is_clear(shooter: Node3D, from: Vector3, target: Node3D, to: Vector3) -> bool:
	if not shooter.is_inside_tree():
		return false
	var exclude := [(shooter as CollisionObject3D).get_rid()] if shooter is CollisionObject3D else []
	var q := PhysicsRayQueryParameters3D.create(from, to, ALL_LAYERS, exclude)
	var hit := shooter.get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or is_part_of(hit.collider, target)


## True when `collider` is `target` or one of its children (a structure's collision bodies).
static func is_part_of(collider: Object, target: Node3D) -> bool:
	return collider == target or (collider is Node and is_instance_valid(target) and target.is_ancestor_of(collider))

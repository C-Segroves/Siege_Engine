class_name LagCompensation
extends RefCounted
## Server-side lag compensation of hitscan shots (docs/DEDICATED_SERVER_SCALING.md section 2.3). A human's beam is
## tested against the units as they stood when the shooter's screen showed them: his round-trip time plus the
## interpolation delay of his client, never more than MAX_REWIND_MS (a high-ping pilot cannot shoot someone
## who already ran behind a corner). Walls and structures are tested where they are now; only the units move back
## through the HitHistory. Bots and the host's own pilot shoot "now" (an empty rewind).
##
## rewind: {history: HitHistory, view_tick: float, ignore_id: int, unit_of: Callable(id) -> Node3D}

const MAX_REWIND_MS := 250.0
const DEFAULT_INTERP_DELAY_MS := 66.0
const MAX_UNIT_SKIPS := 16
const ALL_LAYERS := 0xFFFFFFFF
## Unguided straight shots at least this fast (m/s) count as hitscan for compensation; slower ones (discs, shells)
## stay in server time.
const FAST_PROJECTILE_MPS := 250.0


## How far back (ms) a shooter with round-trip time `rtt_ms` is tested: rtt plus the interpolation delay, capped.
static func make_rewind_ms(rtt_ms: float, interp_delay_ms := DEFAULT_INTERP_DELAY_MS, cap_ms := MAX_REWIND_MS) -> float:
	return clampf(rtt_ms + interp_delay_ms, 0.0, cap_ms)


## The rewind description `shooter`'s battle gives its beam of weapon `weapon` ({} when it is not compensated).
static func make_beam_rewind_for(shooter: Node3D, weapon: Dictionary) -> Dictionary:
	var rewind := make_rewind_for(shooter)
	var policy := rewind.get("policy") as NetProfile
	return rewind if policy == null or policy.compensates_beam(str(weapon.get("id", ""))) else {}


## The rewind description `shooter`'s battle gives it ({} when its shots are not compensated at all).
static func make_rewind_for(shooter: Node3D) -> Dictionary:
	var parent := shooter.get_parent()
	var sync := parent.get_node_or_null("NetSync") if parent != null else null
	if sync == null or not sync.has_method("make_rewind"):
		return {}
	return sync.make_rewind(shooter)


## The first thing a ray from `from` along the unit `dir` hits within `reach`, like PhysicsDirectSpaceState3D.intersect_ray
## ({} when nothing); `excluded` are RIDs it passes through. With a `rewind` the units are taken from the history instead of the physics world.
static func cast_ray(source: Node3D, from: Vector3, dir: Vector3, reach: float, rewind: Dictionary, excluded: Array) -> Dictionary:
	var space := source.get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	exclude.assign(excluded)
	var world := {}
	for i in MAX_UNIT_SKIPS:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + dir * reach, ALL_LAYERS, exclude))
		if hit.is_empty() or rewind.is_empty() or not (hit.collider is Herc):
			world = hit
			break
		exclude.append((hit.collider as Herc).get_rid())   # a unit: its past place decides, not this one
	if rewind.is_empty():
		return world
	return _merge_rewound_hit(world, from, dir, reach, rewind)


static func _merge_rewound_hit(world: Dictionary, from: Vector3, dir: Vector3, reach: float, rewind: Dictionary) -> Dictionary:
	var limit := reach if world.is_empty() else from.distance_to(world.position)
	var history: HitHistory = rewind.history
	var past := history.find_hit(from, dir, limit, float(rewind.view_tick), int(rewind.ignore_id))
	if past.is_empty():
		return world
	var unit: Node3D = (rewind.unit_of as Callable).call(int(past.id))
	if unit == null or not is_instance_valid(unit):
		return world
	return {"position": past.position, "collider": unit, "normal": -dir, "rewound": true}


## Whether `projectile` flies fast and straight enough to be compensated like a beam.
static func is_fast(projectile: Projectile) -> bool:
	return projectile.speed >= FAST_PROJECTILE_MPS and is_straight(projectile)


static func is_straight(projectile: Projectile) -> bool:
	return not projectile.guided and not projectile.lobbed and not projectile.is_mine


## Whether `projectile` is compensated under the game's NetProfile carried by `rewind` (the default speed rule without one).
static func is_compensated(projectile: Projectile, rewind: Dictionary, weapon_id: String) -> bool:
	var policy := rewind.get("policy") as NetProfile
	if policy == null:
		return is_fast(projectile)
	return is_straight(projectile) and policy.compensates_projectile(weapon_id, projectile.speed)

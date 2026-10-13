class_name CommandGoal
extends RefCounted
## What an order asks of the unit that gets it (docs/COMMAND_MAP.md section 2), whatever game the order comes from:
##   attack     go to the target (a combatant or a structure) or the place and fight there; done when the target
##              is destroyed (or the place reached and no enemy left near it);
##   move       go to the place; done on arrival;
##   defend     go to the place (or the object) and hold there; until replaced;
##   hold       stop where it is and hold; until replaced;
##   escort     stay with the commander or a teammate; until replaced, failed when the escorted unit dies;
##   formation  take the unit's formation slot on the commander (AIPilot leader / formation_offset); until replaced;
##   regroup    go to the commander; done on arrival.
## An order's kind and its point / target become the brains' `objective` ({point, urgent, radius, hold, target}:
## InfantryBot and AIPilot read exactly these keys) or, for formation, the AIPilot leader.

const ATTACK := "attack"
const MOVE := "move"
const DEFEND := "defend"
const HOLD := "hold"
const ESCORT := "escort"
const FORMATION := "formation"
const REGROUP := "regroup"
const KINDS := [ATTACK, MOVE, DEFEND, HOLD, ESCORT, FORMATION, REGROUP]
## Kinds that end on their own (the others last until replaced).
const FINISHING := [ATTACK, MOVE, REGROUP]

## How close a place counts as reached (metres): soldiers and vehicles.
const ARRIVE_RADIUS := 15.0
const ESCORT_RADIUS := 10.0
## An attacked place counts as cleared when no enemy is this close to it (metres).
const CLEAR_RADIUS := 60.0


static func is_known(kind: String) -> bool:
	return KINDS.has(kind)


## The brain objective of `kind` at `point`, against `target` (a Node3D or null); {} for formation (the leader
## does it).
static func make_objective(kind: String, point: Vector3, target: Node3D) -> Dictionary:
	match kind:
		ATTACK:
			var out := {"point": point, "urgent": false, "radius": ARRIVE_RADIUS, "hold": true}
			if target:
				out["target"] = target
			return out
		MOVE, REGROUP:
			return {"point": point, "urgent": true, "radius": ARRIVE_RADIUS, "hold": true}
		DEFEND, HOLD:
			return {"point": point, "urgent": false, "radius": ARRIVE_RADIUS, "hold": true}
		ESCORT:
			return {"point": point, "urgent": false, "radius": ESCORT_RADIUS, "hold": true}
	return {}


## True when an order of `kind` with its live `target` (null when none or gone) and point is done for `unit`.
static func is_done(kind: String, unit: Node3D, point: Vector3, target: Node3D, had_target: bool) -> bool:
	match kind:
		ATTACK:
			if had_target:
				return target == null or not bool(target.get("alive"))
			return _flat_distance(unit.global_position, point) <= ARRIVE_RADIUS * 2.0 and not _enemy_near(unit, point)
		MOVE, REGROUP:
			return _flat_distance(unit.global_position, point) <= ARRIVE_RADIUS
	return false


## True when an order of `kind` can no longer be carried out (its escorted unit died).
static func is_failed(kind: String, target: Node3D, had_target: bool) -> bool:
	return kind == ESCORT and had_target and (target == null or not bool(target.get("alive")))


## Ground distance (the brains steer to a place's x/z; its height may be a guess).
static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


static func _enemy_near(unit: Node3D, point: Vector3) -> bool:
	for v in unit.get_tree().get_nodes_in_group("vehicles"):
		if v.alive and TeamRelations.is_hostile(int(unit.get("team")), int(v.team)) and v.global_position.distance_to(point) < CLEAR_RADIUS:
			return true
	return false

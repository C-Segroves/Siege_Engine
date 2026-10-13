class_name ExitSafety
extends RefCounted
## May a raid soldier get out of a vehicle here? (extraction playtest X7; docs/design/extraction.md section 2.) The
## host asks before a rider leaves (OccupancyDirector exit_guard): the spot VehicleExit would put him on must be
##   inside the map's playable area (BattleBounds),
##   above a floor (terrain, building, deck) not so far down that the fall would kill him in his armour at his health
##     (InfantryMotion.make_fall_damage of the free-fall speed; the jetpack is not counted on),
##   not in a map liquid (MapWater: water, lava) where he would land,
##   and free of geometry (not inside a hull, rock or wall).
## Returns "" when safe, else the HUD reason.

const UNSAFE_TEXT := "Wait - not safe to drop: %s"
const REASON_OUTSIDE := "outside the area"
const REASON_FALL := "too high"
const REASON_NO_FLOOR := "no ground below"
const REASON_BLOCKED := "no room to get out"
const REASON_LIQUID := "liquid below"
## How far down a floor is looked for below the exit point (metres).
const FLOOR_PROBE_DEPTH := 2000.0
const CLEAR_RADIUS := 0.5
const CLEAR_HEIGHT := 2.0


## "" when `soldier` may leave `vehicle` now, else the reason (UNSAFE_TEXT).
static func make_refusal(battle: Battle, soldier: Infantry, vehicle: Herc) -> String:
	var p := VehicleExit.make_transform(battle, vehicle).origin
	var reason := make_reason_at(battle, soldier, p)
	return "" if reason == "" else UNSAFE_TEXT % reason


## "" when a soldier set down at `p` survives, else why not (REASON_*).
static func make_reason_at(battle: Battle, soldier: Infantry, p: Vector3) -> String:
	if battle.bounds != null and battle.bounds.bounds.is_outside(p):
		return REASON_OUTSIDE
	var floor_y := make_floor_y(battle, p)
	if is_nan(floor_y):
		return REASON_NO_FLOOR
	if make_fall_damage(soldier, p.y - floor_y) >= make_health(soldier):
		return REASON_FALL
	if MapWater.is_in_water(battle.get_tree(), Vector3(p.x, floor_y + 0.5, p.z)):
		return REASON_LIQUID
	if not is_clear(battle, p):
		return REASON_BLOCKED
	return ""


## Damage of a free fall of `height` metres for `soldier`'s armour (Tribes gravity, from rest).
static func make_fall_damage(soldier: Infantry, height: float) -> float:
	var speed := sqrt(2.0 * Infantry.TRIBES_GRAVITY * maxf(height, 0.0))
	return InfantryMotion.make_fall_damage(soldier.armor, speed)


static func make_health(soldier: Infantry) -> float:
	return float(soldier.components[0].hp) if not soldier.components.is_empty() else 0.0


## Height of the first world surface below `p` (units ignored); NAN when none.
static func make_floor_y(battle: Battle, p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.2, p + Vector3.DOWN * FLOOR_PROBE_DEPTH)
	q.exclude = make_unit_rids(battle)
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		return float(hit.position.y)
	var ground := MapBuilder.ground_height(battle, p)
	return ground if ground <= p.y + 0.2 else NAN


## True when a soldier fits at `p` (no world geometry in his capsule; units ignored).
static func is_clear(battle: Battle, p: Vector3) -> bool:
	var cap := CapsuleShape3D.new()
	cap.radius = CLEAR_RADIUS
	cap.height = CLEAR_HEIGHT
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = Transform3D(Basis(), p + Vector3.UP * (CLEAR_HEIGHT * 0.5 + 0.1))
	q.exclude = make_unit_rids(battle)
	return battle.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


## Every unit's physics body (soldiers, vehicles): floor and room probes pass through them.
static func make_unit_rids(battle: Battle) -> Array[RID]:
	var out: Array[RID] = []
	for h in battle.vehicles.values():
		if is_instance_valid(h) and h is CollisionObject3D:
			out.append((h as CollisionObject3D).get_rid())
	return out
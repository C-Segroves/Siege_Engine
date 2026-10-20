class_name CallinPlacement
extends RefCounted
## Whether a designated point (CallinRequest.point) can take a call-in, and why not (docs/design/lobby_loadout_economy.md
## sections 9.3 and 9.4). The one judgement both the Targeting Laser (live, on the painted spot, on the caller's machine) and the
## host (when the request arrives) make, so the colour the player sees is the answer the host gives:
##   reach       the laser paints no farther than designation.range_m from the caller's eye (the command map has no such limit)
##   area        inside the playable area
##   sky         nothing overhead within lz.sky_clear_m: no roof, bridge or interior (kinds that fall from orbit or land)
##   ground      the exact spot, not a ring search: a clear footprint, level, dry, no unit on it, not enemy ground (CallinSafety)
##   approach    the flight in is open (vehicle delivery by transport: a line from the zone toward the approach point)
## What each kind needs is data: callins.kinds.<kind>.designation {ground, sky, approach, direction} over the defaults below.
## A result is {ok, pos, reason}: `pos` is the floor point the order lands on.

const REASON_RANGE := "Out of range: %d m (the laser reaches %d m)."
const REASON_NO_APPROACH := "No line of sight to the approach: the flight in is blocked."
const REASON_OUTSIDE := "Outside the area."
const REASON_CANNOT := "Cannot call in there: %s."
const REASON_NO_POINT := "Aim at the ground."
const REASON_TAKEN := "Another call-in is already coming down there."
## Metres between the terrain samples of the approach corridor.
const CORRIDOR_STEP_M := 20.0
## What a kind needs when its rules say nothing: the pods and the vehicle come down on the spot, the sweep only needs a place.
const DEFAULT_NEEDS := {"ground": true, "sky": true, "approach": false, "direction": false}
const NEEDS_BY_KIND := {
	CallinRules.KIND_VEHICLE: {"approach": true},
	CallinRules.KIND_RADAR: {"ground": false, "sky": false},
}


static func data() -> Dictionary:
	return CallinRules.data().get("designation", {})


## Metres the Targeting Laser paints.
static func make_range() -> float:
	return float(data().get("range_m", 220.0))


## {ground, sky, approach, direction} of `kind`: the defaults, the kind's table, then its rules' "designation" block.
static func make_needs(kind: String) -> Dictionary:
	var needs := DEFAULT_NEEDS.duplicate()
	needs.merge(NEEDS_BY_KIND.get(kind, {}), true)
	needs.merge(CallinRules.rule(kind).get("designation", {}), true)
	return needs


## True when `kind` flies a line the caller may set with a second click.
static func is_directional(kind: String) -> bool:
	return bool(make_needs(kind).direction)


## Judges `request` for the caller `soldier`. `footprint` is the clear disc the kind needs (CallinChecks.make_footprint),
## `approach_from` the point the flight in comes from (Vector3.INF when it has none).
static func make_judgement(battle: Battle, request: CallinRequest, soldier: Infantry, footprint: float, approach_from := Vector3.INF) -> Dictionary:
	var point := request.point
	var needs := make_needs(request.kind)
	if soldier == null or not soldier.alive:
		return _refuse(point, CallinSafety.REASON_ON_FOOT)
	if request.source == CallinRequest.SOURCE_LASER:
		if soldier.stowed:
			return _refuse(point, CallinSafety.REASON_ON_FOOT)
		var reach := make_range()
		var gap := soldier.aim_origin().distance_to(point)
		if gap > reach + 0.5:
			return _refuse(point, REASON_RANGE % [int(round(gap)), int(round(reach))])
	if battle.bounds != null and battle.bounds.bounds.is_outside(point):
		return _refuse(point, REASON_OUTSIDE)
	if not bool(needs.ground):
		return {"ok": true, "pos": point, "reason": ""}
	var found := CallinSafety.make_reason_at(battle, point, footprint, soldier.team)
	var floor_pos: Vector3 = found.pos
	if bool(needs.sky) and CallinSafety.is_covered(battle, floor_pos):
		return _refuse(floor_pos, CallinSafety.REASON_COVER)
	if str(found.reason) != "":
		return _refuse(floor_pos, REASON_CANNOT % str(found.reason))
	if bool(needs.approach) and approach_from != Vector3.INF and not is_approach_open(battle, floor_pos, approach_from, request.kind):
		return _refuse(floor_pos, REASON_NO_APPROACH)
	return {"ok": true, "pos": floor_pos, "reason": ""}


## True when the flight in is open: from above the zone toward `approach_from`, for designation.approach_check_m, no
## world geometry and no terrain stands in the way (the transport arrives that high above the ground).
static func is_approach_open(battle: Battle, zone: Vector3, approach_from: Vector3, kind: String) -> bool:
	var rule := CallinRules.rule(kind)
	var height := float(rule.get("hover_height_m", 6.0)) + float(rule.get("sling_m", 8.0)) + float(data().get("approach_clearance_m", 4.0))
	var reach := float(data().get("approach_check_m", 120.0))
	var out := Vector3(approach_from.x - zone.x, 0.0, approach_from.z - zone.z).normalized()
	var from := zone + Vector3.UP * height
	var q := PhysicsRayQueryParameters3D.create(from, from + out * reach)
	q.exclude = ExitSafety.make_unit_rids(battle)
	if not battle.get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		return false
	var d := CORRIDOR_STEP_M
	while d <= reach:
		var at := from + out * d
		var ground := MapBuilder.ground_height(battle, at)
		if not is_nan(ground) and ground > at.y:
			return false
		d += CORRIDOR_STEP_M
	return true


static func _refuse(pos: Vector3, reason: String) -> Dictionary:
	return {"ok": false, "pos": pos, "reason": reason}

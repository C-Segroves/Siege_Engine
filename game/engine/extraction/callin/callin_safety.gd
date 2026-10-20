class_name CallinSafety
extends RefCounted
## Landing-zone validation of a call-in (style of ExitSafety; docs/design/lobby_loadout_economy.md section 9.4). A pod or a
## vehicle comes down on the caller's spot, or on the nearest spot within lz.search_m that passes:
##   open sky      nothing within lz.sky_clear_m straight up (no roof, bridge, interior), and the caller is not under cover
##   footprint     a clear disc: walls and rocks within it refuse, the ground inside it is level within the slope limit
##   ground        inside the playable area, a floor below, no liquid, no unit standing on it
##   enemy ground  not on the pad of a hostile faction site (the map's no-call-in zones)
## A result is {ok, pos, reason}: `pos` is the floor point, `reason` the HUD text when it is not ok.

const REASON_COVER := "Under cover (inside a building): call-ins need open sky overhead."
const REASON_ON_FOOT := "Call-ins need you on foot."
const REASON_NONE_FOUND := "No clear landing zone nearby: %s."
const REASON_OUTSIDE := "outside the area"
const REASON_NO_FLOOR := "no ground below"
const REASON_LIQUID := "liquid below"
const REASON_STEEP := "too steep"
const REASON_BLOCKED := "something is in the way"
const REASON_OCCUPIED := "a unit is standing there"
const REASON_ENEMY := "inside enemy ground"
const REASON_ROOFED := "a roof is overhead"
const SAMPLE_DIRECTIONS := 8
## The ground samples of the level test lie on these shares of the footprint radius.
const SAMPLE_RINGS: Array[float] = [0.5, 1.0]
## Height above the floor the sky, wall and floor probes start from (m).
const PROBE_LIFT := 0.4
const WALL_PROBE_HEIGHT := 1.5
const FLOOR_PROBE_HEIGHT := 6.0
## Slack on the level test (m): rough ground is not a ramp.
const LEVEL_SLACK := 0.6
## A surface this flat can be stood on; a steeper hit in the footprint is a wall.
const WALKABLE_NORMAL_Y := 0.5
## A unit this far above the floor is flying over it, not standing on it (m).
const AIRBORNE_HEIGHT := 12.0


## The caller's own check: on foot and under open sky. "" when it passes, else the HUD text.
static func make_caller_refusal(battle: Battle, soldier: Infantry) -> String:
	if soldier == null or not soldier.alive or soldier.stowed:
		return REASON_ON_FOOT
	if is_covered(battle, soldier.global_position):
		return REASON_COVER
	return ""


## True when something lies within lz.sky_clear_m straight above `p` (a roof, a bridge, an interior).
static func is_covered(battle: Battle, p: Vector3) -> bool:
	var reach := float(CallinRules.lz().get("sky_clear_m", 80.0))
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * PROBE_LIFT, p + Vector3.UP * (PROBE_LIFT + reach))
	q.exclude = ExitSafety.make_unit_rids(battle)
	return not battle.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## The landing zone for a footprint of `radius` metres around `center`: the center itself, then rings out to
## lz.search_m, from the way `facing` points. {ok, pos, reason, reasons}: when nothing passes, `reason` is the one most
## candidates failed with and `reasons` counts them all.
static func find_landing(battle: Battle, center: Vector3, radius: float, caller_team: int, facing := Vector3.FORWARD) -> Dictionary:
	var tally := {}
	for p in make_candidates(center, facing):
		var found := make_reason_at(battle, p, radius, caller_team)
		if found.reason == "":
			return {"ok": true, "pos": found.pos, "reason": "", "reasons": tally}
		tally[found.reason] = int(tally.get(found.reason, 0)) + 1
	return {"ok": false, "pos": center, "reason": REASON_NONE_FOUND % make_most_common(tally), "reasons": tally}


## The spots tried, in order: `center`, then rings of SAMPLE_DIRECTIONS spots every lz.search_step_m out to lz.search_m,
## each ring starting from the way `facing` points.
static func make_candidates(center: Vector3, facing: Vector3) -> Array:
	var out := [center]
	var rules := CallinRules.lz()
	var step := maxf(float(rules.get("search_step_m", 10.0)), 1.0)
	var start := atan2(facing.z, facing.x)
	var d := step
	while d <= float(rules.get("search_m", 30.0)):
		for i in SAMPLE_DIRECTIONS:
			var a := start + TAU * float(i) / SAMPLE_DIRECTIONS
			out.append(center + Vector3(cos(a), 0.0, sin(a)) * d)
		d += step
	return out


static func make_most_common(tally: Dictionary) -> String:
	var best := ""
	for reason in tally:
		if best == "" or int(tally[reason]) > int(tally[best]):
			best = str(reason)
	return best


## {pos, reason}: the floor point under `p` and why a footprint of `radius` cannot land there ("" = it can).
static func make_reason_at(battle: Battle, p: Vector3, radius: float, caller_team: int) -> Dictionary:
	var floor_y := ExitSafety.make_floor_y(battle, Vector3(p.x, p.y + FLOOR_PROBE_HEIGHT, p.z))
	var floor_pos := Vector3(p.x, floor_y, p.z)
	if is_nan(floor_y):
		return {"pos": p, "reason": REASON_NO_FLOOR}
	var reason := _make_ground_reason(battle, floor_pos, caller_team)
	if reason == "":
		reason = _make_footprint_reason(battle, floor_pos, radius)
	return {"pos": floor_pos, "reason": reason}


static func _make_ground_reason(battle: Battle, floor_pos: Vector3, caller_team: int) -> String:
	if battle.bounds != null and battle.bounds.bounds.is_outside(floor_pos):
		return REASON_OUTSIDE
	if MapWater.is_in_water(battle.get_tree(), floor_pos + Vector3.UP * 0.5):
		return REASON_LIQUID
	if is_covered(battle, floor_pos):
		return REASON_ROOFED
	if is_in_enemy_zone(battle, floor_pos, caller_team):
		return REASON_ENEMY
	return ""


static func _make_footprint_reason(battle: Battle, floor_pos: Vector3, radius: float) -> String:
	if is_unit_within(battle, floor_pos, radius):
		return REASON_OCCUPIED
	if is_wall_within(battle, floor_pos, radius):
		return REASON_BLOCKED
	if not is_level(battle, floor_pos, radius):
		return REASON_STEEP
	return ""


## True when a unit's body stands within `radius` (flat) of `p`.
static func is_unit_within(battle: Battle, p: Vector3, radius: float) -> bool:
	for h in battle.vehicles.values():
		if is_instance_valid(h) and h.alive and is_on_ground_near(h, p) \
				and Vector2(h.global_position.x - p.x, h.global_position.z - p.z).length() < radius + unit_radius(h):
			return true
	return false


## True when unit `h` is on the ground at `p` (a soldier riding a vehicle or a transport in the air is not).
static func is_on_ground_near(h: Herc, p: Vector3) -> bool:
	return not (h is Infantry and (h as Infantry).stowed) and not h.has_meta("transport") and absf(h.global_position.y - p.y) < AIRBORNE_HEIGHT


## Rough footprint radius of a unit (a soldier's capsule, a vehicle's hull).
static func unit_radius(h: Herc) -> float:
	return 0.8 if h is Infantry else Herc.CAPSULE_MAX_RADIUS


## True when a steep surface (wall, rock, hull) stands within `radius` of `p`: rays at chest height in a ring.
static func is_wall_within(battle: Battle, p: Vector3, radius: float) -> bool:
	var space := battle.get_world_3d().direct_space_state
	var exclude := ExitSafety.make_unit_rids(battle)
	var from := p + Vector3.UP * WALL_PROBE_HEIGHT
	for i in SAMPLE_DIRECTIONS:
		var a := TAU * float(i) / SAMPLE_DIRECTIONS
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(cos(a), 0.0, sin(a)) * radius)
		q.exclude = exclude
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and (hit.normal as Vector3).y < WALKABLE_NORMAL_Y:
			return true
	return false


## True when the ground over the footprint stays within the slope limit of the plane through `p` (its centre).
static func is_level(battle: Battle, p: Vector3, radius: float) -> bool:
	var slope := tan(deg_to_rad(float(CallinRules.lz().get("slope_max_deg", 25.0))))
	for share in SAMPLE_RINGS:
		var d := radius * share
		for i in SAMPLE_DIRECTIONS:
			var a := TAU * float(i) / SAMPLE_DIRECTIONS
			var at := p + Vector3(cos(a), 0.0, sin(a)) * d
			var y := ExitSafety.make_floor_y(battle, Vector3(at.x, p.y + FLOOR_PROBE_HEIGHT, at.z))
			if is_nan(y) or absf(y - p.y) > slope * d + LEVEL_SLACK:
				return false
	return true


## True when `p` lies on the pad of a site whose faction is hostile to `caller_team` (SiteSpawner sites): no call-ins there.
static func is_in_enemy_zone(battle: Battle, p: Vector3, caller_team: int) -> bool:
	var raid = battle.get("extraction")
	if raid == null or raid.site_spawner == null:
		return false
	var margin := float(CallinRules.lz().get("enemy_base_radius_m", 90.0))
	for st in raid.site_spawner.sites:
		var reach := maxf(float(st.pad_radius), margin)
		if TeamRelations.is_hostile(caller_team, int(st.team)) and Vector2(p.x - st.pos.x, p.z - st.pos.z).length() <= reach:
			return true
	return false

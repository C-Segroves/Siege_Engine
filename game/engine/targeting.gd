class_name Targeting
extends RefCounted
## The player's target selection (playtest 2026-10-11 A2), for every vehicle and soldier. Candidates are the living
## units of other, non-allied teams: vehicles and soldiers (group "vehicles") and targetable structures (group
## "targetables": mission buildings with display_name / team / alive / integrity).
##
## target_nearest (C) picks the candidate nearest the crosshair: the smallest angle off the sight line, weighted by
## distance, a blocked line of sight counting extra. target_next (T): the first press locks the closest candidate
## within FRONT_CONE (45 deg) of the facing (the torso / aim direction); further presses within REPEAT_WINDOW_S cycle
## through the other candidates in that cone, nearest first (wrapping). With nothing in the cone it falls back to the
## candidates overall, nearest first. The original games' keys (ES1 T next / C nearest, docs/CODING_STANDARDS.md
## section 2) keep their meaning.

const VEHICLES := "vehicles"
const TARGETABLES := "targetables"
## Half angle (rad) of the cone in front of the facing whose units target_next cycles through.
const FRONT_CONE := deg_to_rad(45.0)
## A target_next press within this many seconds of the previous one cycles on; a later one starts afresh.
const REPEAT_WINDOW_S := 1.5
## Distance (m) that weighs as much as one cone half-angle off the crosshair.
const DISTANCE_SCALE := 600.0
## Score added for a candidate behind terrain or buildings.
const BLOCKED_PENALTY := 2.0
## Aim point above a target's origin (m): the middle of a Herc or a building's lower storey.
const CENTRE_HEIGHT := 4.0


## Living units `viewer` may target: not itself, not allied, not dormant (mission units waiting off stage), and on
## the viewer's radar right now (RadarContacts.is_on_scope).
static func make_candidates(viewer: Herc) -> Array:
	var out := []
	var seen := {}
	for group in [VEHICLES, RadarProxy.GROUP, TARGETABLES]:
		for n in viewer.get_tree().get_nodes_in_group(group):
			if seen.has(n) or not _is_candidate(viewer, n):
				continue
			seen[n] = true
			out.append(n)
	return out


static func _is_candidate(viewer: Herc, n: Node) -> bool:
	return n != viewer and n is Node3D and TargetSelector.is_live(n) \
		and not TeamRelations.is_allied(viewer.team, int(n.get("team"))) and RadarContacts.is_on_scope(viewer, n)


## The point a target is aimed at and ranked by.
static func make_centre(t: Node3D) -> Vector3:
	return t.global_position + Vector3.UP * CENTRE_HEIGHT


## Angle (rad) between `viewer`'s sight line and target `t`.
static func make_off_angle(viewer: Herc, t: Node3D) -> float:
	var to := make_centre(t) - viewer.aim_origin()
	return (-viewer.aim_basis().z).angle_to(to.normalized()) if to.length() > 0.001 else 0.0


## Lower is better: angle off the crosshair in cone half-angles plus the distance in DISTANCE_SCALE units, plus
## BLOCKED_PENALTY when terrain or a building hides it.
static func make_score(viewer: Herc, t: Node3D) -> float:
	var score := make_off_angle(viewer, t) / FRONT_CONE + viewer.aim_origin().distance_to(make_centre(t)) / DISTANCE_SCALE
	if not is_visible_to(viewer, t):
		score += BLOCKED_PENALTY
	return score


static func is_visible_to(viewer: Herc, t: Node3D) -> bool:
	return LineOfSight.is_clear(viewer, viewer.aim_origin(), t, make_centre(t))


## Candidates best first (make_score).
static func make_ranking(viewer: Herc) -> Array:
	var scored := []
	for t in make_candidates(viewer):
		scored.append([make_score(viewer, t), t])
	scored.sort_custom(func(a, b): return a[0] < b[0])
	return scored.map(func(e): return e[1])


## Candidates nearest first.
static func make_distance_ranking(viewer: Herc) -> Array:
	var o := viewer.aim_origin()
	var scored := []
	for t in make_candidates(viewer):
		scored.append([o.distance_squared_to(make_centre(t)), t])
	scored.sort_custom(func(a, b): return a[0] < b[0])
	return scored.map(func(e): return e[1])


## The candidates within FRONT_CONE of the facing, nearest first (line of sight does not matter).
static func make_front_set(viewer: Herc) -> Array:
	return make_distance_ranking(viewer).filter(func(t): return make_off_angle(viewer, t) <= FRONT_CONE)


## target_nearest: the best candidate, null when there is none.
static func pick_best(viewer: Herc) -> Node3D:
	var ranking := make_ranking(viewer)
	return promote(viewer, ranking[0]) if not ranking.is_empty() else null


## target_next: the candidate after `current` in the front cone, nearest first, wrapping round (all candidates, nearest
## first, when none is in the cone); the nearest of them when `current` is not one (a first press passes null).
static func pick_next(viewer: Herc, current: Node3D) -> Node3D:
	var pool := make_front_set(viewer)
	if pool.is_empty():
		pool = make_distance_ranking(viewer)
	if pool.is_empty():
		return null
	var i := pool.find(current)
	return promote(viewer, pool[(i + 1) % pool.size()])


## A far bot's radar contact becomes a full node when targeted (BattleFarUnits.restore, where its proxy stands; the
## receiver keeps a targeted bot's node); anything else is returned as it is.
static func promote(viewer: Herc, t: Node3D) -> Node3D:
	if not (t is RadarProxy):
		return t
	var battle := viewer.get_parent()
	var units = battle.get("far_units") if battle else null
	var h: Herc = units.promote((t as RadarProxy).net_id) if units else null
	return h if h else t

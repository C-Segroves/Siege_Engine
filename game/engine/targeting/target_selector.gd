class_name TargetSelector
extends RefCounted
## The one place an AI shooter (ES1 pilot, soldier bot, every game's turret) chooses its target. Candidates are the
## living units of the "vehicles" group inside a cheap native distance prefilter (the group is the in-battle unit
## index; EntityTable / InterestGrid cells exist only on the network server and carry no dormant / stowed state);
## then hostility (the profile's rule, TeamRelations by default), range, visibility (cloak and radar rules per
## TargetProfile.Visibility), signature weighting, an optional arc / line-of-sight veto, and nearest wins.
## keeps() is the stickiness test for holding a target already chosen.
##
## ctx keys: from (Vector3, distances are measured from here), team (int, the shooter's team), viewer (Node, for
## Visibility.RADAR), aim_point (Callable(unit) -> Vector3, default the unit origin), accepts (Callable(unit, aim
## point) -> bool, arc / line of sight; a physics ray, so it runs on the nearest first and only until one passes).

const VEHICLES := "vehicles"


## True for a unit that may be targeted at all: valid, alive, not dormant (waiting off stage, downed, a transport).
static func is_live(v: Object) -> bool:
	return v != null and is_instance_valid(v) and bool(v.get("alive")) and not (v as Node).has_meta("dormant")


## True when `me` and `t` are Hercs, `t` alive and on a team other than `me` (the wingman radio's "has a contact").
static func is_hostile_live(me: Herc, t: Node) -> bool:
	return t is Herc and is_live(t) and TeamRelations.is_hostile(me.team, (t as Herc).team)


## The best candidate for the shooter in `ctx` under `profile`; null when none.
static func pick(tree: SceneTree, profile: TargetProfile, ctx: Dictionary) -> Node3D:
	var from: Vector3 = ctx.from
	var aim: Callable = ctx.get("aim_point", Callable())
	var accepts: Callable = ctx.get("accepts", Callable())
	var reach_sq := (profile.range_m + profile.pad_m) * (profile.range_m + profile.pad_m)
	var best: Node3D = null
	var best_score := profile.range_m
	var found := []   # [score, unit] of every candidate when an accepts veto must be tried nearest first
	for v in tree.get_nodes_in_group(VEHICLES):
		var cut_sq := reach_sq if accepts.is_valid() else minf(reach_sq, (best_score + profile.pad_m) * (best_score + profile.pad_m))
		# a cheap native distance test first: most units are far outside the range, and the rules below are script calls
		var at := (v as Node3D).global_position
		if from.distance_squared_to(at) > cut_sq:
			continue
		if not _is_candidate(v, profile, ctx):
			continue
		var p: Vector3 = aim.call(v) if aim.is_valid() else at
		var d := from.distance_to(p)
		if is_hidden(v, profile, ctx, from.distance_to(at)):
			continue
		var score := d / RadarMode.make_signature(v) if profile.weigh_signature else d
		if score >= profile.range_m or (not accepts.is_valid() and score >= best_score):
			continue
		if accepts.is_valid():
			found.append([score, v, p])
		else:
			best_score = score
			best = v
	if not accepts.is_valid():
		return best
	found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for f in found:
		if accepts.call(f[1], f[2]):
			return f[1]
	return null


## True while `t` (the held target) is still worth keeping: live, hostile, hidden by nothing and, with a keep_buffer,
## within range_m plus the buffer of `ctx.from`.
static func keeps(profile: TargetProfile, ctx: Dictionary, t: Node) -> bool:
	if t == null or not is_live(t) or not _is_candidate(t, profile, ctx):
		return false
	var distance: float = (ctx.from as Vector3).distance_to((t as Node3D).global_position)
	if profile.keep_buffer >= 0.0 and distance > profile.range_m + profile.keep_buffer:
		return false
	return not is_hidden(t, profile, ctx, distance)


static func _is_candidate(v: Node, profile: TargetProfile, ctx: Dictionary) -> bool:
	if not is_live(v) or (profile.herc_only and not (v is Herc)):
		return false
	if profile.skip_stowed and v is Infantry and (v as Infantry).stowed:
		return false
	var other = v.get("team")
	var other_team := int(other) if other != null else -1
	var team := int(ctx.team)
	return profile.hostile_rule.call(team, other_team) if profile.hostile_rule.is_valid() else TeamRelations.is_hostile(team, other_team)


## True when the profile's visibility rule hides `v` from the shooter at `distance` metres.
static func is_hidden(v: Node, profile: TargetProfile, ctx: Dictionary, distance: float) -> bool:
	match profile.visibility:
		TargetProfile.Visibility.RADAR:
			return CloakRules.is_hidden_from_radar(ctx.get("viewer"), v)
		TargetProfile.Visibility.EYES:
			return InfantryPack.is_hidden_at(v, distance) or CloakRules.is_hidden_from_eyes(v, distance)
		TargetProfile.Visibility.SENSOR:
			return CloakRules.is_hidden_from_sensor(v, profile.sensor, distance)
	return false

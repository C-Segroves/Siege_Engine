class_name GameModeAI
extends RefCounted
## Who of the AI (infantry bots, AI-piloted vehicles) does what in a game mode (docs/formats/game_modes.md §3).
## Pure planning from the rules' state; GameModeBrains hands the goals to the brains.
##
## Team modes work as the Tribes 2 AI objective queue (scripts/aiObjectives.cs, the missions' AIObjective markers):
## each team has objectives with weights per taker (weightLevel1 for the first bot on it, weightLevel2 for the
## second ...); the highest weight left goes to the nearest free bot of the team, until no weight is left. Tribes 2
## maps use their own markers (exported as map.json "ai_objectives": FlagGrab, FlagCapture, FlagDropped,
## FlagCarrier, TouchFlipFlop, DefendLocation, AttackObject); other maps get the same roles made from the mode's
## objects (TEAM weights below, the remake's). A flag / ball carrier always runs it home first.
## Free-for-all modes plan per bot: Hunters bank at the Nexus once they carry enough, else pick up flags; Rabbit
## runs from the hunters with the flag, else chases it; Bounty hunts its target.
##
## A goal: {point: Vector3, urgent: bool, radius: float, hold: bool, attack_object: object id (0 none),
## hunt: net id of a combatant to chase and shoot (0 none)}.

## Weights per taker (1st, 2nd, 3rd, 4th bot) of the made-up roles.
const GRAB := [3850.0, 2000.0, 0.0, 0.0]
const RETURN_FLAG := [4000.0, 2000.0, 0.0, 0.0]
const HUNT_CARRIER := [4500.0, 3000.0, 1000.0, 0.0]
const DEFEND := [3000.0, 1500.0, 500.0, 0.0]
const CLAIM := [3500.0, 1500.0, 500.0, 0.0]
const HOLD := [2000.0, 500.0, 0.0, 0.0]
const ATTACK := [3000.0, 1500.0, 800.0, 0.0]
const GUARD_OWN := [1200.0, 400.0, 0.0, 0.0]
const SIEGE_ATTACK := [4000.0, 4000.0, 4000.0, 4000.0]
const SIEGE_DEFEND := [3000.0, 3000.0, 2000.0, 2000.0]
const ESCORT := [2500.0, 1500.0, 0.0, 0.0]
const DEFEND_RADIUS := 25.0
const TOUCH_RADIUS := 2.0
const ATTACK_RADIUS := 60.0
## Hunters: a bot banks once it carries this many flags (or the greed minimum), and looks for flags this near.
const BANK_AT := 3
const FLAG_SEARCH := 400.0
## Rabbit: the rabbit runs this far away from the nearest hunter.
const FLEE_DISTANCE := 80.0
## Tribes 2 marker types / modes the remake plays (the others - repair, deploy, mortar - are not).
const T2_TOUCH := "AIOTouchObject"
const T2_DEFEND := "AIODefendLocation"
const T2_ATTACK := "AIOAttackObject"
const T2_ATTACK_PLAYER := "AIOAttackPlayer"


## net id -> goal for every AI player (`ai_ids`: the net ids the AI plays) of `players` (make_player dicts).
static func make_goals(rules: GameModeRules, players: Array, ai_ids: Array, markers: Array) -> Dictionary:
	var out := {}
	var ai := players.filter(func(p: Dictionary) -> bool: return ai_ids.has(int(p.id)) and bool(p.get("alive", true)))
	for p in ai:
		var own := _make_personal_goal(rules, p, players)
		if not own.is_empty():
			out[int(p.id)] = own
	if not rules.team_based:
		return out
	for team in rules.teams:
		var free := ai.filter(func(p: Dictionary) -> bool: return int(p.team) == team and not out.has(int(p.id)))
		_assign(make_team_objectives(rules, team, markers), free, out)
	return out


## Highest weight first, each to the nearest free bot.
static func _assign(objectives: Array, free: Array, out: Dictionary) -> void:
	var entries := []
	for o in objectives:
		var weights: Array = o.weights
		for k in weights.size():
			if float(weights[k]) > 0.0:
				entries.append([float(weights[k]), o])
	entries.sort_custom(func(a, b) -> bool: return a[0] > b[0])
	for e in entries:
		if free.is_empty():
			return
		var goal: Dictionary = e[1].goal
		var best := 0
		for i in free.size():
			if (free[i].pos as Vector3).distance_to(goal.point) < (free[best].pos as Vector3).distance_to(goal.point):
				best = i
		out[int(free[best].id)] = goal
		free.remove_at(best)


static func _goal(point: Vector3, urgent: bool, radius: float, hold := false, attack := 0, hunt := 0) -> Dictionary:
	return {"point": point, "urgent": urgent, "radius": radius, "hold": hold, "attack_object": attack, "hunt": hunt}


static func _objective(goal: Dictionary, weights: Array) -> Dictionary:
	return {"goal": goal, "weights": weights}


# ------------------------------------------------------------------ personal goals

static func _make_personal_goal(rules: GameModeRules, p: Dictionary, players: Array) -> Dictionary:
	var carried := rules.make_carried(int(p.id))
	if rules is CtfRules and not carried.is_empty():
		var own: ModeObject = _first(rules.objects_of(ModeObject.KIND_FLAG), func(f: ModeObject) -> bool: return f.team == int(p.team))
		return _goal(own.home, true, TOUCH_RADIUS) if own else {}
	if rules is FindRetrieveRules and not carried.is_empty():
		return _make_stand_goal(rules, p)
	if rules is FootballRules and not carried.is_empty():
		return _make_goal_line_goal(rules, p)
	if rules is HuntersRules:
		return _make_hunter_goal(rules as HuntersRules, p)
	if rules is RabbitRules:
		return _make_rabbit_goal(rules as RabbitRules, p, players)
	if rules is BountyRules:
		var target_key := str((rules as BountyRules).targets.get(str(p.key), ""))
		var t = _first(players, func(q: Dictionary) -> bool: return str(q.key) == target_key)
		return _goal(t.pos, false, ATTACK_RADIUS, false, 0, int(t.id)) if t else {}
	return {}


static func _make_stand_goal(rules: GameModeRules, p: Dictionary) -> Dictionary:
	var best: ModeObject = null
	for s in rules.objects_of(ModeObject.KIND_STAND):
		if s.team == int(p.team) and s.held_object == 0 and (best == null or s.pos.distance_to(p.pos) < best.pos.distance_to(p.pos)):
			best = s
	return _goal(best.pos, true, TOUCH_RADIUS) if best else {}


static func _make_goal_line_goal(rules: GameModeRules, p: Dictionary) -> Dictionary:
	var goal: ModeObject = _first(rules.objects_of(ModeObject.KIND_GOAL), func(g: ModeObject) -> bool: return g.team != int(p.team))
	return _goal(goal.pos, true, TOUCH_RADIUS) if goal else {}


static func _make_hunter_goal(rules: HuntersRules, p: Dictionary) -> Dictionary:
	var n := int(rules.carried.get(str(p.key), 0))
	var need := int(rules._num("greed_min_flags", BANK_AT)) if bool(rules.settings.get("greed_mode", false)) else BANK_AT
	var nexus: ModeObject = _first(rules.objects_of(ModeObject.KIND_NEXUS), func(_o) -> bool: return true)
	if nexus and n >= need and not rules.is_hoard_time():
		return _goal(nexus.pos, true, TOUCH_RADIUS)
	var best: ModeObject = null
	for f in rules.objects_of(ModeObject.KIND_HUNTER_FLAG):
		var d: float = f.pos.distance_to(p.pos)
		if d < FLAG_SEARCH and (best == null or d < best.pos.distance_to(p.pos)):
			best = f
	return _goal(best.pos, true, TOUCH_RADIUS) if best else {}


static func _make_rabbit_goal(rules: RabbitRules, p: Dictionary, players: Array) -> Dictionary:
	var flag: ModeObject = _first(rules.objects_of(ModeObject.KIND_FLAG), func(_o) -> bool: return true)
	if flag == null:
		return {}
	if flag.state == ModeObject.CARRIED and flag.carrier == int(p.id):
		var nearest: Dictionary = {}
		for q in players:
			if int(q.id) != int(p.id) and (nearest.is_empty() or (q.pos as Vector3).distance_to(p.pos) < (nearest.pos as Vector3).distance_to(p.pos)):
				nearest = q
		if nearest.is_empty():
			return {}
		var away := ((p.pos as Vector3) - (nearest.pos as Vector3)).normalized()
		return _goal((p.pos as Vector3) + away * FLEE_DISTANCE, true, TOUCH_RADIUS)
	if flag.state == ModeObject.CARRIED:
		return _goal(flag.pos, false, ATTACK_RADIUS, false, 0, flag.carrier)
	return _goal(flag.pos, true, TOUCH_RADIUS)


# ------------------------------------------------------------------ team objectives

## The team's objectives now: the map's Tribes 2 markers where it has them for the mode, else roles made from
## the mode's objects.
static func make_team_objectives(rules: GameModeRules, team: int, markers: Array) -> Array:
	var from_markers := _make_marker_objectives(rules, team, markers)
	if not from_markers.is_empty():
		return from_markers
	if rules is CtfRules:
		return _make_ctf_objectives(rules, team)
	if rules is CaptureHoldRules:
		return _make_switch_objectives(rules, team, CLAIM, HOLD)
	if rules is SiegeRules:
		var siege := rules as SiegeRules
		return _make_switch_objectives(rules, team, SIEGE_ATTACK if team == siege.offense else [0.0], SIEGE_DEFEND)
	if rules is DefendDestroyRules:
		return _make_destroy_objectives(rules as DefendDestroyRules, team)
	if rules is FindRetrieveRules:
		return _make_retrieve_objectives(rules, team)
	if rules is FootballRules:
		return _make_football_objectives(rules as FootballRules, team)
	return []


static func _make_ctf_objectives(rules: GameModeRules, team: int) -> Array:
	var out := []
	for f in rules.objects_of(ModeObject.KIND_FLAG):
		if f.team != team:
			if f.is_takeable():
				out.append(_objective(_goal(f.pos, true, TOUCH_RADIUS), GRAB))
			continue
		match f.state:
			ModeObject.HOME:
				out.append(_objective(_goal(f.home, false, DEFEND_RADIUS, true), DEFEND))
			ModeObject.DROPPED:
				out.append(_objective(_goal(f.pos, true, TOUCH_RADIUS), RETURN_FLAG))
			ModeObject.CARRIED:
				out.append(_objective(_goal(f.pos, false, ATTACK_RADIUS, false, 0, f.carrier), HUNT_CARRIER))
	return out


static func _make_switch_objectives(rules: GameModeRules, team: int, claim: Array, hold: Array) -> Array:
	var out := []
	for s in rules.objects_of(ModeObject.KIND_SWITCH):
		if s.owner_team != team:
			out.append(_objective(_goal(s.pos, true, TOUCH_RADIUS), claim))
		else:
			out.append(_objective(_goal(s.pos, false, DEFEND_RADIUS, true), hold))
	return out


static func _make_destroy_objectives(rules: DefendDestroyRules, team: int) -> Array:
	var out := []
	for o in rules.objects.values():
		if o.state == ModeObject.DESTROYED:
			continue
		if o.team != team:
			out.append(_objective(_goal(o.pos, false, ATTACK_RADIUS, true, o.id), ATTACK))
		else:
			out.append(_objective(_goal(o.pos, false, DEFEND_RADIUS * 2.0, true), GUARD_OWN))
	return out


static func _make_retrieve_objectives(rules: GameModeRules, team: int) -> Array:
	var out := []
	for f in rules.objects_of(ModeObject.KIND_FLAG):
		if f.state == ModeObject.PLACED and f.owner_team == team:
			out.append(_objective(_goal(f.pos, false, DEFEND_RADIUS, true), HOLD))
		elif f.is_takeable():
			out.append(_objective(_goal(f.pos, true, TOUCH_RADIUS), GRAB if f.state != ModeObject.PLACED else ATTACK))
	return out


static func _make_football_objectives(rules: FootballRules, team: int) -> Array:
	var ball: ModeObject = rules.make_ball()
	if ball == null or ball.state != ModeObject.CARRIED:
		return []
	var carrier_team := -1
	for p in rules.players.values():
		if int(p.id) == ball.carrier:
			carrier_team = int(p.team)
	if carrier_team == team:
		return [_objective(_goal(ball.pos, false, DEFEND_RADIUS), ESCORT)]
	return [_objective(_goal(ball.pos, true, ATTACK_RADIUS, false, 0, ball.carrier), HUNT_CARRIER)]


## Tribes 2 markers of `team` (Siege: the markers of the side the team plays now - the mission's team 1 is the
## offence) that apply now.
static func _make_marker_objectives(rules: GameModeRules, team: int, markers: Array) -> Array:
	var side := team
	if rules is SiegeRules:
		side = 0 if team == (rules as SiegeRules).offense else 1
	var out := []
	for m in markers:
		if int(m.get("team", -1)) != side:
			continue
		var modes: Array = m.get("modes", [])
		if not modes.is_empty() and not modes.has(rules.mode_id):
			continue
		var goal := _make_marker_goal(rules, team, m)
		if not goal.is_empty():
			out.append(_objective(goal, m.get("weights", [0.0])))
	if not out.any(func(o: Dictionary) -> bool: return bool(o.goal.urgent)):
		return []   # no marker to take anything: the made-up roles play the mode
	return out


static func _make_marker_goal(rules: GameModeRules, team: int, m: Dictionary) -> Dictionary:
	var at := ModeObject._vec(m.get("pos", [0, 0, 0]))
	var mode := str(m.get("mode", ""))
	var own_flag: ModeObject = _first(rules.objects_of(ModeObject.KIND_FLAG), func(f: ModeObject) -> bool: return f.team == team)
	var enemy_flag: ModeObject = _first(rules.objects_of(ModeObject.KIND_FLAG), func(f: ModeObject) -> bool: return f.team != team)
	match str(m.get("type", "")):
		T2_TOUCH:
			match mode:
				"FlagGrab":
					return _goal(enemy_flag.pos, true, TOUCH_RADIUS) if enemy_flag and enemy_flag.is_takeable() else {}
				"FlagDropped":
					return _goal(own_flag.pos, true, TOUCH_RADIUS) if own_flag and own_flag.state == ModeObject.DROPPED else {}
				"TouchFlipFlop":
					var s := _make_nearest_switch(rules, at)
					return _goal(s.pos, true, TOUCH_RADIUS) if s and s.owner_team != team else {}
			return {}
		T2_ATTACK_PLAYER:
			if mode == "FlagCarrier" and own_flag and own_flag.state == ModeObject.CARRIED:
				return _goal(own_flag.pos, false, ATTACK_RADIUS, false, 0, own_flag.carrier)
			return {}
		T2_DEFEND:
			return _goal(at, false, DEFEND_RADIUS, true)
		T2_ATTACK:
			return _goal(at, false, ATTACK_RADIUS, true)
	return {}


static func _make_nearest_switch(rules: GameModeRules, at: Vector3) -> ModeObject:
	var best: ModeObject = null
	for s in rules.objects_of(ModeObject.KIND_SWITCH):
		if best == null or s.pos.distance_to(at) < best.pos.distance_to(at):
			best = s
	return best


static func _first(list: Array, pred: Callable) -> Variant:
	for x in list:
		if pred.call(x):
			return x
	return null

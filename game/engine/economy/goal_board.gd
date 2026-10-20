class_name GoalBoard
extends RefCounted
## The goals a lobby offers (docs/design/lobby_loadout_economy.md section 5.4, answer O6): a board of individual goals
## made from the rules' pool for the mode (extraction: the raid task board) and progress from the match stats. Every
## pilot picks his own goals (up to goals.max_individual); there is no team vote and no leader pick: the lobby shows the
## squad's picks read-only (make_teammate_picks) and the squad coordinates by chat. A goal:
## {id, scope: "individual", kind, text, count, reward}.
## Progress kinds read the end-of-match stats: kills, vehicle_kills, objectives, flag_captures, survived.

const SCOPE_INDIVIDUAL := "individual"
const STAT_BY_KIND := {"kills": "kills", "vehicle_kills": "vehicle_kills", "objectives": "objectives",
	"flag_captures": "flag_captures", "survived": "survived"}


## The board of `mode_key` for `seed_value` (the host's seed in the session settings gives everybody the same list).
static func make_board(mode_key: String, seed_value: int) -> Array:
	if mode_key == EconomyRules.EXTRACTION_KEY:
		return _make_raid_board(seed_value)
	var pool: Array = (EconomyRules.goals().get("pool", []) as Array).filter(func(g: Dictionary) -> bool:
		return str(g.get("scope", SCOPE_INDIVIDUAL)) == SCOPE_INDIVIDUAL and _is_offered(g, mode_key))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var board := []
	while board.size() < int(EconomyRules.goals().get("board_size", 6)) and not pool.is_empty():
		board.append(_make_goal(pool.pop_at(rng.randi_range(0, pool.size() - 1))))
	board.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.id) < str(b.id))
	return board


## How much of `goal` the stats have done, 0..count.
static func make_progress(goal: Dictionary, stats: Dictionary) -> int:
	var key := str(STAT_BY_KIND.get(str(goal.get("kind", "")), ""))
	var value: Variant = stats.get(key, 0)
	var done := (1 if value else 0) if value is bool else int(value)
	return clampi(done, 0, int(goal.get("count", 1)))


static func is_done(goal: Dictionary, stats: Dictionary) -> bool:
	return make_progress(goal, stats) >= int(goal.get("count", 1))


## The goals of `board` named in `picked_ids` that `stats` complete (what the ledger pays).
static func make_done_goals(board: Array, picked_ids: Array, stats: Dictionary) -> Array:
	return board.filter(func(g: Dictionary) -> bool: return picked_ids.has(g.id) and is_done(g, stats))


## How many goals a pilot may pick.
static func make_max_picks() -> int:
	return int(EconomyRules.goals().get("max_individual", 3))


## `picked` cut to the goals that are on `board`, at most make_max_picks (a rerolled board voids old picks).
static func make_valid_picks(board: Array, picked: Array) -> Array:
	var ids := board.map(func(g: Dictionary) -> String: return str(g.id))
	return picked.map(func(id: Variant) -> String: return str(id)).filter(func(id: String) -> bool: return ids.has(id)).slice(0, make_max_picks())


## What the squad's other pilots picked, for the read-only teammates' panel: [{peer, name, goals: [goal dicts]}] for the
## pilots of `squad_peers` except `my_peer`, from `roster` entries' "goals" ids against `board`.
static func make_teammate_picks(board: Array, roster: Dictionary, squad_peers: Array, my_peer: int) -> Array:
	var out := []
	for peer in squad_peers:
		if int(peer) == my_peer or not roster.has(peer):
			continue
		var picked: Array = make_valid_picks(board, roster[peer].get("goals", []) if roster[peer].get("goals") is Array else [])
		out.append({"peer": int(peer), "name": str(roster[peer].get("name", "?")),
			"goals": board.filter(func(g: Dictionary) -> bool: return picked.has(str(g.id)))})
	return out


static func _is_offered(goal: Dictionary, mode_key: String) -> bool:
	return (goal.get("modes", []) as Array).any(func(m: String) -> bool: return mode_key == m or mode_key.begins_with(m + EconomyRules.KEY_SEPARATOR))


static func _make_goal(g: Dictionary) -> Dictionary:
	return {"id": str(g.id), "scope": str(g.scope), "kind": str(g.kind), "count": int(g.count), "reward": int(g.reward),
		"text": str(g.text).replace("{count}", str(int(g.count)))}


static func _make_raid_board(seed_value: int) -> Array:
	return RaidTaskBoard.make_board(seed_value).map(func(t: Dictionary) -> Dictionary:
		return {"id": str(t.id), "scope": SCOPE_INDIVIDUAL, "kind": str(t.kind), "count": int(t.get("count", 1)),
			"reward": int(t.get("reward", 0)), "text": str(t.get("text", t.kind))})

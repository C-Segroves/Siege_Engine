class_name LobbyGoals
extends RefCounted
## The goals of the lobby for the local pilot (docs/design/lobby_loadout_economy.md section 5.4, answer O6): the board
## to pick from (an extraction raid: the pilot's raid task board), his picks (up to three), and what his squadmates
## picked, read-only. Everybody picks for himself; the squad coordinates in the chat. Picks travel in the roster entry
## ("goals": ids; in a raid the kit's tasks, as before).

const NO_TEAMMATES := "Nobody else in your squad yet."

static var _board_key := ""
static var _board: Array = []


## The goal board of `settings`: [{id, text, reward, kind, count}]. A raid shows the local pilot's task board.
static func make_board(settings: Dictionary, profile: ExtractionProfile = null) -> Array:
	if ExtractionRules.is_extraction(settings):
		var raid := profile if profile != null else ExtractionProfile.load_for(Net.player_name)
		return raid.make_task_board().map(make_raid_goal)
	var key := "%s|%d" % [EconomyRules.make_mode_key(settings), int(settings.get(GameOptionsModel.GOAL_SEED_KEY, 1))]
	if key != _board_key:   # the lobby asks for the board on every roster change
		_board_key = key
		_board = GoalBoard.make_board(EconomyRules.make_mode_key(settings), int(settings.get(GameOptionsModel.GOAL_SEED_KEY, 1)))
	return _board


static func make_raid_goal(task: Dictionary) -> Dictionary:
	return {"id": str(task.id), "scope": GoalBoard.SCOPE_INDIVIDUAL, "kind": str(task.kind), "count": int(task.get("count", 1)),
		"reward": int(task.get("reward", 0)), "text": RaidTaskBoard.make_text(task)}


## The ids the local pilot picked, from his roster entry (a raid: the tasks of his kit).
static func make_picked_ids(entry: Dictionary, settings: Dictionary) -> Array:
	if ExtractionRules.is_extraction(settings):
		var kit: Dictionary = entry.get("kit", {}) if entry.get("kit") is Dictionary else {}
		return (kit.get("tasks", []) as Array).map(func(t: Dictionary) -> String: return str(t.id))
	return GoalBoard.make_valid_picks(make_board(settings), entry.get("goals", []) if entry.get("goals") is Array else [])


static func make_max_picks(settings: Dictionary) -> int:
	return RaidTaskBoard.make_max_picked() if ExtractionRules.is_extraction(settings) else GoalBoard.make_max_picks()


## What the squad's other pilots picked: [{peer, name, goals: [goal dicts]}], from the roster.
static func make_teammate_picks(settings: Dictionary, roster: Dictionary, squad_peers: Array, my_id: int) -> Array:
	if ExtractionRules.is_extraction(settings):
		return _make_raid_teammate_picks(roster, squad_peers, my_id)
	return GoalBoard.make_teammate_picks(make_board(settings), roster, squad_peers, my_id)


static func _make_raid_teammate_picks(roster: Dictionary, squad_peers: Array, my_id: int) -> Array:
	var out := []
	for peer in squad_peers:
		if int(peer) == my_id or not roster.has(peer):
			continue
		var kit: Dictionary = roster[peer].get("kit", {}) if roster[peer].get("kit") is Dictionary else {}
		out.append({"peer": int(peer), "name": str(roster[peer].get("name", "?")),
			"goals": (kit.get("tasks", []) as Array).map(make_raid_goal)})
	return out


## "Get 10 kills   +80 cr".
static func make_goal_text(goal: Dictionary) -> String:
	return "%s   +%d cr" % [goal.text, int(goal.reward)] if int(goal.reward) > 0 else str(goal.text)


## The goals of `board` that `stats` complete among the local pilot's `picked` ids (what the ledger pays).
static func make_done(board: Array, picked: Array, stats: Dictionary) -> Array:
	return GoalBoard.make_done_goals(board, picked, stats)

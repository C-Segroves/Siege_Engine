extends Node
## Bot pathing (BattleNavigation, InfantryBotRoute), headless: on a Tribes 2 and a Tribes 1 map an AI soldier
## starting outside his team's base gets an urgent objective inside his team's base (beside a station, the case of a
## command-map "move to" inside a base) and must reach it; a walkable path to it exists.
##   godot --headless --audio-driver Dummy --path game res://tests/bot_path_check.tscn [-- <map ids>]

const MAPS := ["tribes2:Katabatic", "tribes:Raindance"]
const SETTLE_FRAMES := 30
## The objective's radius and the time he has to get there (seconds).
const REACH := 4.0
const LIMIT_SECONDS := 60.0
## The goal is the station of his base nearest his spawn, this far beside it.
const BESIDE_STATION := 2.5
## He starts this far out (metres), on the far side of his spawn from the goal: outside the base.
const START_OUTSIDE := 70.0

var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	var maps: Array = Array(OS.get_cmdline_user_args()).filter(func(a: String) -> bool: return not a.begins_with("--"))
	for map in (maps if not maps.is_empty() else MAPS):
		await _check_map(str(map))
	print("bot_path_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _check_map(map: String) -> void:
	print(map, ":")
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": map, "start": BattleInfantry.START_ON_FOOT,
		"ai": [], InfantryBots.CONFIG_KEY: 0, "frag_limit": 500}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	var me := battle.player as Infantry
	battle.pilot.set_physics_process(false)
	var spec := battle.infantry.bots.make_bot_spec(battle.infantry.pack, 0)
	spec.team = me.team
	var brain := battle.infantry.bots.spawn_bot(spec, 0.5)
	var bot := brain.soldier
	bot.end_spawn_protection()
	var goal := _make_goal(battle, bot)
	var out := bot.global_position - goal
	out.y = 0.0
	var start := goal + out.normalized() * START_OUTSIDE
	start.y = MapBuilder.ground_height(battle, start) + 0.5
	bot.global_position = start   # outside the base, its structure between him and the goal
	bot.velocity = Vector3.ZERO
	brain.objective = {"point": goal, "urgent": true, "radius": REACH, "hold": true}
	print("  bot at %s, goal %s (%.0f m, %.1f m lower)" % [bot.global_position.snapped(Vector3.ONE * 0.1),
		goal.snapped(Vector3.ONE * 0.1), bot.global_position.distance_to(goal), bot.global_position.y - goal.y])
	var t := 0.0
	var best := INF
	while t < LIMIT_SECONDS:
		await get_tree().create_timer(0.5, true, true).timeout
		t += 0.5
		best = minf(best, _flat_distance(bot.global_position, goal))
		if best <= REACH and absf(bot.global_position.y - goal.y) < 3.0:
			break
	var nav := BattleNavigation.of(battle)
	_expect(not nav.make_path(bot.global_position, goal).is_empty(), "a walkable path to the goal exists")
	_expect(best <= REACH, "the bot reaches the goal inside the base (closest %.1f m, %.0f s)" % [best, t])
	battle.queue_free()
	await _frames(4)


## Beside the station of the bot's team nearest to him (inside his base); else 40 m from him.
func _make_goal(battle: Battle, bot: Infantry) -> Vector3:
	var best := Vector3.INF
	var stations := battle.get_node_or_null("Stations")
	var list: Array = stations.stations if stations and stations.get("stations") is Array else []
	for st in list:
		var p: Vector3 = (st.xf as Transform3D).origin
		if int(st.get("team", -1)) == bot.team and bot.global_position.distance_to(p) < bot.global_position.distance_to(best):
			best = p
	if best == Vector3.INF:
		return bot.global_position + Vector3(40, 0, 0)
	var side := (bot.global_position - best)
	side.y = 0.0
	return best + side.normalized() * BESIDE_STATION


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

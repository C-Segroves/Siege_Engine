extends Node
## Bot pathing (BattleNavigation, InfantryBotRoute), headless: on a Tribes 2 and a Tribes 1 map an AI soldier
## starting outside his team's base gets an urgent objective inside his team's base (beside a station, the case of a
## command-map "move to" inside a base) and must reach it; a walkable path to it exists.
##   godot --headless --audio-driver Dummy --path game res://tests/bot_path_check.tscn [-- <map ids>]

const MAPS := ["tribes2:Katabatic", "tribes:Raindance"]
const SETTLE_FRAMES := 30
## The objective's radius and the time he has to get there (seconds).
const REACH := 5.0
const LIMIT_SECONDS := 90.0
## The goal is the walkable spot nearest a point this far beside the station of his base nearest his spawn.
const BESIDE_STATION := 2.5
## He starts this far out (metres) from the goal, toward the battlefield's middle or the first other direction
## with a walkable way in: outside the base.
const START_OUTSIDE := 70.0
## The reachable spot must lie this near the station's side (metres): inside the base.
const INSIDE_REACH := 12.0
const START_DIRECTIONS := 8

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
	var station_side := await _make_walkable(battle, _make_goal(battle, bot))
	var nav := BattleNavigation.of(battle)
	var start := Vector3.INF
	var way := PackedVector3Array()
	for k in START_DIRECTIONS:   # the first start outside the base (toward the middle first) with a way in
		var out := Vector3(-station_side.x, 0.0, -station_side.z).normalized().rotated(Vector3.UP, TAU * k / START_DIRECTIONS)
		var p := station_side + out * START_OUTSIDE
		p.y = MapBuilder.ground_height(battle, p) + 0.5
		way = await _make_path(nav, p, station_side)
		if not way.is_empty() and station_side.distance_to(way[way.size() - 1]) < INSIDE_REACH:
			start = p
			break
	_expect(start != Vector3.INF, "a walkable way in from outside the base exists")
	if start == Vector3.INF:
		battle.queue_free()
		await _frames(4)
		return
	# the order's place is the spot by the station he can get to (a station's own body is not)
	var goal := way[way.size() - 1]
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
		if OS.has_environment("BOT_PATH_TRACE") and int(t * 2) % 8 == 0:
			var pth: PackedVector3Array = brain._route.make_path()
			print("  trace t=%.0f pos=%s straight=%.1f idx=%d end=%s pending=%d" % [t, bot.global_position.snapped(Vector3.ONE * 0.1),
				brain._route._straight_left, brain._route._index, pth[pth.size() - 1].snapped(Vector3.ONE * 0.1) if pth.size() > 0 else "-",
				BattleNavigation.of(battle).pending_tiles()])
		if best <= REACH and absf(bot.global_position.y - goal.y) < 3.0:
			break
	_expect(best <= REACH, "the bot reaches the goal inside the base (closest %.1f m, %.0f s)" % [best, t])
	battle.queue_free()
	await _frames(4)


## Beside the station of the bot's team nearest his spawn (inside his base); else 40 m from him.
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
	var out := Vector3(-best.x, 0.0, -best.z).normalized()
	return best + out * BESIDE_STATION


## The walkable spot nearest `p` (a command-map order is a place a soldier can stand on), once its tiles are baked.
func _make_walkable(battle: Battle, p: Vector3) -> Vector3:
	var nav := BattleNavigation.of(battle)
	for i in 600:
		var q := nav.make_walkable_point(p)
		if q != Vector3.INF:
			return q
		await get_tree().physics_frame
	return p


## A path from `from` to `to` once their tiles are baked ([] when none comes).
func _make_path(nav: BattleNavigation, from: Vector3, to: Vector3) -> PackedVector3Array:
	for i in 300:
		var way := nav.make_path(from, to)
		if not way.is_empty():
			return way
		await get_tree().physics_frame
	return PackedVector3Array()


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

extends Node
## Golden trace of the game modes and the extraction raid (MECHANICS_UNIFICATION G7), fixed step:
##   Godot --headless --audio-driver Dummy --path game res://tests/trace_modes_extraction_check.tscn
## Part 1, game modes (GameModeRules driven by a 0.25 s clock, scripted like game_modes_check): CTF, Capture and
## Hold, Defend and Destroy, Siege, deathmatch with a time limit and a kill limit. Records score changes,
## object states, announcements, requests and the end.
## Part 2, an extraction raid on Katabatic (extraction_check "X8 base tasks"): the generator task, the flag
## theft and its response squad, the extraction. Records the director's state, the task lines, notices, the end.
## Writes tests/golden/modes_extraction.json when missing; the raid part skips when its data is not installed.

const TraceSupport = preload("res://tests/trace_support.gd")
const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const STEP := 0.25
const MAP := "tribes2:Katabatic"
const SEED := 4242
const SETTLE_FRAMES := 20
const GENERATOR_FACTION := "imperial"
const FLAG_FACTION := "knights"
const MAX_LAND_FRAMES := 60 * 60
const AFTER_END_FRAMES := 60

var _trace
var _failures := 0
var _pilot := "QA Trace Extraction"   # the test store is per process
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	_guard.back_up()
	Net.player_name = _pilot
	await get_tree().process_frame
	_trace = TraceSupport.new("modes_extraction", get_tree())
	_modes()
	if Assets.has_pack("tribes2") and not MapBuilder.list_maps().filter(func(m): return m.id == MAP).is_empty():
		await _raid()
	else:
		print("trace_modes_extraction_check: raid part skipped (Tribes 2 is not installed)")
	_guard.restore()
	_failures += _trace.finish()
	print("trace_modes_extraction_check: %s (%s; %d failures)" % ["OK" if _failures == 0 else "FAILED", _trace.summary(), _failures])
	get_tree().quit(1 if _failures > 0 else 0)


# ------------------------------------------------------------------ part 1: modes

static func _player(id: int, key: String, team: int, pos := Vector3.ZERO) -> Dictionary:
	return {"id": id, "key": key, "team": team, "alive": true, "pos": pos, "can_touch": true, "vehicle": false,
		"integrity": 1.0}


static func _object(id: int, kind: String, team: int, pos: Vector3, extra := {}) -> Dictionary:
	var d := {"id": id, "kind": kind, "team": team, "pos": [pos.x, pos.y, pos.z]}
	d.merge(extra)
	return d


func _make(mode: String, objects: Array, teams: Dictionary, settings := {}) -> GameModeRules:
	var s := GameModes.make_rules_settings(mode, {})
	s.merge(settings, true)
	var r := GameModes.make_rules(mode, s)
	r.setup(objects, teams)
	return r


## Plays `events` ([[seconds, Callable(rules)]], by time) against `r` for `seconds`, ticking the rules every STEP and
## recording what changed.
func _play(label: String, r: GameModeRules, players: Array, events: Array, seconds: float) -> void:
	_trace.start()
	_trace.add("mode", label, 0)
	var next := 0
	var steps := int(seconds / STEP)
	for i in steps + 1:
		var t := i * STEP
		_trace.set_clock(t)
		while next < events.size() and float(events[next][0]) <= t + 0.0001:
			(events[next][1] as Callable).call(r)
			next += 1
		r.apply_tick(STEP, players)
		_snapshot(r)
	_trace.add("done", "over=%s winner=%s" % [r.over, r.winner], 0)


func _snapshot(r: GameModeRules) -> void:
	for team in r.teams:
		_trace.track("team%d" % int(team), r.score.team_score(int(team)))
	for key in r.score.players:
		_trace.track("player." + str(key), r.score.player_score(str(key)))
	for id in r.objects:
		var o: ModeObject = r.objects[id]
		_trace.track("object%d" % int(id), "%s owner%d carrier%d" % [o.state, int(o.owner_team), int(o.carrier)])
	for msg in r.take_messages():
		_trace.add("announce", str(msg), 0)
	for q in r.take_requests():
		_trace.add("request", str(q.kind), 0)
	if r.over:
		_trace.track("over", "%s|%s" % [r.winner, r.result_text.replace("\n", " / ")])


func _modes() -> void:
	var red_home := Vector3(0, 0, 0)
	var blue_home := Vector3(100, 0, 0)
	var ann := _player(10, "Ann", 0, blue_home)
	var bob := _player(20, "Bob", 1, red_home)
	var ctf := _make("ctf", [_object(1, "flag", 0, red_home), _object(2, "flag", 1, blue_home)], {0: "Red", 1: "Blue"},
		{"score_per_team_flag_cap": 1, "score_per_player_flag_cap": 3, "flag_return_s": 45, "score_limit": 2})
	_play("ctf", ctf, [ann, bob], [
		[1.0, func(r): r.apply_touch(ann, 2)],
		[2.0, func(r): r.apply_touch(bob, 1)],
		[3.0, func(r): r.apply_kill(bob, ann)],
		[4.0, func(r): r.apply_touch(_player(10, "Ann", 0, red_home), 1)],
		[5.0, func(r): r.apply_touch(_player(10, "Ann", 0, red_home), 1)],
		[8.0, func(r): r.apply_touch(_player(10, "Ann", 0, blue_home), 2)],
		[9.0, func(r): r.apply_kill(_player(10, "Ann", 0, Vector3(50, 0, 0)), {})],
		[60.0, func(r): r.apply_touch(_player(10, "Ann", 0, blue_home), 2)],
		[61.0, func(r): r.apply_touch(_player(10, "Ann", 0, red_home), 1)]], 65.0)

	var hold := _make("capture_hold", [_object(1, "switch", -1, Vector3.ZERO), _object(2, "switch", -1, Vector3(50, 0, 0))],
		{0: "Red", 1: "Blue"}, {"capture_delay_s": 12, "hold_interval_s": 0.5, "hold_points": 1, "team_capture_points": 1,
			"score_per_capture": 1, "score_limit_per_switch": 1200})
	_play("capture_hold", hold, [], [
		[1.0, func(r): r.apply_touch(_player(1, "Ann", 0), 1)],
		[20.0, func(r): r.apply_touch(_player(2, "Bob", 1), 1)]], 30.0)

	var dd := _make("defend_destroy", [_object(1, "objective", 0, Vector3.ZERO, {"value": 3}),
		_object(2, "objective", 1, Vector3(9, 0, 0), {"value": 5}), _object(3, "objective", 1, Vector3(19, 0, 0), {"value": 1})],
		{0: "Red", 1: "Blue"})
	_play("defend_destroy", dd, [], [
		[1.0, func(r): r.apply_destroyed(2, _player(1, "Ann", 0))],
		[2.0, func(r): r.apply_destroyed(1, _player(2, "Bob", 0))],
		[3.0, func(r): r.apply_destroyed(3, _player(1, "Ann", 0))]], 6.0)

	var siege: SiegeRules = _make("siege", [_object(1, "switch", 1, Vector3.ZERO)], {0: "Storm", 1: "Inferno"},
		{"first_offense": 0, "round_time_s": 600})
	_play("siege", siege, [], [
		[1.0, func(r): r.apply_touch(_player(2, "Bob", 1), 1)],
		[100.0, func(r): r.apply_touch(_player(1, "Ann", 0), 1)]], 205.0)

	var dm := _make("deathmatch", [], {}, {"score_limit": 2, "time_limit_s": 10})
	var a := _player(1, "Ann", 0)
	var b := _player(2, "Bob", 1)
	_play("deathmatch_time", dm, [a, b], [
		[1.0, func(r): r.apply_kill(b, a)],
		[2.0, func(r): r.apply_kill(a, a)]], 12.0)
	var dm2 := _make("deathmatch", [], {}, {"score_limit": 2})
	_play("deathmatch_kills", dm2, [a, b], [
		[1.0, func(r): r.apply_kill(b, a)],
		[2.0, func(r): r.apply_kill(b, a)]], 4.0)


# ------------------------------------------------------------------ part 2: extraction raid

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _raid() -> void:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	var gen := {"id": "qa_gen", "kind": RaidTaskBoard.KIND_GENERATOR, "faction": GENERATOR_FACTION, "count": 1}
	var flag := {"id": "qa_flag", "kind": RaidTaskBoard.KIND_FLAG, "faction": FLAG_FACTION, "count": 1}
	gen["reward"] = RaidTaskBoard.make_reward(gen)
	flag["reward"] = RaidTaskBoard.make_reward(flag)
	p.tasks = [gen, flag]
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": MAP, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = SEED
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	_trace.start()
	_trace.add("raid", MAP, 0)
	var x: ExtractionDirector = battle.extraction
	_trace.watch_battle(battle)
	var poll := _poll_raid.bind(battle)
	get_tree().physics_frame.connect(poll)
	await _frames(SETTLE_FRAMES)
	var soldier := battle.player as Infantry
	var n := 0
	while soldier.stowed and n < MAX_LAND_FRAMES:
		n += 1
		await get_tree().physics_frame
	soldier.spawn_protection = 600.0
	soldier.apply_spawn_protection()
	var gnode: Node = x.tasks._generator_of.get("qa_gen")
	if gnode != null:
		var hits := 0
		while gnode.alive and hits < 200:
			hits += 1
			gnode.apply_hit(0.0, 1e5, soldier, gnode.global_position)
		_trace.add("step", "generator destroyed", hits)
		await _frames(3)
	var flag_box: LootContainer = null
	for c in x.containers.values():
		if (c as LootContainer).kind == RaidTasks.FLAG_CONTAINER:
			flag_box = c
	if flag_box != null:
		soldier.global_position = flag_box.position + Vector3(1.0, 0.5, 0.0)
		soldier.velocity = Vector3.ZERO
		await _frames(8)
		x._apply_pickup(1)
		_trace.add("step", "flag taken", 1)
		await _frames(5)
		var fr: Dictionary = x.tasks.response.responses.get("qa_flag", {})
		if not fr.is_empty():
			fr["timer"] = 0.0
		await _frames(50)
	x.apply_extract(1)
	_trace.add("step", "extract", 1)
	await _frames(AFTER_END_FRAMES)
	_trace.add("done", "over" if battle.is_over() else "running", 0)
	get_tree().physics_frame.disconnect(poll)
	var s := get_tree().current_scene
	if s:
		s.queue_free()
		get_tree().current_scene = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _frames(3)


func _poll_raid(battle: Node) -> void:
	var x = battle.get("extraction") if is_instance_valid(battle) else null
	if x == null:
		return
	_trace.track("status", x.my_status)
	_trace.track("containers", x.containers.size())
	_trace.track("stowed", 1 if (battle.player != null and battle.player.get("stowed")) else 0)
	var i := 0
	for t in x.tasks.mine:
		_trace.track("task%d" % i, "%s done=%s" % [t.get("kind"), t.get("done")])
		i += 1
	for id in x.tasks.response.responses:
		var fr: Dictionary = x.tasks.response.responses[id]
		_trace.track("response." + str(id), "%s bots>0=%s" % [fr.get("state"), (fr.get("bots", []) as Array).size() > 0])
	_trace.track("objectives", x.make_objective_lines().map(func(l): return str(l.get("text")).split(" [")[0]))
	_trace.track("task_lines", x.tasks.make_objective_lines().map(func(l): return str(l.get("text")).split(" [")[0]))

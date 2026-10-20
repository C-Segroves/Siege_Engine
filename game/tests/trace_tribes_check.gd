extends Node
## Golden trace of Tribes / Tribes 2 training missions (MECHANICS_UNIFICATION G4), driven by a fixed physics step:
##   Godot --headless --audio-driver Dummy --path game res://tests/trace_tribes_check.tscn
## Tribes 1_Welcome (the player is put on the tower switch after 3 s) and Tribes 2 Training1 (intro skipped
## through the script at 5 s, the player put beside the MPB at 7 s) are played to their end (tribes_training_check
## cheat runs); the first other installed training mission of each pack only runs for 30 s.
## Records chat / radio, objectives, spawns, schedule events set / fired, the end; writes tests/golden/tribes.json
## when missing.

const TraceSupport = preload("res://tests/trace_support.gd")
const FPS := 60
const T1_CHEAT := "tribes:1_Welcome"
const T1_SWITCH := "Objective"
const T2_CHEAT := "tribes2:Training1"
const T2_GOAL := "MPB"
const T2_GOAL_OFFSET := Vector3(20, 2, 20)
const IDLE_SECONDS := 30.0
const CHEAT_SECONDS := 120.0
const AFTER_END_FRAMES := 20
const CODE_LEN := 48

var _trace
var _failures := 0
var _seen := {}
var _result := {}


func _ready() -> void:
	await get_tree().process_frame
	var names := []
	for p in TribesMissionRuntime.PACKS:
		for e in TribesMissionRuntime.list_missions(p):
			names.append("%s:%s" % [p, e.id])
	if names.is_empty():
		print("trace_tribes_check: SKIPPED (Tribes game data is not installed)")
		get_tree().quit(0)
		return
	_trace = TraceSupport.new("tribes", get_tree())
	if not TribesMissionRuntime.load_mission(T1_CHEAT).is_empty():
		await _run(T1_CHEAT, CHEAT_SECONDS, 1)
	if not TribesMissionRuntime.load_mission(T2_CHEAT).is_empty():
		await _run(T2_CHEAT, CHEAT_SECONDS, 2)
	for p in TribesMissionRuntime.PACKS:
		for e in TribesMissionRuntime.list_missions(p):
			var n := "%s:%s" % [p, e.id]
			if n != T1_CHEAT and n != T2_CHEAT:
				await _run(n, IDLE_SECONDS, 0)
				break
	_failures += _trace.finish()
	print("trace_tribes_check: %s (%s; %d failures)" % ["OK" if _failures == 0 else "FAILED", _trace.summary(), _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _run(mission_name: String, seconds: float, cheat: int) -> void:
	_trace.start()   # seeds the random generator before the mission script runs
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "mission_name": mission_name, "respawn": false,
		"roster": {1: {"name": "Tester", "vehicle": "", "team": 0, "loadout": []}}}
	_result = {}
	battle.match_finished.connect(func(r): _result.merge(r))
	get_tree().root.add_child(battle)
	_trace.add("mission", mission_name, 0)
	_seen.clear()
	for i in 3:
		await get_tree().physics_frame
	_trace.watch_battle(battle)
	var poll := _poll_schedules.bind(battle)
	get_tree().physics_frame.connect(poll)
	var rt := battle.mission as TribesMissionRuntime
	var step := 0
	var frames := int(seconds * FPS)
	for f in frames:
		await get_tree().physics_frame
		if rt == null or rt.is_mission_over():
			break
		if cheat == 1 and step == 0 and rt.sim_time >= 3.0:
			step = 1
			var sw := rt.sim.resolve(T1_SWITCH)
			battle.player.global_position = rt.sim.position_of(sw) + Vector3(0.5, 0.5, 0.0)
			battle.player.velocity = Vector3.ZERO
			_trace.add("step", "switch", 1)
		elif cheat == 2 and step == 0 and rt.sim_time >= 5.0:
			step = 1
			rt.vm.call_fn("skipintrocinematic", [])
			_trace.add("step", "skip intro", 1)
		elif cheat == 2 and step == 1 and rt.sim_time >= 7.0:
			step = 2
			var mpb := rt.sim.resolve(T2_GOAL)
			var soldier := rt.actors.soldier_of(rt.actors.human_client)
			if soldier:
				soldier.global_position = rt.sim.position_of(mpb) + T2_GOAL_OFFSET
				soldier.velocity = Vector3.ZERO
			_trace.add("step", "mpb", 2)
	for i in AFTER_END_FRAMES:
		await get_tree().physics_frame
	_trace.add("done", "ended" if not _result.is_empty() else "time", 0)
	get_tree().physics_frame.disconnect(poll)
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


## Schedule events: "timer+" when one is set , "timer" when it ran,
## "timer-" when it was cancelled.
func _poll_schedules(battle: Node) -> void:
	var rt := battle.get("mission") as TribesMissionRuntime if is_instance_valid(battle) else null
	if rt == null:
		return
	var events: Dictionary = rt.schedules._events
	for id in events:
		if not _seen.has(id):
			var ev: Dictionary = events[id]
			var what := str(ev.get("code", ev.get("name", ""))).left(CODE_LEN).replace("\n", " ")
			_seen[id] = [what, float(ev.at)]
			_trace.add("timer+", what, 0)
	for id in _seen.keys():
		if not events.has(id):
			var due: bool = float(_seen[id][1]) <= rt.sim_time + 0.1
			_trace.add("timer" if due else "timer-", _seen[id][0], 0)
			_seen.erase(id)

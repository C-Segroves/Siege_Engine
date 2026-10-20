extends Node
## Golden trace of Starsiege missions (MECHANICS_UNIFICATION G3), driven by a fixed physics step:
##   Godot --headless --audio-driver Dummy --path game res://tests/trace_ss_check.tscn
## HA0 is played like test_starsiege_mission (teleport to Nav Alpha at 8 s, destroy the flyer at 20 s, the guard
## at 30 s and move to Nav Bravo), CE3 only runs for 60 s of simulation time (script messages and timers).
## Records chat / radio, objectives, spawns, schedule() timers set and fired, script state and the end;
## writes tests/golden/ss.json when missing.

const TraceSupport = preload("res://tests/trace_support.gd")
const FPS := 60
const STEPS := [[1.0, 0], [8.0, 1], [20.0, 2], [30.0, 3]]   # HA0: [sim seconds, step]
const HA0_SECONDS := 60.0
const IDLE_MISSIONS := {"CE3": 60.0}
const AFTER_END_FRAMES := 20
const CODE_LEN := 48

var _trace
var _failures := 0
var _timers_seen := {}


func _ready() -> void:
	await get_tree().process_frame
	if not FileAccess.file_exists("res://../gamedata/starsiege/missions/HA0.json") and not _installed():
		print("trace_ss_check: SKIPPED (Starsiege game data is not installed)")
		get_tree().quit(0)
		return
	_trace = TraceSupport.new("ss", get_tree())
	await _run("HA0", HA0_SECONDS, true)
	for mid in IDLE_MISSIONS:
		await _run(mid, IDLE_MISSIONS[mid], false)
	_failures += _trace.finish()
	print("trace_ss_check: %s (%s; %d failures)" % ["OK" if _failures == 0 else "FAILED", _trace.summary(), _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _installed() -> bool:
	return not MissionCompiler.load_mission("starsiege:HA0", PackedInt32Array(), 1, -1, {"resolve_texts": true}).is_empty()


func _run(mid: String, seconds: float, scripted: bool) -> void:
	_trace.start()   # seeds the random generator before the mission script runs
	var battle: Node = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "mission_name": "starsiege:" + mid, "respawn": false,
		"roster": {1: {"name": "Tester", "vehicle": "starsiege:pi_eman", "team": 0, "loadout": []}}}
	var result := {}
	battle.match_finished.connect(func(r): result.merge(r))
	get_tree().root.add_child(battle)
	_trace.add("mission", mid, 0)
	_timers_seen = {}
	await get_tree().physics_frame
	await get_tree().physics_frame
	_trace.watch_battle(battle, func() -> Dictionary: return {})
	var poll := _poll_timers.bind(battle)
	get_tree().physics_frame.connect(poll)
	var step := 0
	var frames := int(seconds * FPS)
	for f in frames:
		await get_tree().physics_frame
		var ms = battle.get("mission")
		if scripted and ms != null and step < STEPS.size() and float(f) / FPS >= STEPS[step][0]:
			_script_step(battle, ms, int(STEPS[step][1]))
			step += 1
		if not result.is_empty():
			break
	for i in AFTER_END_FRAMES:
		await get_tree().physics_frame
	_trace.add("done", "ended" if not result.is_empty() else "time", 0)
	get_tree().physics_frame.disconnect(poll)
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	Sfx.stop_music(0.0)


## HA0 like test_starsiege_mission._ha0.
func _script_step(battle: Node, ms, step: int) -> void:
	var p: Node3D = battle.player
	_trace.add("step", str(step), step)
	if p == null:
		return
	match step:
		1:
			var nav: Vector3 = ms._obj_pos(ms.ss_resolve("MissionGroup/navMarkers/navAlpha"))
			p.global_position = nav + Vector3(0, 5, 150)
		2:
			ms.ss_builtin("damageobject", [ms.ss_resolve("MissionGroup/flyerGroup/Flyer1"), 1e9])
		3:
			ms.ss_builtin("damageobject", [ms.ss_resolve("MissionGroup/guardGroup/guard1"), 1e9])
			var nav: Vector3 = ms._obj_pos(ms.ss_resolve("MissionGroup/navMarkers/navBravo"))
			p.global_position = nav + Vector3(0, 5, 0)


## schedule() timers by their code text: "timer+" when one is set (code: due in whole seconds), "timer" when one ran.
func _poll_timers(battle: Node) -> void:
	var ms = battle.get("mission") if is_instance_valid(battle) else null
	if ms == null or ms.get("timers") == null:
		return
	var now := {}
	var due := {}
	for t in ms.timers:
		var key := String(t[1]).left(CODE_LEN)
		now[key] = int(now.get(key, 0)) + 1
		due[key] = int(roundf(float(t[0])))
	for key in now:
		for i in int(now[key]) - int(_timers_seen.get(key, 0)):
			_trace.add("timer+", key, 0)   # the due time is not kept: it shifts by a frame with the poll order
	for key in _timers_seen:
		for i in int(_timers_seen[key]) - int(now.get(key, 0)):
			_trace.add("timer", key, 0)
	_timers_seen = now

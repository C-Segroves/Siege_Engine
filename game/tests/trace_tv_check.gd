extends Node
## Golden trace of Tribes: Vengeance campaign missions (MECHANICS_UNIFICATION G6), driven by a fixed physics step:
##   Godot --headless --audio-driver Dummy --path game res://tests/trace_tv_check.tscn
## The first mission and the first one with waypoints each run 40 s; the player (protected) is put at the centre of
## the next enabled script trigger every 2 s (MessageTriggerEnter like walking there), or, when the install has
## no imported script, onto the next waypoint of the Aerial Assault fallback rule.
## Records chat / radio, objectives, spawns, script state (running scripts, objective states, countdown, placed
## soldiers spawned) and the end; writes tests/golden/tv.json when missing. Skips when Tribes: Vengeance or
## Tribes 2 is not imported.

const TraceSupport = preload("res://tests/trace_support.gd")
const PACK := "tribes_v"
const FPS := 60
const SETTLE_FRAMES := 30
const MISSION_SECONDS := 40.0
const TRIGGER_EVERY_FRAMES := 2 * 60
const MAX_TRIGGERS := 20
const AFTER_END_FRAMES := 40

var _trace
var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	if not Assets.has_pack(PACK) or not Assets.has_pack("tribes2"):
		print("trace_tv_check: SKIPPED (Tribes: Vengeance / Tribes 2 is not imported)")
		get_tree().quit(0)
		return
	_trace = TraceSupport.new("tv", get_tree())
	await _run(0)
	var wp := _first_with_waypoints()
	if wp > 0:
		await _run(wp)
	_failures += _trace.finish()
	print("trace_tv_check: %s (%s; %d failures)" % ["OK" if _failures == 0 else "FAILED", _trace.summary(), _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _first_with_waypoints() -> int:
	Session.start_stage_campaign(PACK)
	var c: Object = Session.campaign
	for i in range(1, c.missions.size()):
		var m := MapBuilder.load_map("%s:%s" % [PACK, c.missions[i].map])
		if not (m.get("waypoints", []) as Array).is_empty():
			return i
	return 0


func _state(battle: Node) -> Dictionary:
	var rt := battle.get("mission") as TVMissionRuntime
	if rt == null:
		return {}
	var s := {"waypoint": rt.waypoint_index, "over": 1 if rt.is_over() else 0}
	if rt.script_run == null:
		return s
	s["ended"] = 1 if rt.script_run.ended else 0
	s["countdown"] = int(roundf(rt.countdown))
	var spawned := 0
	for n in rt._npcs:
		if bool(n.get("spawned", false)):
			spawned += 1
	s["npcs_spawned"] = spawned
	for i in rt.objectives.size():
		s["objective%d" % i] = int(rt.objectives[i].get("state", 0))
	return s


func _run(index: int) -> void:
	Session.start_stage_campaign(PACK)
	Session.campaign.index = index
	var herc := MatchFlow.make_issued_soldier()
	_trace.start()   # seeds the random generator before the mission script runs
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = MatchFlow.make_mission_config(str(herc.vehicle), [], {})
	get_tree().root.add_child(b)
	_trace.add("mission", str(Session.current_mission().get("name", "")), index)
	_trace.watch_battle(b, func() -> Dictionary: return _state(b))
	for _f in SETTLE_FRAMES:
		await get_tree().physics_frame
	var rt := b.mission as TVMissionRuntime
	var visited := 0
	if rt != null and b.player != null:
		(b.player as Infantry).spawn_protection = 600.0
		(b.player as Infantry).apply_spawn_protection()
	for f in int(MISSION_SECONDS * FPS):
		await get_tree().physics_frame
		if rt == null or rt.is_over():
			break
		if f % TRIGGER_EVERY_FRAMES == TRIGGER_EVERY_FRAMES - 1 and visited < MAX_TRIGGERS and b.player != null:
			var t = _next_trigger(rt, visited)
			visited += 1
			if t != null:
				var c: Array = t.rec.pos
				b.player.global_position = Vector3(float(c[0]), float(c[1]) + 1.0, float(c[2]))
				b.player.velocity = Vector3.ZERO
				_trace.add("step", str(t.rec.get("label", "")), visited)
			elif rt.waypoint_index < rt.targets.size():   # no script imported: the Aerial Assault waypoint rule
				var p: Vector3 = rt.targets[rt.waypoint_index].pos
				b.player.global_position = p + Vector3(0, 2.0, 0)
				b.player.velocity = Vector3.ZERO
				_trace.add("step", "waypoint %d" % rt.waypoint_index, visited)
	for _f in AFTER_END_FRAMES:
		await get_tree().physics_frame
	_trace.add("done", "over" if (rt != null and rt.is_over()) else "running", 0)
	b.queue_free()
	for _f in 3:
		await get_tree().physics_frame


## The `n`-th enabled trigger (list order), wrapping when fewer are enabled.
func _next_trigger(rt: TVMissionRuntime, n: int):
	var enabled := rt._triggers.filter(func(t) -> bool: return bool(t.enabled))
	if enabled.is_empty():
		return null
	return enabled[n % enabled.size()]

extends Node
## Golden trace of Tribes: Aerial Assault missions (MECHANICS_UNIFICATION G5), driven by a fixed physics step:
##   Godot --headless --audio-driver Dummy --path game res://tests/trace_aa_check.tscn
## Missions (the aa_campaign_check scenarios): training 1 (30 s idle), the first generators mission (every
## generator reported destroyed), MISSION06 Onslaught (scripted: vehicle pad, WAYPT1, preparation time skipped)
## and MISSION01 (arena: score limit reached by kills).
## A second trace, tests/golden/aa_end.json, records one scripted closing-prompt ending (the script's Success prompt: the
## voice plays, then END_DELAY, then the end) so the grace-after-voice path has its own golden.
## Records chat / radio, objectives, spawns, script state, kills and the end; writes tests/golden/aa.json when
## missing. Skips when Aerial Assault or Tribes 2 is not imported.

const TraceSupport = preload("res://tests/trace_support.gd")
const PACK := "tribes_aa"
const FPS := 60
const SETTLE_FRAMES := 30
const IDLE_SECONDS := 30.0
const STEP_FRAMES := 40
const AFTER_END_FRAMES := 40

var _trace
var _end_trace
var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	if not Assets.has_pack(PACK) or not Assets.has_pack("tribes2"):
		print("trace_aa_check: SKIPPED (Aerial Assault / Tribes 2 is not imported)")
		get_tree().quit(0)
		return
	_trace = TraceSupport.new("aa", get_tree())
	await _training()
	await _generators()
	await _scripted()
	await _arena()
	_failures += _trace.finish()
	_end_trace = TraceSupport.new("aa_end", get_tree())
	_trace = _end_trace
	await _closing_prompt()
	_failures += _end_trace.finish()
	print("trace_aa_check: aa_end %s (%s)" % [_end_trace.last_status, _end_trace.summary()])
	print("trace_aa_check: %s (%s; %d failures)" % ["OK" if _failures == 0 else "FAILED", _trace.summary(), _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _state(battle: Node) -> Dictionary:
	var rt := battle.get("mission") as AAMissionRuntime
	if rt == null:
		return {}
	var s := {"waypoint": rt.waypoint_index, "kills": rt.kills, "over": 1 if rt.is_over() else 0}
	if rt.vm != null:
		s["vm_state"] = rt.vm.state
		s["vm_text"] = rt.vm.state_text().length()
	return s


func _start(index: int, folder := "") -> Battle:
	Session.start_stage_campaign(PACK)
	if folder != "":
		var c: Object = Session.campaign
		for i in c.missions.size():
			if str(c.missions[i].get("folder", "")) == folder:
				index = i
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
	return b


func _frames(n: int) -> void:
	for _f in n:
		await get_tree().physics_frame


func _stop(b: Battle) -> void:
	await _frames(AFTER_END_FRAMES)
	_trace.add("done", "over" if (b.mission as AAMissionRuntime).is_over() else "running", 0)
	b.queue_free()
	await _frames(3)


func _training() -> void:
	var b := await _start(0)
	await _frames(int(IDLE_SECONDS * FPS))
	await _stop(b)


func _generators() -> void:
	var idx := 0
	var c: Object
	Session.start_stage_campaign(PACK)
	c = Session.campaign
	for i in c.missions.size():
		var m := MapBuilder.load_map("%s:%s" % [PACK, c.missions[i].map])
		if AAMissionRuntime.make_goal(m) == AAMissionRuntime.GOAL_GENERATORS:
			idx = i
			break
	var b := await _start(idx)
	var base := TribesBase.of(b)
	if base != null:
		for o in base.objects:
			if o.kind == TribesBaseObject.KIND_GENERATOR:
				base.object_destroyed.emit(o, null)
	await _stop(b)


func _scripted() -> void:
	if AAScript.make_logic("MISSION06").is_empty():
		return
	var b := await _start(0, "MISSION06")
	var rt := b.mission as AAMissionRuntime
	if rt == null or rt.vm == null:
		await _stop(b)
		return
	b.player.global_position = AAScript.make_tag_positions(rt.map, "VSTATION1")[0] + Vector3(0, 2, 0)
	_trace.add("step", "vehicle pad", 1)
	await _frames(STEP_FRAMES)
	b.player.global_position = AAScript.make_tag_positions(rt.map, "WAYPT1")[0] + Vector3(0, 2, 0)
	_trace.add("step", "waypoint 1", 2)
	await _frames(STEP_FRAMES)
	rt.vm.state_time = 190.0
	_trace.add("step", "skip preparation", 3)
	await _frames(STEP_FRAMES)
	await _stop(b)


func _arena() -> void:
	if AAScript.make_logic("MISSION01").is_empty():
		return
	var b := await _start(0, "MISSION01")
	var rt := b.mission as AAMissionRuntime
	if rt == null or rt.enemies.is_empty():
		await _stop(b)
		return
	await _frames(30)
	var foe: Infantry = (rt.enemies[0] as InfantryBot).soldier
	for _k in int(rt.logic.score_limit):
		rt.on_unit_destroyed(foe)
	_trace.add("step", "score limit", int(rt.logic.score_limit))
	await _frames(30)
	await _stop(b)


func _closing_prompt() -> void:
	var b := await _start(0)
	var rt := b.mission as AAMissionRuntime
	if rt == null or rt.vm == null:
		await _stop(b)
		return
	await _frames(2 * FPS)
	rt.vm_end(true, int(rt.vm.program.get("death", 0)) if int(rt.vm.program.get("death", 0)) > 0 else 1)
	_trace.add("step", "closing prompt", 1)
	await _frames(20 * FPS)
	await _stop(b)

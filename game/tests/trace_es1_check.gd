extends Node
## Golden trace of Earthsiege 1 missions (MECHANICS_UNIFICATION G1), driven by a fixed physics step:
##   Godot --headless --audio-driver Dummy --path game res://tests/trace_es1_check.tscn
## B0_C0_4A (pilot rescue, every Cybrid destroyed round by round: win), B0_C0_3A (datalink: the player holds
## 20 m from the link, stages and win), B0_C0_3B (base defence: the base destroyed, loss).
## Records chat / radio, objectives, spawns, region fires and the end; writes tests/golden/es1.json when missing.

const TraceSupport = preload("res://tests/trace_support.gd")
const ROSTER := {1: {"name": "Tester", "vehicle": "es1:RAPTOR", "team": 0, "loadout": []}}
const SETTLE_FRAMES := 20
const END_WAIT_FRAMES := 60
const MAX_KILL_ROUNDS := 20
const DATALINK_STANDOFF := 20.0
const DATALINK_FRAMES := 20 * 60
const AFTER_END_FRAMES := 10

var _trace
var _failures := 0
var _player: Node


func _ready() -> void:
	Engine.time_scale = 1.0
	await get_tree().process_frame
	if MissionCompiler.load_mission("B0_C0_4A", PackedInt32Array(), 1, -1, {"resolve_texts": true}).is_empty():
		print("trace_es1_check: SKIPPED (Earthsiege 1 game data is not installed)")
		get_tree().quit(0)
		return
	_trace = TraceSupport.new("es1", get_tree())
	await _rescue_won()
	await _datalink()
	await _base_lost()
	_failures += _trace.finish()
	print("trace_es1_check: %s (%s; %d failures)" % ["OK" if _failures == 0 else "FAILED", _trace.summary(), _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _start(mission_name: String) -> Battle:
	var mdef := MissionCompiler.load_mission(mission_name, PackedInt32Array(), 1, -1, {"resolve_texts": true})
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "respawn": false, "mission": mdef, "roster": ROSTER.duplicate(true)}
	battle.set_meta("result", {})
	battle.match_finished.connect(func(r): battle.get_meta("result").merge(r))
	get_tree().root.add_child(battle)
	_player = battle.player
	_trace.start()
	_trace.add("mission", mission_name, 0)
	_trace.watch_battle(battle, func() -> Dictionary: return _state(battle))
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
		_protect_player(battle)
	return battle


## Region fires, dormant waves, nav progress and the mission variables, polled each physics frame.
func _state(battle: Battle) -> Dictionary:
	var rt: MissionRuntime = battle.mission
	if rt == null:
		return {}
	var s := {"dormant": rt.dormant_groups.size(), "nav": rt.nav_index}
	for i in rt.regions.size():
		s["region%d" % i] = 1 if bool(rt.regions[i].get("fired", false)) else 0
	for i in rt.mission_vars.size():
		if rt.mission_vars[i] != 0:
			s["var%d" % i] = rt.mission_vars[i] if i == 0 else 1   # kill counters flap by a unit: set / clear only
	return s


func _finish(battle: Battle) -> void:
	for i in AFTER_END_FRAMES:
		await get_tree().physics_frame
	_trace.add("done", "", 0)
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _protect_player(battle: Battle) -> void:
	var p: Herc = battle.player
	if p and is_instance_valid(p):
		p.shield_front = p.shield_max
		p.shield_rear = p.shield_max
		for c in p.components:
			c.hp = c.max


func _destroy(h: Herc) -> void:
	for i in END_WAIT_FRAMES * 4:
		if h == null or not h.alive:
			return
		h.apply_hit(1e6, 1e6, _player, h.global_position)
		await get_tree().physics_frame


func _kill_hostiles() -> void:
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v.team != 0 and v.alive:
			await _destroy(v)


func _hostiles_left(battle: Battle) -> int:
	var n := 0
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v.team != 0 and v.alive:
			n += 1
	for gi in battle.mission.dormant_groups:
		if int(battle.mission.m.groups[gi].get("team", 1)) != 0:
			n += 1
	return n


func _wait_end(battle: Battle) -> void:
	for i in END_WAIT_FRAMES:
		_protect_player(battle)
		await get_tree().physics_frame
		if not battle.get_meta("result").is_empty():
			break


func _rescue_won() -> void:
	var battle := await _start("B0_C0_4A")
	for round in MAX_KILL_ROUNDS:
		if _hostiles_left(battle) == 0:
			break
		_protect_player(battle)
		await _kill_hostiles()
		await get_tree().physics_frame
	await _wait_end(battle)
	await _finish(battle)


func _datalink() -> void:
	var battle := await _start("B0_C0_3A")
	var rt: MissionRuntime = battle.mission
	var link: Node3D = rt.win_rules._datalink_node()
	var p: Herc = battle.player
	var frames := 0
	while link != null and not rt.win_rules.datalink_flag and frames < DATALINK_FRAMES:
		frames += 1
		_hold_at_link(battle, link)
		await get_tree().physics_frame
	for i in END_WAIT_FRAMES * 2:
		_hold_at_link(battle, link)
		await get_tree().physics_frame
	await _finish(battle)


func _hold_at_link(battle: Battle, link: Node3D) -> void:
	var p: Herc = battle.player
	_protect_player(battle)
	if link is Structure and (link as Structure).alive:
		(link as Structure).hp = (link as Structure).max_hp
		(link as Structure).integrity = 1.0
	p.global_position = link.global_position + Vector3(0, 2.0, DATALINK_STANDOFF)
	p.velocity = Vector3.ZERO
	p.throttle = 0.0
	p.look_at(Vector3(link.global_position.x, p.global_position.y, link.global_position.z))
	p.torso_yaw = 0.0


func _base_lost() -> void:
	var battle := await _start("B0_C0_3B")
	for s in battle.mission.structures:
		if s.team == 0 and s.alive:
			s.destroy(null)
	await _wait_end(battle)
	await _finish(battle)

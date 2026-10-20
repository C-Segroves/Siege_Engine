extends Node
## Golden trace of Earthsiege 2 missions (MECHANICS_UNIFICATION G2), driven by a fixed physics step:
##   Godot --headless --audio-driver Dummy --path game res://tests/trace_es2_check.tscn
## C1_01 and C1_02 are played with the es2_mission_check "cheat" driver (nav points walked, hostiles destroyed,
## regions fired, scan targets approached) in rounds of 10 physics frames until the mission ends.
## Records chat / radio, objectives, spawns, region / timer state, statuses and the end; writes
## tests/golden/es2.json when missing.

const TraceSupport = preload("res://tests/trace_support.gd")
const MISSIONS := ["C1_01", "C1_02"]
const SETTLE_FRAMES := 30
const ROUND_FRAMES := 10
const MAX_ROUNDS := 400
const AFTER_END_FRAMES := 20

var _trace
var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	if MissionCompiler.load_mission("es2:C1_01", PackedInt32Array(), 1, -1, {"resolve_texts": true}).is_empty():
		print("trace_es2_check: SKIPPED (Earthsiege 2 game data is not installed)")
		get_tree().quit(0)
		return
	_trace = TraceSupport.new("es2", get_tree())
	for n in MISSIONS:
		await _run_mission(n)
	_failures += _trace.finish()
	print("trace_es2_check: %s (%s; %d failures)" % ["OK" if _failures == 0 else "FAILED", _trace.summary(), _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _state(battle: Node) -> Dictionary:
	var rt = battle.mission
	if rt == null:
		return {}
	var s := {"dormant": rt.dormant_groups.size(), "nav": rt.nav_index}   # status() is left out: it flips for a single frame, so whether a poll sees it depends on the step order
	for i in rt.regions.size():
		s["region%d" % i] = 1 if bool(rt.regions[i].get("fired", false)) else 0
	for i in rt.get_timer_count():
		s["timer%d_armed" % i] = 1 if rt.is_timer_armed(i) else 0
	for i in rt.mission_vars.size():
		if rt.mission_vars[i] != 0:
			s["var%d" % i] = rt.mission_vars[i] if i == 0 else 1   # kill counters flap by a unit: set / clear only
	return s


func _run_mission(name: String) -> void:
	var mdef := MissionCompiler.load_mission("es2:" + name, PackedInt32Array(), 1, -1, {"resolve_texts": true})
	var battle: Node = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "respawn": false, "mission": mdef,
		"roster": {1: {"name": "Tester", "vehicle": "es2:OUTLAW", "team": 0, "loadout": []}}}
	var result := {}
	battle.match_finished.connect(func(r): result.merge(r))
	get_tree().root.add_child(battle)
	_trace.start()
	_trace.add("mission", name, 0)
	_trace.watch_battle(battle, func() -> Dictionary: return _state(battle))
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	var rt2 := battle.mission as MissionRuntimeES2
	var protect := []
	for ob in rt2.objectives:
		if not ob.def.get("required", true) or int(ob.def.get("type", 0)) in [3, 4]:
			protect += rt2.target_nodes(ob.def.get("target"))
	var o00 = rt2.orders.current_order(0)
	if o00 is Dictionary and int(rt2.m.header.raw[3]) in [3, 7]:
		protect += rt2.target_nodes(o00.get("target"))
	var rounds := 0
	while result.is_empty() and rounds < MAX_ROUNDS:
		rounds += 1
		_drive(battle, rt2, protect)
		for i in ROUND_FRAMES:
			await get_tree().physics_frame
	for i in AFTER_END_FRAMES:
		await get_tree().physics_frame
	_trace.add("done", "ended" if not result.is_empty() else "timeout", 0)
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	Sfx.stop_music(0.0)


func _drive(battle: Node, rt2: MissionRuntimeES2, protect: Array) -> void:
	var player: Node3D = battle.player
	if not (player and is_instance_valid(player) and player.alive):
		return
	player.shield_front = player.shield_max
	player.shield_rear = player.shield_max
	for c in player.components:
		c.hp = c.max
	for ri in rt2.regions.size():
		rt2.fire_region(ri)
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v.team != 0 and v.alive and not protect.has(v):
			v.apply_hit(1e6, 1e6, player, v.global_position)
	for st in rt2.structures:
		if st.team != 0 and st.alive and not protect.has(st):
			st.destroy(player)
	for ob in rt2.objectives:
		var o: Dictionary = ob.def
		if int(o.get("type", 0)) == 0 and o.get("path_points") is Array and not o.path_points.is_empty():
			var gi: int = rt2.group_of(o.get("target"))
			if gi > 0:
				for u in rt2.group_units.get(gi, []):
					if is_instance_valid(u) and u.alive:
						u.global_position = rt2.on_ground(MissionRuntime.to_godot(o.path_points[-1])) + Vector3.UP
	var scan_t: Array = []
	var o0 = rt2.orders.current_order(0)
	if o0 is Dictionary and o0.get("target") is Dictionary:
		scan_t = rt2.target_nodes(o0.target)
	for ob in rt2.objectives:
		if int(ob.def.get("type", 0)) in [3, 4] and scan_t.is_empty():
			scan_t = rt2.target_nodes(ob.def.get("target"))
	if rt2.nav_index < rt2.nav_points.size():
		player.global_position = rt2.nav_points[rt2.nav_index] + Vector3.UP * 2.0
	elif not rt2.scan_flag and not scan_t.is_empty() and is_instance_valid(scan_t[0]):
		var tp: Vector3 = scan_t[0].global_position
		player.global_position = rt2.on_ground(tp + Vector3(0, 0, 30)) + Vector3.UP
		player.look_at(Vector3(tp.x, player.global_position.y, tp.z))

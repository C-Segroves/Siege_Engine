extends Node
## The Tribes and Tribes 2 training missions in the mission runtime (docs/formats/tribes.md / tribes2.md
## section 8):
##   godot --path game res://tests/tribes_training_check.tscn [-- <mission ids ...>] [--seconds=60] [--shots]
## Each installed training mission loads into a Battle (the player on foot), runs its script for --seconds of
## mission time and must post radio lines and an objective without script errors. Then two scripted cheat runs
## finish a mission: Tribes 1_Welcome (the player is put on the tower switch) and Tribes 2 Training1 (the intro
## skipped through the script's own skipIntroCinematic, the player put beside the MPB). --shots (with a
## window) saves renders/tribes_training_<id>.png a few seconds into each mission.

const BATTLE_SCENE := "res://games/es1/battle.tscn"
const DEFAULT_SECONDS := 60.0
const TIME_SCALE := 4.0
const SHOT_AT_SECONDS := 12.0
const SHOT_DIR := "res://../renders/"
const CHEAT_TIMEOUT := 90.0
const T1_CHEAT := "tribes:1_Welcome"
const T1_SWITCH := "Objective"
const T2_CHEAT := "tribes2:Training1"
const T2_GOAL := "MPB"
## Metres from the MPB (Training1's objectiveDistanceChecks completes the mission within 70 m).
const T2_GOAL_OFFSET := Vector3(20, 2, 20)

var _fails := 0
var _seconds := DEFAULT_SECONDS
var _shots := false
var _only: Array[String] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seconds="):
			_seconds = float(a.substr(10))
		elif a == "--shots":
			_shots = true
		elif not a.begins_with("--"):
			_only.append(a.to_lower())
	Engine.time_scale = TIME_SCALE
	await get_tree().process_frame
	await _run_all()
	Engine.time_scale = 1.0
	print("TRIBES TRAINING: %d failed" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		_fails += 1


func _run_all() -> void:
	var names := []
	for p in TribesMissionRuntime.PACKS:
		for e in TribesMissionRuntime.list_missions(p):
			names.append("%s:%s" % [p, e.id])
	_check(not names.is_empty(), "training missions installed (%d)" % names.size())
	for n in names:
		if _only.is_empty() or String(n).to_lower() in _only or String(n).get_slice(":", 1).to_lower() in _only:
			await _run_mission(n)
	if _only.is_empty() or T1_CHEAT.to_lower() in _only:
		await _cheat_tribes()
	if _only.is_empty() or T2_CHEAT.to_lower() in _only:
		await _cheat_tribes2()


# ------------------------------------------------------------------ battles

func _start(mission_name: String) -> Battle:
	var battle: Battle = load(BATTLE_SCENE).instantiate()
	battle.config = {"mode": "mission", "mission_name": mission_name, "respawn": false,
		"roster": {1: {"name": "Tester", "vehicle": "", "team": 0, "loadout": []}}}
	get_tree().root.add_child(battle)
	for i in 3:
		await get_tree().physics_frame
	return battle


func _stop(battle: Battle) -> void:
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _runtime(battle: Battle) -> TribesMissionRuntime:
	return battle.mission as TribesMissionRuntime


## Runs the battle until `until` (a Callable(rt) -> bool) holds or `seconds` of mission time passed.
func _run_for(battle: Battle, seconds: float, until := Callable(), shot_id := "") -> void:
	var rt := _runtime(battle)
	var shot_done := not _shots
	while rt != null and rt.sim_time < seconds and not rt.is_mission_over():
		await get_tree().physics_frame
		if not shot_done and rt.sim_time >= SHOT_AT_SECONDS:
			shot_done = true
			await _shoot(shot_id)
		if until.is_valid() and until.call(rt):
			return


func _shoot(id: String) -> void:
	if DisplayServer.get_name() == "headless" or id == "":
		return
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(SHOT_DIR + "tribes_training_%s.png" % id.replace(":", "_"))
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)


func _run_mission(mission_name: String) -> void:
	var battle := await _start(mission_name)
	var rt := _runtime(battle)
	_check(rt != null, "%s: Tribes mission runtime" % mission_name)
	if rt == null:
		await _stop(battle)
		return
	_check(battle.player is Infantry, "%s: the player starts on foot (%s)" % [mission_name,
		battle.player.vehicle_id if battle.player else "none"])
	await _run_for(battle, _seconds, Callable(), mission_name)
	rt.flush_errors()
	if battle.player:
		print("  player at ", battle.player.global_position, " ground ", MapBuilder.ground_height(battle, battle.player.global_position), " alive ", battle.player.alive)
	print("  %s: %.0f s, %d radio lines, objectives %s, %d bots, %d warnings" % [mission_name, rt.sim_time,
		rt.output.radio_lines.size(), rt.output.objectives.filter(func(o: String) -> bool: return o != ""), _bots(battle), rt.warnings.size()])
	for e in rt.error_log:
		print("    script error: ", e)
	for w in rt.warnings:
		print("    warning: ", w)
	_check(rt.error_log.is_empty(), "%s: no script errors (%d)" % [mission_name, rt.error_log.size()])
	_check(not rt.output.radio_lines.is_empty(), "%s: training lines on the radio" % mission_name)
	_check(rt.output.objectives.any(func(o: String) -> bool: return o != ""), "%s: an objective posted" % mission_name)
	var items := _item_records(rt).filter(func(r: Dictionary) -> bool:
		return not rt.item_models.grants.record(String(r.get("datablock", ""))).is_empty())   # flags are the mode's
	var drawn := items.filter(func(r: Dictionary) -> bool: return r.get("model") is Node3D)
	if not items.is_empty():
		_check(not drawn.is_empty(), "%s: its items are drawn (%d of %d have a model)" % [mission_name, drawn.size(), items.size()])
	await _stop(battle)


## The mission's Item records (PLAYTEST C4: Training1's sniper rifle must be seen to be picked up); those with a
## catalogued model must be drawn.
static func _item_records(rt: TribesMissionRuntime) -> Array:
	return rt.sim.objects.values().filter(func(r: Dictionary) -> bool:
		return String(r.class).to_lower() == "item" and not r.get("is_datablock", false))


func _bots(battle: Battle) -> int:
	return battle.vehicles.values().filter(func(h) -> bool: return is_instance_valid(h) and h is Infantry and h.has_meta("bot_id")).size()


# ------------------------------------------------------------------ cheat runs

## Tribes 1_Welcome: standing on the tower switch completes the introduction (TowerSwitch::onCollision ->
## Training::missionComplete -> EndGame).
func _cheat_tribes() -> void:
	if TribesMissionRuntime.load_mission(T1_CHEAT).is_empty():
		return
	var battle := await _start(T1_CHEAT)
	var rt := _runtime(battle)
	var won := [false]
	rt.mission_over.connect(func(ok: bool, _c: int, _t: String) -> void: won[0] = ok)
	await _run_for(battle, 3.0)
	var switch := rt.sim.resolve(T1_SWITCH)
	_check(switch > 0, "1_Welcome: the tower switch is in the mission tree")
	battle.player.global_position = rt.sim.position_of(switch) + Vector3(0.5, 0.5, 0.0)
	battle.player.velocity = Vector3.ZERO
	await _run_for(battle, rt.sim_time + CHEAT_TIMEOUT)
	_check(rt.is_mission_over() and won[0], "1_Welcome completed by touching the switch (%.0f s)" % rt.sim_time)
	_check(rt.error_log.is_empty(), "1_Welcome cheat run: no script errors %s" % [rt.error_log])
	await _stop(battle)


## Tribes 2 Training1: the script's skipIntroCinematic() ends the bomber intro, the player is put beside the MPB:
## objectiveDistanceChecks calls missionComplete, its Victory box finishes the mission.
func _cheat_tribes2() -> void:
	if TribesMissionRuntime.load_mission(T2_CHEAT).is_empty():
		return
	var battle := await _start(T2_CHEAT)
	var rt := _runtime(battle)
	var won := [false]
	rt.mission_over.connect(func(ok: bool, _c: int, _t: String) -> void: won[0] = ok)
	await _run_for(battle, 5.0)
	rt.vm.call_fn("skipintrocinematic", [])
	await _run_for(battle, rt.sim_time + 2.0)
	var mpb := rt.sim.resolve(T2_GOAL)
	_check(mpb > 0, "Training1: the MPB is in the mission tree")
	var soldier := rt.actors.soldier_of(rt.actors.human_client)
	if soldier:
		soldier.global_position = rt.sim.position_of(mpb) + T2_GOAL_OFFSET
		soldier.velocity = Vector3.ZERO
	await _run_for(battle, rt.sim_time + CHEAT_TIMEOUT)
	_check(rt.is_mission_over() and won[0], "Training1 completed at the MPB (%.0f s)" % rt.sim_time)
	_check(rt.error_log.is_empty(), "Training1 cheat run: no script errors %s" % [rt.error_log])
	await _stop(battle)

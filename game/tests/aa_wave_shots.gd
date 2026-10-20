extends Node
## Windowed renders of the Aerial Assault soldiers in a mission (the allies and a BioDerm wave of Gen Defender) for checking by eye.
##   AA_TEST_ROOT=<data folder with tribes_aa/ and tribes2/> AA_SHOT_DIR=<folder> [AA_MISSION_FOLDER=MISSION11] godot --audio-driver Dummy --path game res://tests/aa_wave_shots.tscn
const WATCHDOG_SECONDS := 180.0
const SETTLE_FRAMES := 40

var _battle: Battle
var _xf := Transform3D.IDENTITY
var _override := false         # the camera is left alone (the terrain streams around it) until the first look


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var root := OS.get_environment("AA_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	var dir := OS.get_environment("AA_SHOT_DIR")
	var folder := OS.get_environment("AA_MISSION_FOLDER") if OS.get_environment("AA_MISSION_FOLDER") != "" else "MISSION11"
	Session.start_stage_campaign("tribes_aa")
	var c: Object = Session.campaign
	for i in c.missions.size():
		if str(c.missions[i].get("folder", "")) == folder:
			c.index = i
	var herc := MatchFlow.make_issued_soldier()
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = MatchFlow.make_mission_config(str(herc.vehicle), [], {})
	get_tree().root.add_child(b)
	_battle = b
	process_priority = 1000
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	var rt := b.mission as AAMissionRuntime
	if b.overlay:
		b.overlay.visible = false
	print("player alive %s at %s (spawn %s)" % [str(b.player.alive), str(b.player.global_position), str(rt.player_spawn(0).origin)])
	if OS.get_environment("AA_NO_SPAWN") == "":
		rt._spawn_wave(0)
		rt._spawn_wave(1)
	for _f in 90:
		await get_tree().process_frame
	print("player alive %s at %s" % [str(b.player.alive), str(b.player.global_position)])
	print("allies %d enemies %d, voice %s" % [rt.count_alive(rt.allies), rt.count_alive(rt.enemies), str(rt.vm.state_name() if rt.vm else "no machine")])
	var k := 0
	for b2 in rt.enemies:
		if is_instance_valid(b2) and is_instance_valid(b2.soldier) and k < 3:
			await _look_at(b2.soldier, dir.path_join("enemy_%d.png" % k))
			k += 1
	k = 0
	for b2 in rt.allies:
		if is_instance_valid(b2) and is_instance_valid(b2.soldier) and k < 1:
			await _look_at(b2.soldier, dir.path_join("ally_%d.png" % k))
			k += 1
	get_tree().quit(0)


func _look_at(s: Node3D, path: String) -> void:
	var target := s.global_position + Vector3(0, 1.2, 0)
	var xf := Transform3D(Basis.IDENTITY, target + Vector3(3.5, 0.8, 3.5))
	xf = xf.looking_at(target, Vector3.UP)
	_xf = xf
	_override = true
	for _f in 8:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _process(_d: float) -> void:
	if _override and _battle != null and _battle.cameras != null:
		var c: Camera3D = _battle.cameras.chase_cam
		c.current = true
		c.global_transform = _xf

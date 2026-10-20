extends Node
## Windowed renders of a Tribes: Vengeance mission with its placed soldiers streamed in around the player: the player's start
## (eye view) and an over-the-shoulder view of the soldiers next to it, for checking the bodies and animations by eye.
##   TV_TEST_ROOT=<scratch data folder> TV_SHOT_DIR=<folder> [TV_MISSION=<index>] godot --audio-driver Dummy --path game res://tests/tv_npc_shots.tscn
const WATCHDOG_SECONDS := 240.0
const SETTLE_FRAMES := 60

var _battle: Battle
var _xf := Transform3D.IDENTITY


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var root := OS.get_environment("TV_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	var dir := OS.get_environment("TV_SHOT_DIR")
	DirAccess.make_dir_recursive_absolute(dir)
	var index := int(OS.get_environment("TV_MISSION")) if OS.get_environment("TV_MISSION") != "" else 1
	Session.start_stage_campaign("tribes_v")
	Session.campaign.index = index
	var herc := MatchFlow.make_issued_soldier()
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = MatchFlow.make_mission_config(str(herc.vehicle), [], {})
	get_tree().root.add_child(b)
	_battle = b
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	var rt := b.mission as TVMissionRuntime
	print("script run: ", rt.script_run != null, " npcs ", rt._npcs.size(), " spawned ", rt._npcs.filter(func(e): return e.spawned).size())
	print("objectives: ", rt.objectives.map(func(o): return o.text))
	if b.overlay:
		b.overlay.visible = false
	var spawn: Vector3 = b.player.global_position
	# the nearest spawned soldier
	var best: Node3D = null
	for e in rt._npcs:
		var brain = e.brain
		if brain != null and is_instance_valid(brain) and is_instance_valid(brain.soldier):
			if best == null or brain.soldier.global_position.distance_to(spawn) < best.global_position.distance_to(spawn):
				best = brain.soldier
	process_priority = 1000
	var cam := Node3D.new()
	add_child(cam)
	cam.global_position = spawn + Vector3(0, 2.2, 0)
	cam.look_at(spawn + Vector3(0, 1.8, -10), Vector3.UP)
	_xf = cam.global_transform
	await _shot(dir.path_join("start.png"))
	if best != null:
		print("nearest soldier ", best.name, " body ", (best as Infantry).make_body_shape_id(), " at ", best.global_position.distance_to(spawn), " m")
		var dirn := (best.global_position - spawn).normalized()
		cam.global_position = best.global_position - dirn * 5.0 + Vector3(0, 2.0, 0)
		cam.look_at(best.global_position + Vector3(0, 1.2, 0), Vector3.UP)
		_xf = cam.global_transform
		await _shot(dir.path_join("npc.png"))
		cam.global_position = best.global_position + Vector3(2.5, 1.6, 2.5)
		cam.look_at(best.global_position + Vector3(0, 1.2, 0), Vector3.UP)
		_xf = cam.global_transform
		await _shot(dir.path_join("npc2.png"))
	get_tree().quit(0)


func _process(_d: float) -> void:
	if _battle != null and _battle.cameras != null:
		var c: Camera3D = _battle.cameras.chase_cam
		c.far = 6000.0
		c.current = true
		c.global_transform = _xf


func _shot(path: String) -> void:
	for _f in 8:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)

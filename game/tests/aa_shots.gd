extends Node
## Windowed renders of one Aerial Assault mission (overview and ground level) for checking by eye.
##   AA_TEST_ROOT=<scratch data folder> AA_SHOT_DIR=<folder> [AA_MISSION=<index>] godot --audio-driver Dummy --path game res://tests/aa_shots.tscn
const WATCHDOG_SECONDS := 180.0
const SETTLE_FRAMES := 40


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
	var index := int(OS.get_environment("AA_MISSION")) if OS.get_environment("AA_MISSION") != "" else 5
	Session.start_stage_campaign("tribes_aa")
	Session.campaign.index = index
	var herc := MatchFlow.make_issued_soldier()
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = MatchFlow.make_mission_config(str(herc.vehicle), [], {})
	get_tree().root.add_child(b)
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	var spawn: Vector3 = b.mission.player_spawn(0).origin
	var bounds: Dictionary = b.mission.map.get("bounds", {})
	var centre := Vector3((float(bounds.min[0]) + float(bounds.max[0])) * 0.5, spawn.y, (float(bounds.min[1]) + float(bounds.max[1])) * 0.5)
	_battle = b
	process_priority = 1000
	var cam := Node3D.new()
	add_child(cam)
	if b.overlay:
		b.overlay.visible = false
	cam.global_position = centre + Vector3(0, 900, 700)
	cam.look_at(centre, Vector3.UP)
	_xf = cam.global_transform
	var fogged: Array = []
	for n in b.find_children("*", "WorldEnvironment", true, false):
		var e: Environment = (n as WorldEnvironment).environment
		if e != null:
			fogged.append([e, e.fog_enabled])
			e.fog_enabled = false
	await _shot(dir.path_join("overview.png"))
	for f in fogged:
		f[0].fog_enabled = f[1]
	cam.global_position = spawn + Vector3(0, 3, 0)
	cam.look_at(centre + Vector3(0, 3, 0), Vector3.UP)
	_xf = cam.global_transform
	await _shot(dir.path_join("ground.png"))
	cam.global_position = centre + Vector3(0, 220, 260)
	cam.look_at(centre, Vector3.UP)
	_xf = cam.global_transform
	await _shot(dir.path_join("mid.png"))
	cam.global_position = spawn + Vector3(0, 3, 0)
	cam.look_at(spawn + Vector3(300, 220, 0), Vector3.UP)
	_xf = cam.global_transform
	await _shot(dir.path_join("sky.png"))
	get_tree().quit(0)


var _cam: Camera3D
var _battle: Battle
var _xf := Transform3D.IDENTITY


func _process(_d: float) -> void:
	if _battle != null and _battle.cameras != null:
		var c: Camera3D = _battle.cameras.chase_cam
		c.far = 6000.0
		c.current = true
		c.global_transform = _xf


func _shot(path: String) -> void:
	for _f in 6:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)

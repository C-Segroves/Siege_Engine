extends Node
## Windowed renders of an Aerial Assault arena map (overview, ground level, a structure close-up) for checking by eye.
##   AA_MAP=Katabatic AA_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/aa_map_shots.tscn
## SIEGE_RENDER_UNIFIED=0/1 picks the render path.
const WATCHDOG_SECONDS := 180.0
const SETTLE_FRAMES := 40

var _battle: Battle
var _xf := Transform3D.IDENTITY


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("AA_SHOT_DIR")
	var map_name := OS.get_environment("AA_MAP") if OS.get_environment("AA_MAP") != "" else "Katabatic"
	var cfg := MatchFlow.make_skirmish_config("es1:RAPTOR", [], {"mode": "vs", "map": "tribes_aa:" + map_name, "respawn": false, "ai": []})
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = cfg
	_battle = b
	get_tree().root.add_child(b)
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	process_priority = 1000
	var cam := Node3D.new()
	add_child(cam)
	if b.overlay:
		b.overlay.visible = false
	var at: Vector3 = b.player.global_position
	var structs := get_tree().get_nodes_in_group("structures")
	print("structures: ", structs.size())
	_aim(cam, at + Vector3(0, 500, 500), at)
	await _shot(dir.path_join("%s_overview.png" % map_name))
	_aim(cam, at + Vector3(0, 3, 0), at + Vector3(200, 3, 0))
	await _shot(dir.path_join("%s_ground.png" % map_name))
	if not structs.is_empty():
		var s: Node3D = structs[structs.size() / 2]
		var sp := s.global_position
		_aim(cam, sp + Vector3(40, 25, 40), sp + Vector3(0, 8, 0))
		await _shot(dir.path_join("%s_structure.png" % map_name))
		var s2: Node3D = structs[0]
		_aim(cam, s2.global_position + Vector3(30, 15, 30), s2.global_position + Vector3(0, 5, 0))
		await _shot(dir.path_join("%s_structure2.png" % map_name))
	for s in structs:                      # a turret close up (the disc's own turret shapes)
		if s is TribesTurret:
			var tp: Vector3 = s.global_position
			_aim(cam, tp + Vector3(7, 4, 7), tp + Vector3(0, 1.5, 0))
			await _shot(dir.path_join("%s_turret.png" % map_name))
			break
	get_tree().quit(0)


func _aim(cam: Node3D, from: Vector3, to: Vector3) -> void:
	cam.global_position = from
	cam.look_at(to, Vector3.UP)
	_xf = cam.global_transform


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

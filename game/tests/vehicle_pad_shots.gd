extends Node
## Windowed renders of the Tribes vehicle pad for checking by eye (needs a window and the Tribes packs):
##   PAD_SHOT_DIR=<folder> PAD_SHOT_MAP=tribes2:Katabatic godot --audio-driver Dummy --path game res://tests/vehicle_pad_shots.tscn
## <map>_pad_high.png (from above and the side), <map>_pad_low.png (the soldier's eye view).
const SETTLE_FRAMES := 30
const KINDS := ["vehicle_pad"]

var _battle: Battle
var _cam: Camera3D
var _xf := Transform3D.IDENTITY


func _ready() -> void:
	get_tree().create_timer(240.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	RenderingServer.frame_pre_draw.connect(_hold_camera)
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("PAD_SHOT_DIR")
	var map_id := OS.get_environment("PAD_SHOT_MAP")
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": map_id, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": []}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	_battle = battle
	battle.overlay.visible = false
	await _frames(SETTLE_FRAMES)
	battle.cameras.apply_view(true)
	var s := battle.player as Infantry
	s.spawn_protection = 100000.0
	s.apply_spawn_protection()
	var pad: TribesBaseObject = null
	for k in KINDS:
		var found := TribesBase.of(battle).objects_of(k)
		if not found.is_empty():
			pad = found[0]
	if pad == null:
		print("no vehicle pad on ", map_id)
		get_tree().quit(1)
		return
	s.global_position = pad.global_position + Vector3(0, 40, 0)
	s.velocity = Vector3.ZERO
	_cam = Camera3D.new()
	battle.add_child(_cam)
	for mi in pad.shape.find_children("*", "MeshInstance3D", true, false):
		print("mesh ", mi.name, " vis=", mi.is_visible_in_tree(), " ", (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb().get_center(), " ", (mi as MeshInstance3D).get_aabb().size)
	var tag := map_id.replace(":", "_")
	var c := pad.global_position
	await _frames(20)
	_aim_camera(c + Vector3.UP * 1.0, c + Vector3(20, 18, 20))
	await _shot(dir.path_join("%s_pad_high.png" % tag))
	_aim_camera(c + Vector3.UP * 1.0, c + Vector3(-14, 3, 22))
	await _shot(dir.path_join("%s_pad_low.png" % tag))
	_aim_camera(c, c + Vector3(0, 30, 0.1))
	await _shot(dir.path_join("%s_pad_top.png" % tag))
	print("pad ", pad.shape_id, " at ", c)
	get_tree().quit()


func _aim_camera(look_at_point: Vector3, from: Vector3) -> void:
	var cam := _cam
	cam.global_position = from
	cam.look_at(look_at_point, Vector3.UP)
	_xf = cam.global_transform


func _hold_camera() -> void:
	if _battle != null and _xf != Transform3D.IDENTITY:
		_battle.cameras.apply_view(true)
		var c: Camera3D = _battle.cameras.chase_cam
		c.far = 3000.0
		c.current = true
		c.global_transform = _xf


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(path: String) -> void:
	for _f in 6:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)

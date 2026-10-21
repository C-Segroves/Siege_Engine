extends Node
## Windowed render of an inventory station call-in on Varuna's Fall (needs a window and the Tribes 2 pack), for checking by eye:
##   CALLIN_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/callin_station_shots.tscn
## station_placed.png: the station standing on the spot the order was made for.
const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const MAP := "tribes2:varuna"
const SEED := 4242
const SETTLE_FRAMES := 20
const RAID_POINTS := 2000
const CAMERA_BACK_M := 9.0
const CAMERA_UP_M := 4.0
const WAIT_S := 60.0

var _pilot := "QA Station Shots %d" % OS.get_process_id()
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	get_tree().create_timer(300.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _run() -> void:
	_guard.back_up()
	Net.player_name = _pilot
	await get_tree().process_frame
	var profile := ExtractionProfile.load_for(_pilot)
	profile.save()
	var operator := OperatorProfile.load_for(_pilot)
	operator.apply_raid_points(RAID_POINTS)
	operator.save()
	var config := MatchFlow.make_extraction_solo_config(profile, {"map": MAP, "respawn": true}, 0, 0)
	config["extraction_seed"] = SEED
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	var me := battle.player as Infantry
	var t0 := Time.get_ticks_msec()
	while me.stowed and Time.get_ticks_msec() - t0 < WAIT_S * 1000.0:
		await _frames(1)
	await _frames(SETTLE_FRAMES)
	var callins := battle.extraction.callins
	callins.points.balances[1] = RAID_POINTS
	callins.points.mine = RAID_POINTS
	var request: CallinRequest = callins.checks.make_feet_request(1, CallinRules.KIND_INVENTORY, "")
	var order: CallinOrder = callins.apply_order(request)
	print("order made: ", order != null, " reason now: ", callins.checks.make_plan(request).reason)
	if order != null:
		await _wait_station(callins, order)
		await _shot(battle, order.lz, "station_placed")
	_guard.restore()
	get_tree().quit()


func _wait_station(callins: CallinDirector, order: CallinOrder) -> void:
	var t0 := Time.get_ticks_msec()
	while order.is_open() and order.state < CallinOrder.State.ACTIVE and Time.get_ticks_msec() - t0 < WAIT_S * 1000.0:
		await _frames(5)
	await _frames(SETTLE_FRAMES)
	print("order state ", order.state, " station ", callins.stations.get(order.object_id))


func _shot(battle: Battle, target: Vector3, tag: String) -> void:
	var dir := OS.get_environment("CALLIN_SHOT_DIR")
	var cam := Camera3D.new()
	battle.add_child(cam)
	cam.far = 3000.0
	cam.look_at_from_position(target + Vector3(CAMERA_BACK_M, CAMERA_UP_M, CAMERA_BACK_M), target + Vector3.UP * 1.5)
	battle.set_process(false)
	cam.make_current()
	await _frames(6)
	await RenderingServer.frame_post_draw
	var path := dir.path_join("%s.png" % tag)
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)

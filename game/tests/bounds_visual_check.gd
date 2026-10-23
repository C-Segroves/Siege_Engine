extends Node
## The out-of-area visuals (BoundsVisual): the red wall shows within range of the area edge and hides beyond (shorter on foot than
## in a vehicle), the tint is on exactly when BattleBounds says the local player is outside, and off inside, dead, and in a support
## craft; a dedicated server profile builds no wall nodes. Windowed with --shots=<dir>: saves bounds_<case>_<w>x<h>.png
## (a Herc near the edge, a Herc outside, a soldier near the edge, a soldier outside) at 1280x720 and 1920x1080.
##   godot --audio-driver Dummy --path game res://tests/bounds_visual_check.tscn [-- --shots=<dir> --map=<id> --vehicle=<id>]

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const WINDOW_SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080)]
const SETTLE_FRAMES := 20
const FOOT_NEAR := 40.0
const FOOT_FAR := 150.0
const VEHICLE_NEAR := 120.0
const VEHICLE_FAR := 400.0
const OUTSIDE := 30.0
const DEFAULT_VEHICLE := "es1:RAPTOR"
const SOLDIER_MAP := "tribes2:Katabatic"
const SOLDIER_ID := "tribes2:SHRIKE"   # the Tribes 2 vehicle that tells the pack is installed

var _failures := 0
var _shots := ""
var _map := ""
var _vehicle := DEFAULT_VEHICLE


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
		elif a.begins_with("--map="):
			_map = a.substr(6)
		elif a.begins_with("--vehicle="):
			_vehicle = a.substr(10)
	for sz in WINDOW_SIZES:
		await _set_window(sz)
		await _check_vehicle(sz)
	await _check_server_profile()
	print("bounds_visual_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame   # the visuals update per rendered frame


func _set_window(sz: Vector2i) -> void:
	var w := get_window()
	w.mode = Window.MODE_WINDOWED
	w.size = sz
	UiScale.apply(w)
	await _frames(4)


func _make_battle(vehicle: String) -> Battle:
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = Battle.default_config(vehicle)
	if _map != "":
		battle.config["map"] = _map
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


## `distance` metres inside (positive) or outside (negative) the west edge, at the area's middle in z.
func _place(battle: Battle, distance: float) -> void:
	var r := battle.bounds.bounds.area
	var p := battle.player
	var x := r.position.x + distance
	var z := r.get_center().y
	var ground := MapTerrain.make_surface_height(battle, Vector3(x, 0.0, z))
	p.global_position = Vector3(x, (ground if ground != INF else p.global_position.y) + 2.0, z)
	p.rotation.y = PI * 0.5   # facing the west edge
	if not p is Infantry:
		p.set_physics_process(false)
	p.velocity = Vector3.ZERO
	battle.bounds.set_physics_process(false)   # the test moves the body by hand: no damage or respawn meanwhile


func _check_vehicle(window: Vector2i) -> void:
	var battle := await _make_battle(_vehicle)
	var tag := "%dx%d" % [window.x, window.y]
	var vis: Node = battle.get_node_or_null("BoundsVisual")
	if battle.player == null or vis == null or not battle.bounds.bounds.has_area:
		print("skip  %s: no player, visuals or area on %s" % [tag, battle.config.get("map", "?")])
		_free(battle)
		await _frames(2)
		return
	var wall: BoundsWall = vis.get_meta("wall")
	var tint: BoundsTint = vis.get_meta("tint")
	var p := battle.player
	_expect(not p is Infantry, "%s: a vehicle is flown" % tag)
	await _expect_wall_and_tint(battle, wall, tint, tag + " vehicle", VEHICLE_NEAR, VEHICLE_FAR)
	await _shot(battle, "herc_near_edge", window, VEHICLE_NEAR * 0.4)
	await _shot(battle, "herc_outside", window, -OUTSIDE)
	await _expect_tint_cases(battle, tint, tag)
	_free(battle)
	await _frames(2)
	if Packs.vehicle(SOLDIER_ID).is_empty():
		return
	await _check_foot(window)


func _expect_wall_and_tint(battle: Battle, wall: BoundsWall, tint: BoundsTint, what: String, near: float, far: float) -> void:
	_place(battle, near * 0.5)
	await _frames(3)
	_expect(wall.strength > 0.0 and wall.mesh_instance.visible, "%s: the wall shows in range (strength %.2f)" % [what, wall.strength])
	_expect(wall.mesh_instance.mesh != null and wall.mesh_instance.mesh.get_surface_count() > 0, "%s: a wall strip is built" % what)
	_expect(not tint.is_on, "%s: no tint inside" % what)
	_place(battle, far)
	await _frames(3)
	_expect(wall.strength == 0.0 and not wall.mesh_instance.visible, "%s: the wall hides beyond range" % what)
	_place(battle, -OUTSIDE)
	await _frames(3)
	_expect(tint.is_on and tint.rect.visible and tint.warning.visible, "%s: the tint is on outside" % what)
	_expect(tint.is_on == battle.bounds.is_out_of_area(battle.player), "%s: the tint agrees with BattleBounds" % what)
	_place(battle, near * 0.5)
	await _frames(3)
	_expect(not tint.is_on and not tint.rect.visible, "%s: the tint clears on return" % what)


## Tint off when dead and in a support craft, while outside.
func _expect_tint_cases(battle: Battle, tint: BoundsTint, tag: String) -> void:
	var p := battle.player
	_place(battle, -OUTSIDE)
	await _frames(3)
	_expect(tint.is_on, "%s: outside again" % tag)
	SupportCraft.mark(p)
	await _frames(3)
	_expect(not tint.is_on and not battle.bounds.is_out_of_area(p), "%s: no tint in a support craft" % tag)
	p.remove_from_group(SupportCraft.GROUP)
	await _frames(3)
	_expect(tint.is_on, "%s: the tint is back after leaving it" % tag)
	p.alive = false
	await _frames(3)
	_expect(not tint.is_on, "%s: no tint when dead" % tag)
	p.alive = true


func _check_foot(window: Vector2i) -> void:
	var guard := SavedCampaignGuard.new()
	guard.back_up()
	var pilot := "QA Bounds %d" % OS.get_process_id()
	Net.player_name = pilot
	var p := ExtractionProfile.load_for(pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": SOLDIER_MAP, "respawn": true}, 3, 1)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = 4242
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	var soldier := battle.player as Infantry
	var t0 := Time.get_ticks_msec()
	while soldier != null and soldier.stowed and Time.get_ticks_msec() - t0 < 60000:
		await get_tree().physics_frame
	var vis: Node = battle.get_node_or_null("BoundsVisual")
	var tag := "%dx%d" % [window.x, window.y]
	if soldier != null and not soldier.stowed and vis != null and battle.bounds.bounds.has_area:
		var wall: BoundsWall = vis.get_meta("wall")
		var tint: BoundsTint = vis.get_meta("tint")
		await _expect_wall_and_tint(battle, wall, tint, tag + " soldier", FOOT_NEAR * 2.0, FOOT_FAR)
		_place(battle, BoundsVisual.value("show_range_foot_m") + 20.0)
		await _frames(3)
		_expect(wall.strength == 0.0, "%s soldier: the foot range is shorter than the vehicle's" % tag)
		await _shot(battle, "soldier_near_edge", window, FOOT_NEAR)
		await _shot(battle, "soldier_outside", window, -OUTSIDE)
	else:
		print("skip  %s soldier: no raid on foot" % tag)
	_free(battle)
	guard.restore()
	await _frames(2)


func _check_server_profile() -> void:
	ServerProfile.set_collision_only(true)
	var battle := await _make_battle(_vehicle)
	var found := battle.find_children("*", "BoundsWall", true, false).size() + battle.find_children("*", "BoundsTint", true, false).size()
	ServerProfile.set_collision_only(false)
	_expect(found == 0 and battle.get_node_or_null("BoundsVisual") == null, "server profile: no wall or tint nodes (%d)" % found)
	_free(battle)
	await _frames(2)


func _shot(battle: Battle, case_name: String, window: Vector2i, distance: float) -> void:
	_place(battle, distance)
	await _frames(40)   # terrain streams in after a move
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := "%s/bounds_%s_%dx%d.png" % [_shots, case_name, window.x, window.y]
	get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


func _free(battle: Battle) -> void:
	get_tree().current_scene = null
	battle.queue_free()

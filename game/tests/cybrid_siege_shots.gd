extends Node
## Windowed renders of the Cybrid siege on Varuna's Fall for checking by eye (needs a window and the Tribes 2 pack):
##   CYBRID_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/cybrid_siege_shots.tscn
## 1_broadcast.png   the map-wide broadcast and the countdown on the player's own screen
## 2_wave.png        a wave of Cybrid Hercs and infantry advancing on a faction base (the airfield)
## 3_look.png        a Cybrid soldier close up (the made-up metal look and the visor)
## 4_safe_area.png   the shrinking safe area's wall seen from inside the circle
const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const SEED := 4242
const SETTLE_FRAMES := 20
const LAND_FRAMES := 3600
const SHOT_FRAMES := 12
const SITE := "airfield"
const WAVE_DISTANCE := 330.0
const CAMERA_BACK := 70.0
const CAMERA_UP := 14.0
const ADVANCE_FRAMES := 150
const LOOK_DISTANCE := 5.5
const WALL_SECONDS := 900.0
const WALL_VIEW_DISTANCE := 90.0

var _pilot := "QA Siege Shots %d" % OS.get_process_id()
var _guard := SavedCampaignGuard.new()
var _cam: Camera3D


func _ready() -> void:
	ExtractionRules.data()["bot_sleep"]["enabled"] = false
	get_tree().create_timer(900.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_guard.back_up()
	Net.player_name = _pilot
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("CYBRID_SHOT_DIR")
	if dir == "":
		dir = ProjectSettings.globalize_path("user://cybrid_shots")
	DirAccess.make_dir_recursive_absolute(dir)
	var battle := await _start_raid()
	var x := battle.extraction
	var host := x.siege.host
	var player := battle.player as Infantry
	for i in LAND_FRAMES:
		if not player.stowed:
			break
		await get_tree().physics_frame
	player.spawn_protection = 100000.0
	player.apply_spawn_protection()
	var site := x.site_spawner.find_site(SITE)
	player.global_position = battle.infantry.make_on_ground(site.pos + Vector3(60, 0, 40))
	await _frames(10)
	host.apply_warning()
	for i in 4:
		host.apply_tick(1.0)
	host.timeline.apply_tick(30.0)
	for i in 3:
		host.apply_tick(1.0)
	await _frames(30)
	await _shot(dir.path_join("1_broadcast.png"))
	host.timeline.apply_tick(100.0)
	host.apply_tick(0.5)
	await _wave_on_base(x, site)
	await _shot_wave(dir.path_join("2_wave.png"), site)
	await _shot_look(dir.path_join("3_look.png"))
	await _shot_wall(battle, x, dir.path_join("4_safe_area.png"))
	_guard.restore()
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _start_raid() -> Battle:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": VarunaMap.MAP_ID, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = SEED
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


## A wave of Hercs and soldiers standing WAVE_DISTANCE out from the base, marching on it.
func _wave_on_base(x: ExtractionDirector, site: Dictionary) -> void:
	var host := x.siege.host
	var out := Vector3(0, 0, -1).rotated(Vector3.UP, 0.6)
	var gate: Vector3 = site.pos + out * WAVE_DISTANCE
	var pack := SiegeSpawner.make_infantry_pack()
	var sizes := ["LIGHT", "LIGHT", "MEDIUM", "LIGHT", "HEAVY", "LIGHT", "MEDIUM", "LIGHT", "HEAVY", "LIGHT"]
	for size in sizes:
		host.spawner._spawn_trooper(pack, size, gate, 0.55)
	var pool := SiegeSpawner.make_herc_pool(10)
	for k in 4:
		host.spawner._spawn_herc(str(pool[(k * 7 + 3) % pool.size()]), gate)
	x.siege.apply_looks()
	host.commander.apply_retarget()
	await _frames(ADVANCE_FRAMES)
	x.siege.apply_looks()


func _use_camera(at: Vector3, look_at: Vector3) -> void:
	if _cam == null:
		_cam = Camera3D.new()
		_cam.far = 6000.0
		_cam.fov = 62.0
		get_tree().current_scene.add_child(_cam)
	get_tree().current_scene.set_process(false)   # the battle's own cameras take over every frame otherwise
	_cam.global_position = at
	_cam.look_at(look_at, Vector3.UP)
	_cam.make_current()


func _shot_wave(path: String, site: Dictionary) -> void:
	var host: SiegeHost = (get_tree().current_scene as Battle).extraction.siege.host
	var centre := Vector3.ZERO
	var n := 0
	for r in host.spawner.units:
		if is_instance_valid(r.unit) and (r.unit as Herc).alive:
			centre += (r.unit as Herc).global_position
			n += 1
	centre /= maxf(n, 1.0)
	var toward: Vector3 = (site.pos - centre)
	toward.y = 0.0
	var back := -toward.normalized() * CAMERA_BACK
	_use_camera(centre + back + Vector3.UP * CAMERA_UP, site.pos + Vector3.UP * 8.0)
	await _shot(path)


func _shot_look(path: String) -> void:
	var host: SiegeHost = (get_tree().current_scene as Battle).extraction.siege.host
	for r in host.spawner.units:
		if r.kind == "infantry" and is_instance_valid(r.unit) and (r.unit as Herc).alive:
			var s := r.unit as Infantry
			var front := -s.global_basis.z.normalized()
			_use_camera(s.global_position + front * LOOK_DISTANCE + Vector3.UP * 1.6 + s.global_basis.x * 1.2, s.global_position + Vector3.UP * 1.4)
			await _shot(path)
			return


func _shot_wall(battle: Battle, x: ExtractionDirector, path: String) -> void:
	var host := x.siege.host
	host.timeline.siege_s = WALL_SECONDS
	await _frames(30)
	var c := host.zone.make_centre(WALL_SECONDS)
	var r := host.zone.make_radius(WALL_SECONDS)
	var site := x.site_spawner.find_site(SITE)
	var dir := (Vector2(site.pos.x, site.pos.z) - c).normalized()
	var wall := c + dir * r
	var from := wall - dir * WALL_VIEW_DISTANCE
	var ground := battle.infantry.make_on_ground(Vector3(from.x, 0.0, from.y))
	_use_camera(ground + Vector3.UP * 6.0, Vector3(wall.x, ground.y + 25.0, wall.y))
	await _frames(30)
	await _shot(path)


func _shot(path: String) -> void:
	for _f in SHOT_FRAMES:
		await get_tree().process_frame
	if _cam != null:
		_cam.make_current()
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)

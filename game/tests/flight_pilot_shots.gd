extends Node
## Windowed render of the extraction intro flight, for checking by eye (needs a window and the Tribes 2 pack):
##   FLIGHT_SHOT_DIR=<folder> [FLIGHT_SHOT_MAP=tribes2:Katabatic] godot --audio-driver Dummy --path game res://tests/flight_pilot_shots.tscn
## FLIGHT_SHOT_PATROL=<vehicle id> (e.g. tribes2:SHRIKE) flies that craft on a patrol across the hills about the drop point instead
## (several turns: banking shows, and every ridge on the way).
## A side camera rides along with the transport that flies the raider in (it banks into turns and pitches over ridges);
## flight_<n>.png every SHOT_EVERY seconds, plus a telemetry line (height over the ground, pitch, bank, speed) with each.

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const SEED := 4242
const SETTLE_FRAMES := 20
var SHOT_EVERY := float(OS.get_environment("FLIGHT_SHOT_EVERY")) if OS.get_environment("FLIGHT_SHOT_EVERY") != "" else 2.0
var MAX_SHOTS := int((float(OS.get_environment("FLIGHT_SHOT_SECONDS")) if OS.get_environment("FLIGHT_SHOT_SECONDS") != "" else 80.0) / SHOT_EVERY)
const PATROL_RADIUS := 1200.0
const PATROL_START_HEIGHT := 40.0
const SIDE_OFFSET := Vector3(34.0, 9.0, 26.0)

## FlyerAI that never picks a target: the patrol demo only flies.
class PatrolOnly extends FlyerAI:
	func _apply_target_search() -> void:
		flyer.target = null


var _pilot := "QA Flight Shots %d" % OS.get_process_id()
var _guard := SavedCampaignGuard.new()
var _cam: Camera3D
var _craft: Flyer


func _ready() -> void:
	get_tree().create_timer(400.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_guard.back_up()
	Net.player_name = _pilot
	await get_tree().process_frame
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("FLIGHT_SHOT_DIR")
	var map_id := OS.get_environment("FLIGHT_SHOT_MAP") if OS.get_environment("FLIGHT_SHOT_MAP") != "" else VarunaMap.MAP_ID
	var battle := await _start_raid(map_id)
	var x := battle.extraction
	_craft = _spawn_patrol(battle, x) if OS.get_environment("FLIGHT_SHOT_PATROL") != "" else battle.occupancy.vehicle_of(1) as Flyer
	if _craft == null:
		print("flight_pilot_shots: no transport flew the raider in on ", map_id)
		_finish()
		return
	print("map ", map_id, " transport ", _craft.display_name, " profile clearance ", _craft.pilot.profile.clearance_m)
	_cam = Camera3D.new()
	_cam.far = 6000.0
	battle.add_child(_cam)
	battle.set_process(false)
	_cam.make_current()
	var patrol := OS.get_environment("FLIGHT_SHOT_PATROL") != ""
	var n := 0
	var t := 0.0
	var next_shot := 0.0
	var lowest := INF
	while n < MAX_SHOTS and is_instance_valid(_craft) and _craft.alive and (patrol or battle.occupancy.soldier_of(1).stowed):
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		_follow()
		lowest = minf(lowest, _craft.make_altitude())
		if t >= next_shot:
			next_shot += SHOT_EVERY
			await _shot(dir, n)
			n += 1
	print("lowest height over the ground during the flight: %.1f m" % lowest)
	_finish()


## An AI flyer of the raider's team (nobody to attack) on a patrol of waypoints 1.2 km about the drop point (the Flyer's own FlyerAI flies it).
func _spawn_patrol(battle: Battle, x: ExtractionDirector) -> Flyer:
	var centre: Vector3 = x.zones[0]
	var path := PackedVector3Array()
	for corner in [Vector2(1, 0), Vector2(0.2, 1), Vector2(-1, 0.3), Vector2(0, -1), Vector2(0.9, -0.5)]:
		var p := centre + Vector3(corner.x, 0.0, corner.y) * PATROL_RADIUS
		path.append(Vector3(p.x, MapBuilder.ground_height(battle, p), p.z))
	var start := path[0] + Vector3.UP * PATROL_START_HEIGHT
	var spec := {"net_id": battle.spawner.allocate_id(), "vehicle": OS.get_environment("FLIGHT_SHOT_PATROL"), "team": battle.occupancy.soldier_of(1).team, "owner": 1,
		"xf": Transform3D(Basis(Vector3.UP, 0.0), start), "loadout": [], "name": "Patrol",
		"ai": {"skill": 0.5, "flyer": true, "path": path}}
	battle.send_spawn(spec)
	var fl := battle.vehicles.get(int(spec.net_id)) as Flyer
	fl.set_meta("dormant", true)
	fl.ai = PatrolOnly.new(fl)
	return fl


func _follow() -> void:
	var basis := _craft.global_basis.orthonormalized()
	_cam.global_position = _craft.global_position + basis * SIDE_OFFSET
	_cam.look_at(_craft.global_position + Vector3.UP * 2.0, Vector3.UP)
	_cam.make_current()


func _shot(dir: String, n: int) -> void:
	_follow()
	print("t%05.1f agl %.0f m  pitch %+.0f deg  bank %+.0f deg  speed %.0f m/s  vy %+.0f req %.0f at %s" % [n * SHOT_EVERY, _craft.make_altitude(),
		rad_to_deg(_craft.flight.pitch), rad_to_deg(_craft.flight.bank), _craft.flight.speed, _craft.flight.velocity.y, _craft.pilot._required_climb, str(_craft.global_position.round())])
	if dir == "" or DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/flight_%02d.png" % [dir, n])


func _start_raid(map_id: String) -> Battle:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": map_id, "respawn": true}, 0, 0)
	config["extraction_seed"] = SEED
	config[ExtractionRules.FAST_CONFIG_KEY] = OS.get_environment("FLIGHT_SHOT_FAST") != ""
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	return battle


func _finish() -> void:
	_guard.restore()
	get_tree().quit()

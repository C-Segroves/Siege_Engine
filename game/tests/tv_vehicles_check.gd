extends Node
## The drivable Tribes: Vengeance vehicles (tools/tv_vehicles.py, game/games/tribes_v/tv_vehicle_fleet.gd):
##   1. the catalog: Pod, Tank, AssaultShip and Buggy with their class-default handling, hull, seats, turret and fixed weapons;
##   2. the maps place them as vehicle records (no longer scenery) and a mission battle streams them in parked, boardable;
##   3. each vehicle in a mission battle: the player's soldier boards it by touch, drives or flies it a distance (the SiegeInput actions),
##      fires every weapon, the shots hurt an enemy copy, and it is destroyed when its hull goes;
##   4. an enemy vehicle with AI goals is crewed by the shared AI pilots and moves on its own.
## The facing (nose -Z) is vehicle_facing_check's. Needs Tribes: Vengeance and Tribes 2 (the soldier) imported; skips otherwise.
##   TV_TEST_ROOT=<data folder> godot --headless --audio-driver Dummy --path game res://tests/tv_vehicles_check.tscn
##   tv_vehicle_shots.tscn: the windowed renders of the same stage (TV_SHOT_DIR=<folder>)

const PACK := "tribes_v"
const DUMMY := "TANK"                       # the enemy copy every vehicle shoots at: big, and it stays on the ground
## The frozen enemy's origin sits this far above the shooter's (its hull is 5.3 m tall: the guns' line, level or climbing 3 degrees, crosses it).
const DUMMY_ORIGIN_RISE := -0.6
const IDS := ["POD", "TANK", "ASSAULT_SHIP", "BUGGY"]
const KINDS := {"POD": "flyer", "TANK": "tank", "ASSAULT_SHIP": "flyer", "BUGGY": "wheeled"}
const SEATS := {"POD": 1, "TANK": 2, "ASSAULT_SHIP": 3, "BUGGY": 6}
const GUNS := {"POD": 2, "TANK": 2, "ASSAULT_SHIP": 3, "BUGGY": 1}
const TURRETS := ["TANK", "BUGGY"]
## Class defaults (Content/Classes/VehicleClasses.pkg): Health, TopSpeed (uu/s, 1/70 m per unit).
const HEALTH := {"POD": 140.0, "TANK": 800.0, "ASSAULT_SHIP": 550.0, "BUGGY": 450.0}
const HP_PER_HEALTH := 26.4
const POD_TOP_SPEED_MPS := 4400.0 / 70.0
const SHIP_TOP_SPEED_MPS := 2100.0 / 70.0
## Mission with a quiet start in open terrain (SP-Mercy-Escape: one parked buggy 22 m away).
const MISSION_MAP := "SP-Mercy-Escape"
## Mission with a long level stretch of open ground near the start (its own vehicles are taken away) and a soldier who may pilot (a
## heavy armour may not: SP-Prison-Junkyard's): the stage of the driving checks.
const STAGE_MAP := "SP-Regicide"
const SETTLE_FRAMES := 40
const LANE_WIDTH := 24.0                   # the vehicles drive and fire along -Z
const LANE_SAMPLE_M := 6.0
const LANE_LENGTH := 160.0
const LEVEL_M := 1.2
const SITE_RINGS := 12
const SITE_RING_STEP := 50.0
const SITE_DIRECTIONS := 12
const AI_SPACING := 25.0
const LANE_CLEAR_HEIGHTS := [1.0, 3.0, 6.0]
const NO_FLOOR := -100000.0
const FLOOR_PROBE_M := 40.0
const TERRAIN_AGREES_M := 1.0
const DRIVE_SECONDS := 4.0
const MIN_DRIVE_M := {"POD": 20.0, "TANK": 8.0, "ASSAULT_SHIP": 10.0, "BUGGY": 15.0}
const FIRE_SECONDS := 3.0
const TARGET_DISTANCE := 40.0
## A parked aircraft's shots fly level and strike the ground a few metres ahead: the enemy stands inside their blast.
const AIR_TARGET_DISTANCE := 9.0
const AI_SECONDS := 8.0
const MIN_AI_MOVE_M := 15.0
const SETTLE_PHYSICS_FRAMES := 20
const BOARD_PHYSICS_FRAMES := 30
const WATCHDOG_SECONDS := 240.0

var _fails := 0
var _battle: Battle
var _shot_dir := ""


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void:
		print("FAIL  watchdog: the check hung")
		get_tree().quit(2))
	_run.call_deferred()


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _run() -> void:
	var root := OS.get_environment("TV_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	_shot_dir = OS.get_environment("TV_SHOT_DIR")
	if not Assets.has_pack(PACK) or not Assets.has_pack("tribes2") or Packs.vehicle("%s:POD" % PACK).is_empty():
		print("tv_vehicles_check: Tribes: Vengeance (with vehicles) or Tribes 2 is not imported, skipped")
		get_tree().quit(0)
		return
	_check_catalog()
	_check_maps()
	await _start_mission(MISSION_MAP)
	await _check_placed_vehicle()
	_battle.queue_free()
	await get_tree().process_frame
	await _start_mission(STAGE_MAP)
	var site := _find_site()
	for i in IDS.size():
		await _check_vehicle(IDS[i], site)
	await _check_ai_vehicles(site)
	_battle.queue_free()
	await get_tree().process_frame
	print("tv_vehicles_check: %s (%d failures)" % ["OK" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# ------------------------------------------------------------------ 1. catalog

func _check_catalog() -> void:
	print("catalog:")
	for key in IDS:
		var id := "%s:%s" % [PACK, key]
		var v := Packs.vehicle(id)
		_expect(not v.is_empty() and v.category == "vehicle" and v.kind == KINDS[key], "%s: category vehicle, kind %s" % [id, v.get("kind", "?")])
		_expect(bool(v.get("flyer", false)) == (KINDS[key] == "flyer"), "%s: flyer flag %s" % [id, v.get("flyer", false)])
		_expect(not Assets.shape(str(v.shape)).is_empty() and bool(v.pilotable) and PackVehicleLoader.has_fixed_loadout(v),
			"%s: shape installed, pilotable, fixed weapons" % id)
		_expect(absf(_hull_hp(v) - HEALTH[key] * HP_PER_HEALTH) < 1.0,
			"%s: hull %.0f hp = Health %s x 26.4" % [id, _hull_hp(v), HEALTH[key]])
		_expect(BoardingRules.make_seat_count(v) == SEATS[key] and (v.guns as Array).size() == GUNS[key] and v.loadout.size() == GUNS[key],
			"%s: %d seats, %d guns with their weapons" % [id, BoardingRules.make_seat_count(v), v.guns.size()])
		_expect((v.loadout as Array).all(func(w: String) -> bool: return Packs.weapon(w).get("category", "") == "vehicle"),
			"%s: its weapons are vehicle weapons %s" % [id, v.loadout])
		_expect(not WeaponFit.fits(Packs.weapon(str(v.loadout[0])), v, 0, {}), "%s: no Herc weapon or other pod fits its mounts" % id)
		_expect((v.torso_node as int >= 0) == TURRETS.has(key), "%s: turret node %d" % [id, int(v.torso_node)])
		_expect(VehicleSeats.make_role(id, 0) == VehicleSeats.PILOT, "%s: seat 0 is the pilot's" % id)
	var pod := FlightPresets.make_params(Packs.vehicle("%s:POD" % PACK), 1.0)
	var ship := FlightPresets.make_params(Packs.vehicle("%s:ASSAULT_SHIP" % PACK), 1.0)
	_expect(absf(float(pod.max_speed) - POD_TOP_SPEED_MPS) < 0.1 and absf(float(ship.max_speed) - SHIP_TOP_SPEED_MPS) < 0.1,
		"the aircraft fly at their TopSpeed (%.1f and %.1f m/s)" % [pod.max_speed, ship.max_speed])
	_expect(VehicleSeats.make_gunner_seat("%s:TANK" % PACK) == 1 and VehicleSeats.make_gunner_seat("%s:POD" % PACK) < 0, "the tank has a gunner seat, the pod none")
	_expect(Packs.vehicle("%s:TANK" % PACK).max_speed < Packs.vehicle("%s:BUGGY" % PACK).max_speed, "the tank is slower than the rover (TopSpeed 5000 against 13250)")


static func _hull_hp(v: Dictionary) -> float:
	var hp := 0.0
	for c in v.damage.components:
		hp += float(c.hp)
	return hp


# ------------------------------------------------------------------ 2. maps

func _check_maps() -> void:
	print("maps:")
	var idx = Assets.load_json("maps/_index.json", PACK)
	var placed := 0
	var scenery := 0
	var unknown := 0
	for e in idx:
		var m := MapBuilder.load_map("%s:%s" % [PACK, e.id])
		for rec in m.get("vehicles", []):
			placed += 1
			unknown += 0 if not Packs.vehicle(str(rec.vehicle)).is_empty() else 1
		for s in m.get("statics", []):
			scenery += 1 if str(s.get("actor", "")).begins_with("Vehicle") else 0
	_expect(placed >= 50 and unknown == 0, "%d vehicles are placed in the maps, all of a catalog vehicle (%d unknown)" % [placed, unknown])
	_expect(scenery == 0, "no vehicle is left as scenery (%d)" % scenery)


# ------------------------------------------------------------------ battle

func _start_mission(map_id: String) -> void:
	Session.start_stage_campaign(PACK)
	var c: Object = Session.campaign
	for i in c.missions.size():
		if str(c.missions[i].map) == map_id:
			c.index = i
	var herc := MatchFlow.make_issued_soldier()
	_battle = load("res://games/es1/battle.tscn").instantiate()
	_battle.config = MatchFlow.make_mission_config(str(herc.vehicle), [], {})
	get_tree().root.add_child(_battle)
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	var rt := _battle.mission as TVMissionRuntime
	rt._npcs.clear()                  # no placed soldier or vehicle of the map interferes (_check_placed_vehicle keeps its own)
	if map_id != MISSION_MAP:
		rt.fleet.entries.clear()
	rt.set_physics_process(false)     # the script must not end the mission under the checks (a timer, a trigger the aircraft fly through)


func _soldier() -> Infantry:
	return _battle.occupancy.soldier_of(multiplayer.get_unique_id())


## A level spot with a real floor: every point of a LANE_WIDTH x LANE_LENGTH patch ahead (along -Z) has a physics floor within LEVEL_M of the
## first and nothing solid stands in the lane at vehicle height; inside the map. (The height field alone lies where the terrain has holes.)
func _find_site() -> Vector3:
	var origin := _soldier().global_position
	for ring in range(1, SITE_RINGS + 1):
		for k in SITE_DIRECTIONS:
			var a := TAU * float(k) / SITE_DIRECTIONS
			var p := origin + Vector3(cos(a), 0.0, sin(a)) * ring * SITE_RING_STEP
			if _is_clear_lane(p):
				p.y = _floor_y(p)
				return p
	push_error("tv_vehicles_check: no level lane near the player")
	return origin


func _is_clear_lane(p: Vector3) -> bool:
	var base := _floor_y(p)
	if is_nan(base):
		return false
	for dz in range(0, int(LANE_LENGTH) + 1, int(LANE_SAMPLE_M)):
		for dx in range(-int(LANE_WIDTH * 0.5), int(LANE_WIDTH * 0.5) + 1, int(LANE_SAMPLE_M)):
			var q := p + Vector3(float(dx), 0.0, -float(dz))
			var floor_at := _floor_y(q)
			if _battle.bounds.bounds.is_outside(q) or is_nan(floor_at) or absf(floor_at - base) > LEVEL_M:
				return false
	for dx in [-LANE_WIDTH * 0.5, 0.0, LANE_WIDTH * 0.5]:
		for rise in LANE_CLEAR_HEIGHTS:
			var from := Vector3(p.x + dx, base + rise, p.z)
			if not _battle.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3(0, 0, -LANE_LENGTH))).is_empty():
				return false
	return true


## The terrain's floor under `p`: the physics floor where it agrees with the height field (NAN over a hole of the terrain, under a roof or a
## bridge, outside the map).
func _floor_y(p: Vector3) -> float:
	var h := MapBuilder.ground_height(_battle, Vector3(p.x, NO_FLOOR, p.z))
	if h <= NO_FLOOR:
		return NAN                    # off the terrain or over a hole of it: the ground vehicles' own ground model has nothing there
	var hit := _battle.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(Vector3(p.x, h + FLOOR_PROBE_M, p.z), Vector3(p.x, h - FLOOR_PROBE_M, p.z)))
	return float(hit.position.y) if not hit.is_empty() and absf(float(hit.position.y) - h) < TERRAIN_AGREES_M else NAN


## The map's parked buggy appears when the player is near, stands on the ground and the soldier may take its pilot seat.
func _check_placed_vehicle() -> void:
	print("placed vehicle (%s):" % MISSION_MAP)
	var rt := _battle.mission as TVMissionRuntime
	_expect(rt != null and rt.fleet.entries.size() == 1, "the mission has one placed vehicle (%d)" % rt.fleet.entries.size())
	var e: Dictionary = rt.fleet.entries[0]
	var far := TVVehicleFleet.new(rt)
	far.build([e.rec])
	far.sync(_soldier().global_position + Vector3(TVVehicleFleet.SPAWN_RADIUS * 4.0, 0, 0))
	_expect(not bool(far.entries[0].spawned), "a vehicle does not appear while the player is far (> %.0f m)" % TVVehicleFleet.SPAWN_RADIUS)
	rt.fleet.sync(_soldier().global_position)
	await get_tree().process_frame
	var v := e.vehicle as Herc
	_expect(bool(e.spawned) and v != null and is_instance_valid(v), "it appears within %.0f m of the player" % TVVehicleFleet.SPAWN_RADIUS)
	if v == null:
		return
	for _f in 20:
		await get_tree().physics_frame
	var where := TVVehicleFleet.make_start_point(e.rec, _battle, Packs.vehicle(str(e.rec.vehicle)))
	_expect(v.vehicle_id == "%s:BUGGY" % PACK and VehicleOccupancy.of(v).is_empty(), "it is a parked, empty Rover")
	_expect(v.global_position.distance_to(where) < 3.0, "it stands where the actor was (%.1f m off)" % v.global_position.distance_to(where))
	var check := BoardingRules.make_seat_choice(_soldier(), v, VehicleOccupancy.of(v))
	_expect(bool(check.ok) and int(check.seat) == VehicleOccupancy.PILOT_SEAT, "the soldier would take its pilot seat (%s)" % [check])


# ------------------------------------------------------------------ 3. one vehicle

func _spawn(key: String, at: Vector3, ally: bool, ai_goals := false) -> Herc:
	var rec := {"vehicle": "%s:%s" % [PACK, key], "pos": [at.x, at.y, at.z], "basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
		"ai_goals": ai_goals, "label": key}
	return TVVehicleFleet.make_spawned(_battle, TVVehicleFleet.make_spec(rec, _battle, ally))


static func _health(h: Herc) -> float:
	var hull := 0.0
	for c in h.components:
		hull += float(c.hp)
	return h.shield_front + h.shield_rear + hull


func _check_vehicle(key: String, at: Vector3) -> void:
	var id := "%s:%s" % [PACK, key]
	print("%s:" % id)
	var v := _spawn(key, at, true)
	var soldier := _soldier()
	for _f in SETTLE_PHYSICS_FRAMES:
		await get_tree().physics_frame
	# board by touching the hull (the Tribes 2 rule)
	soldier.global_position = v.global_position + Vector3(BoardingRules.make_hull_radius(v) + 0.2, 0.3, 0.0)
	soldier.velocity = Vector3.ZERO
	for _f in BOARD_PHYSICS_FRAMES:
		await get_tree().physics_frame
		if _battle.player == v:
			break
	_expect(_battle.player == v and VehicleOccupancy.of(v).pilot() == multiplayer.get_unique_id(), "the soldier boarded by touch and pilots it")
	if _battle.player != v:
		_battle.remove_vehicle(v.net_id)
		return
	var enemy := _spawn(DUMMY, v.global_position + Vector3(0, 0, -(AIR_TARGET_DISTANCE if v is Flyer else TARGET_DISTANCE)), false)
	await get_tree().physics_frame
	enemy.set_physics_process(false)
	enemy.global_position.y = v.global_position.y + DUMMY_ORIGIN_RISE      # hull centred on the guns' line, whatever the slope
	var before := _health(enemy)
	v.target = enemy                  # locked, as the player's target_nearest does
	var shots := await _hold_fire(FIRE_SECONDS)
	_expect(shots >= 1, "it fired %d shots from its %d weapons" % [shots, v.weapons.size()])
	_expect(_health(enemy) < before, "the shots hurt an enemy %s (%.0f -> %.0f)" % [DUMMY, before, _health(enemy)])
	var start := v.global_position
	await _drive(v, DRIVE_SECONDS)
	var moved := Vector2(v.global_position.x - start.x, v.global_position.z - start.z).length()
	_expect(moved >= float(MIN_DRIVE_M[key]), "driven %.0f m in %.0f s (%s, %.1f m/s top speed)" % [moved, DRIVE_SECONDS, key, v.max_speed])
	if v is Flyer:
		_expect((v as Flyer).make_altitude() > 0.5, "it flies (%.1f m above the ground)" % (v as Flyer).make_altitude())
	_expect(v.alive and _health(v) > 0.0, "it is intact")
	v.target = null
	_battle.remove_vehicle(enemy.net_id)
	v.apply_environment_damage(1.0)
	await get_tree().physics_frame
	_expect(not v.alive, "it is destroyed when its hull goes")
	_release_controls()
	_battle.remove_vehicle(v.net_id)


func _release_controls() -> void:
	for a in ["throttle_up", "throttle_down", "ascend", "fire_group_1", "fire_group_2"]:
		Input.action_release(a)


## Holds both fire groups as the player would (gamepad active so no mouse capture is needed); returns the projectiles launched.
func _hold_fire(seconds: float) -> int:
	SiegeInput.last_device = SiegeInput.Device.GAMEPAD
	var shots := [0]
	var counter := func(n: Node) -> void:
		if n is Projectile:
			shots[0] += 1
	_battle.child_entered_tree.connect(counter)
	for a in ["fire_group_1", "fire_group_2"]:
		Input.action_press(a)
	await _wait(seconds)
	for a in ["fire_group_1", "fire_group_2"]:
		Input.action_release(a)
	await get_tree().create_timer(0.5).timeout
	_battle.child_entered_tree.disconnect(counter)
	return int(shots[0])


## Full throttle (and lift for an aircraft) through the input actions.
func _drive(v: Herc, seconds: float) -> void:
	Input.action_press("throttle_up")
	if v is Flyer:
		Input.action_press("ascend")
	await _wait(seconds)
	Input.action_release("throttle_up")
	Input.action_release("ascend")


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()


# ------------------------------------------------------------------ 4. AI crews

func _check_ai_vehicles(at: Vector3) -> void:
	print("AI crews:")
	var cases := {}
	for i in IDS.size():
		var p := at + Vector3(AI_SPACING * i, 0, 0)
		p.y = _floor_y(p)
		cases[IDS[i]] = {"vehicle": _spawn(IDS[i], p, false, true), "start": p}
	var enemy_hold := _soldier()
	enemy_hold.spawn_protection = 600.0       # the AI vehicles shoot at the soldier; he is not what this checks
	enemy_hold.apply_spawn_protection()
	await _wait(AI_SECONDS)
	for key in IDS:
		var v := cases[key].vehicle as Herc
		var moved := Vector2(v.global_position.x - cases[key].start.x, v.global_position.z - cases[key].start.z).length()
		var occ := VehicleOccupancy.of(v)
		_expect(occ.is_ai_piloted(), "%s has the AI pilot" % key)
		_expect(moved >= MIN_AI_MOVE_M or v.global_position.y - cases[key].start.y > 5.0, "%s moved %.0f m on its own in %.0f s" % [key, moved, AI_SECONDS])
		_battle.remove_vehicle(v.net_id)

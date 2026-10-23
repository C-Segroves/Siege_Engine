extends Node
## The drivable Tribes: Vengeance vehicles (tools/tv_vehicles.py, game/games/tribes_v/tv_vehicle_fleet.gd):
##   1. the catalog: Pod, Tank, AssaultShip and Buggy with their class-default handling, hull, seats, turret and fixed weapons;
##   2. the maps place them as vehicle records (no longer scenery) and a mission battle streams them in parked, boardable;
##   3. each vehicle in a mission battle: the player's soldier boards it by touch, drives or flies it a distance (the SiegeInput actions),
##      fires every weapon, the shots hurt an enemy copy, and it is destroyed when its hull goes;
##   4. an enemy vehicle with AI goals is crewed by the shared AI pilots and moves on its own;
##   5. riders: the pilot of the Pod and the Rover and the two gunners of the Assault Ship are drawn on their seat nodes in the seat pose
##      (the Tank's and the Rover's other seats are hidden, as in the original); the wheels turn and steer, the landing gear and wings
##      follow the altitude, the tank's treads run;
##   6. a vehicle pad holds its vehicle, builds the next after its spawn time and sells it as a station;
##   7. a crewed vehicle follows the goals a script gives it (VehiclePatrol, VehicleMoveTo) through the shared AIOrder, and a script
##      can spawn one (ActionSpawnRook).
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
const AI_SAMPLE_SECONDS := 0.5
const MIN_AI_MOVE_M := 8.0
const SETTLE_PHYSICS_FRAMES := 20
const BOARD_PHYSICS_FRAMES := 30
const WATCHDOG_SECONDS := 420.0
## Seats whose rider the original draws (positions: hideOccupant false) and the body sequence each sits in.
const SEATS_SHOWN := {"POD": [0], "TANK": [], "ASSAULT_SHIP": [1, 2], "BUGGY": [0]}
const SEAT_POSES := {"POD": "pod_stand", "ASSAULT_SHIP": "ashipgunner_stand", "BUGGY": "buggy_stand"}
const RIDER_BODY := "tribes_v:tv_phoenixmedium"
const FIRST_RIDER_PEER := 2001
const ON_SEAT_M := 0.05
const RIDER_SETTLE_FRAMES := 6
const WHEELS := 4
const MIN_STEER_RAD := 0.1
const TURN_SECONDS := 1.5
const GEAR_UP_MIN := 0.9
const PAD_SPAWN_S := 90.0
const PAD_ABANDON_M := 71.4
const PAD_ABANDON_S := 60.0
const PAD_LIFT_M := 0.57
const PAD_MAX_OFF_M := 3.0
const CLEAR_OF_PAD_M := 10.0
const PATROL_SECONDS := 45.0
const PATROL_REACH_M := 90.0
const GROUND_MOVE_M := 120.0
const GROUND_MOVE_SECONDS := 25.0
const GOAL_STEP_SECONDS := 0.5

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
	await _check_riders(site)
	await _check_pad(site)
	await _check_goals(site)
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
	_check_parts_catalog()
	var pod := FlightPresets.make_params(Packs.vehicle("%s:POD" % PACK), 1.0)
	var ship := FlightPresets.make_params(Packs.vehicle("%s:ASSAULT_SHIP" % PACK), 1.0)
	_expect(absf(float(pod.max_speed) - POD_TOP_SPEED_MPS) < 0.1 and absf(float(ship.max_speed) - SHIP_TOP_SPEED_MPS) < 0.1,
		"the aircraft fly at their TopSpeed (%.1f and %.1f m/s)" % [pod.max_speed, ship.max_speed])
	_expect(VehicleSeats.make_gunner_seat("%s:TANK" % PACK) == 1 and VehicleSeats.make_gunner_seat("%s:POD" % PACK) < 0, "the tank has a gunner seat, the pod none")
	_expect(Packs.vehicle("%s:TANK" % PACK).max_speed < Packs.vehicle("%s:BUGGY" % PACK).max_speed, "the tank is slower than the rover (TopSpeed 5000 against 13250)")


## Bones bound to their parts, sequences, seat nodes and the parts block of each vehicle.
func _check_parts_catalog() -> void:
	for key in IDS:
		var id := "%s:%s" % [PACK, key]
		var v := Packs.vehicle(id)
		var sh := Assets.shape(str(v.shape))
		var pieces: Array = sh.lods[0].pieces
		_expect(pieces.size() >= 4, "%s: its vertices ride %d bones (wheels, wings, tracks, engines are parts of their own)" % [id, pieces.size()])
		var seats := InfantryGear.seats_of(id)
		var shown := []
		for i in seats.size():
			if bool(seats[i].shown):
				shown.append(i)
				_expect(_has_node(sh, str(seats[i].node)), "%s: seat %d has its node %s" % [id, i, seats[i].node])
		_expect(shown == SEATS_SHOWN[key], "%s: the seats drawn are %s (hideOccupant of the class positions)" % [id, shown])
	var buggy := Packs.vehicle("%s:BUGGY" % PACK).get("parts", {}) as Dictionary
	_expect((buggy.get("wheels", {}).get("list", []) as Array).size() == WHEELS and float(buggy.wheels.radius_m) > 0.5, "the Rover has %d wheels of its WheelRadius" % WHEELS)
	var ship := Packs.vehicle("%s:ASSAULT_SHIP" % PACK).get("parts", {}) as Dictionary
	_expect(ship.has("gear") and ship.has("wings"), "the Assault Ship has landing gear and wings")
	_expect((Packs.vehicle("%s:TANK" % PACK).get("parts", {}) as Dictionary).has("treads"), "the Tank has treads")


static func _has_node(shape: Dictionary, node_name: String) -> bool:
	return (shape.nodes as Array).any(func(n: Dictionary) -> bool: return str(n.name).to_lower() == node_name.to_lower())


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
	# the mission's script has given this one (the supply rover) goals and a pilot already: the map's record in a fleet of its own is parked
	var rec: Dictionary = (MapBuilder.load_map("%s:%s" % [PACK, MISSION_MAP]).vehicles as Array)[0]
	var fleet := TVVehicleFleet.new(rt)
	fleet.build([rec])
	var e: Dictionary = fleet.entries[0]
	var far := TVVehicleFleet.new(rt)
	far.build([rec])
	far.sync(_soldier().global_position + Vector3(TVVehicleFleet.SPAWN_RADIUS * 4.0, 0, 0))
	_expect(not bool(far.entries[0].spawned), "a vehicle does not appear while the player is far (> %.0f m)" % TVVehicleFleet.SPAWN_RADIUS)
	for mission_entry in rt.fleet.entries:           # the script's own rover (crewed) makes room for the parked one
		if mission_entry.vehicle != null and is_instance_valid(mission_entry.vehicle):
			_battle.remove_vehicle((mission_entry.vehicle as Herc).net_id)
	rt.fleet.entries.clear()
	fleet.sync(_soldier().global_position)
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
	_check_parked_parts(key, v)
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
	await _check_driven_parts(key, v)
	v.target = null
	_battle.remove_vehicle(enemy.net_id)
	v.apply_environment_damage(1.0)
	await get_tree().physics_frame
	_expect(not v.alive, "it is destroyed when its hull goes")
	_release_controls()
	_battle.remove_vehicle(v.net_id)


## Standing on the ground: the Assault Ship has its gear out and its wings folded.
func _check_parked_parts(key: String, v: Herc) -> void:
	if key != "ASSAULT_SHIP":
		return
	var layers := v.parts.layers as Dictionary
	_expect(float(layers.get("gearup", 1.0)) == 0.0 and float(layers.get("wingsclosed", 0.0)) == 1.0,
		"parked: landing gear out, wings folded %s" % [layers])


## After the drive (the vehicle is still moving): wheels rolled and steer, gear in and wings out in the air, treads and engines moving.
func _check_driven_parts(key: String, v: Herc) -> void:
	var p := v.parts
	_expect((p != null) == Packs.vehicle(v.vehicle_id).has("parts"), "%s: its parts are animated" % key)
	if p == null:
		return
	var layers := p.layers as Dictionary
	match key:
		"BUGGY":
			_expect(absf(p.rolled_m) > float(MIN_DRIVE_M[key]) * 0.5, "the Rover's wheels rolled %.0f m" % p.rolled_m)
			Input.action_press("turn_left")
			Input.action_press("throttle_up")
			await _wait(TURN_SECONDS)
			_expect(absf(p.steer) > MIN_STEER_RAD, "its front wheels steer into the turn (%.2f rad)" % p.steer)
			Input.action_release("turn_left")
		"ASSAULT_SHIP":
			_expect(float(layers.get("gearup", 0.0)) >= GEAR_UP_MIN and float(layers.get("wingsclosed", 1.0)) < 1.0 - GEAR_UP_MIN,
				"flying: the landing gear is in and the wings are out %s" % [layers])
		"TANK":
			_expect(float(p.tread_phase.left) > 0.0 and float(p.tread_phase.right) > 0.0 and layers.has("leftforward"),
				"the tank's treads run (%s)" % [p.tread_phase])
		"POD":
			_expect(float(layers.get("throttleforward", 0.0)) > 0.3 and layers.has("idle"), "the pod's engines tilt and idle %s" % [layers])


func _release_controls() -> void:
	for a in ["throttle_up", "throttle_down", "ascend", "turn_left", "fire_group_1", "fire_group_2"]:
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
	var travelled := {}                      # the way driven: a vehicle that goes to and fro (or stops to shoot) is back where it started
	var last := {}
	for key in IDS:
		last[key] = (cases[key].vehicle as Herc).global_position
	var t := 0.0
	while t < AI_SECONDS:
		await _wait(AI_SAMPLE_SECONDS)
		t += AI_SAMPLE_SECONDS
		for key in IDS:
			var now := (cases[key].vehicle as Herc).global_position
			travelled[key] = float(travelled.get(key, 0.0)) + Vector2(now.x - last[key].x, now.z - last[key].z).length()
			last[key] = now
	for key in IDS:
		var v := cases[key].vehicle as Herc
		var moved := float(travelled[key])
		var occ := VehicleOccupancy.of(v)
		_expect(occ.is_ai_piloted(), "%s has the AI pilot" % key)
		_expect(moved >= MIN_AI_MOVE_M or v.global_position.y - cases[key].start.y > 5.0, "%s moved %.0f m on its own in %.0f s" % [key, moved, AI_SECONDS])
		_battle.remove_vehicle(v.net_id)


# ------------------------------------------------------------------ 5. riders

## Every seat of every vehicle taken: the seats the original draws show their rider on the seat node in the seat's pose, the others stay hidden.
func _check_riders(at: Vector3) -> void:
	print("riders:")
	var next_peer := FIRST_RIDER_PEER
	for key in IDS:
		var v := _spawn(key, at, true)
		for _f in SETTLE_PHYSICS_FRAMES:
			await get_tree().physics_frame
		var riders: Array[Infantry] = []
		for seat in BoardingRules.make_seat_count(v.def):
			riders.append(_board(v, seat, next_peer))
			next_peer += 1
		for _f in RIDER_SETTLE_FRAMES:
			await get_tree().process_frame
			await get_tree().physics_frame
		for seat in riders.size():
			_check_rider(key, riders[seat], seat)
		for r in riders:
			_battle.remove_vehicle(r.net_id)
		_battle.remove_vehicle(v.net_id)


func _check_rider(key: String, r: Infantry, seat: int) -> void:
	var drawn: bool = (SEATS_SHOWN[key] as Array).has(seat)
	var tag := "%s seat %d" % [key, seat]
	_expect(r.is_seated_visibly() == drawn and r.visible == drawn, "%s: the rider is %s" % [tag, "drawn" if drawn else "hidden"])
	if not drawn:
		return
	var off := r.global_position.distance_to(r.seat.node.global_position)
	_expect(off < ON_SEAT_M, "%s: he sits on %s (%.3f m off)" % [tag, r.seat.node.name, off])
	_expect(r.make_pose_name().to_lower() == SEAT_POSES[key], "%s: he sits in %s (%s)" % [tag, SEAT_POSES[key], r.make_pose_name()])


## A soldier in a Vengeance body for the fake peer `peer`, put in `seat` by the state message every peer applies.
func _board(v: Herc, seat: int, peer: int) -> Infantry:
	var armor := "tribes2:MEDIUM"
	var spec := _battle.infantry.make_soldier_spec(peer, TVMissionRuntime.PLAYER_TEAM, "Rider %d" % seat, v.global_transform)
	spec.merge({"vehicle": armor, "armor": armor, "spawn_armor": armor, "body_shape": RIDER_BODY,
		"loadout": InfantryCatalog.armor(armor).get("default_loadout", [])}, true)
	_battle.send_spawn(spec)
	var s := _battle.vehicles.get(spec.net_id) as Infantry
	var occ := VehicleOccupancy.of(v)
	occ.apply_seat(seat, peer)
	_battle.occupancy._apply_state(v.net_id, occ.seats.duplicate(), s.net_id, true, s.global_transform, peer)
	return s


# ------------------------------------------------------------------ 6. pads

func _check_pad(at: Vector3) -> void:
	print("vehicle pad:")
	var rt := _battle.mission as TVMissionRuntime
	var id := "%s:BUGGY" % PACK
	var pad := {"vehicle": id, "actor": "BaseObjectVehicleSpawnBuggy", "label": "TestPad", "pos": [at.x, at.y, at.z],
		"basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], "yaw": 0.0, "team_name": "", "spawn_s": PAD_SPAWN_S, "offset_m": PAD_LIFT_M,
		"abandon_radius_m": PAD_ABANDON_M, "abandon_s": PAD_ABANDON_S}
	var f := TVVehicleFleet.new(rt)
	f.build([], [pad])
	f.sync(at)
	var e: Dictionary = f.entries[0]
	var v := e.vehicle as Herc
	_expect(v != null and f.has_label("TestPadvehicle") and v.vehicle_id == id, "the pad holds its Rover, called TestPad + vehicle")
	for _f in SETTLE_PHYSICS_FRAMES:
		await get_tree().physics_frame
	_expect(v.global_position.distance_to(at) < PAD_MAX_OFF_M and VehicleOccupancy.of(v).is_empty(),
		"it stands on the pad, empty (%.1f m off)" % v.global_position.distance_to(at))
	var actors := {}
	f.apply_label_positions(actors)
	_expect(actors.has("TestPadvehicle"), "an objective marker finds the vehicle's place before it exists")
	_check_abandonment(f, e, v, at)
	await get_tree().physics_frame
	_expect(bool(e.dead) and int(e.respawn_at) > Time.get_ticks_msec() + int(PAD_SPAWN_S * 900.0),
		"destroyed, the pad builds the next only after its %.0f s" % PAD_SPAWN_S)
	f.sync(at)
	_expect(e.vehicle == v and bool(e.dead), "nothing appears meanwhile")
	e.respawn_at = 1
	f.sync(at)
	var next := e.vehicle as Herc
	_expect(not bool(e.dead) and next != null and next != v and next.alive, "after that time a new Rover stands on the pad")
	_battle.remove_vehicle(next.net_id)
	await _check_pad_station(at, id)


## Left empty beyond the abandon radius for the abandon time, the pad's vehicle is destroyed.
func _check_abandonment(f: TVVehicleFleet, e: Dictionary, v: Herc, at: Vector3) -> void:
	v.set_physics_process(false)
	var away := at + Vector3(PAD_ABANDON_M + 10.0, 0.0, 0.0)
	v.global_position = away
	f.sync(at)
	_expect(v.alive and int(e.abandoned_at) > 0, "left %.0f m from its pad, the empty vehicle starts to count down" % (PAD_ABANDON_M + 10.0))
	v.global_position = at + Vector3(0.0, PAD_LIFT_M, 0.0)
	f.sync(at)
	_expect(int(e.abandoned_at) == 0, "back on the pad the count stops")
	v.global_position = away
	f.sync(at)
	e.abandoned_at = Time.get_ticks_msec() - int(PAD_ABANDON_S * 1000.0) - 1
	f.sync(at)
	_expect(not v.alive and bool(e.dead), "after %.0f s it is destroyed" % PAD_ABANDON_S)


## The shared station code sells the pad's own vehicle to a soldier standing on it, once, while the pad is clear.
func _check_pad_station(at: Vector3, id: String) -> void:
	var st := TribesStations.new(_battle, [{"kind": "vehicle", "team": -1, "xf": Transform3D(Basis(), at), "node": null,
		"record": {"vehicle": id, "lift_m": PAD_LIFT_M}}])
	var soldier := _soldier()
	soldier.global_position = at + Vector3(0.0, 0.2, 0.0)
	soldier.velocity = Vector3.ZERO
	_expect(st.find_station(soldier) == 0, "the soldier stands on the pad station")
	_expect(st.make_station_vehicles(soldier, 0).size() == 1 and str(st.make_station_vehicles(soldier, 0)[0].id) == id, "it offers its one vehicle")
	var known := _battle.vehicles.keys()
	st.apply_vehicle_purchase(multiplayer.get_unique_id(), id, 0)
	soldier.global_position = at + Vector3(CLEAR_OF_PAD_M, 0.5, 0.0)          # the Rover appears on the soldier: he would board it by touch
	await get_tree().physics_frame
	var bought: Herc = null
	for net_id in _battle.vehicles:
		if not known.has(net_id):
			bought = _battle.vehicles[net_id]
	_expect(bought != null and bought.vehicle_id == id and VehicleOccupancy.of(bought).is_empty(), "buying puts an empty Rover on the pad")
	if bought == null:
		return
	bought.set_physics_process(false)             # it was shoved off the pad by the soldier standing on it: back to its place
	bought.global_position = at + Vector3(0.0, PAD_LIFT_M, 0.0)
	var count := _battle.vehicles.size()
	soldier.global_position = at + Vector3(0.0, 0.2, 0.0)
	st.apply_vehicle_purchase(multiplayer.get_unique_id(), id, 0)
	soldier.global_position = at + Vector3(CLEAR_OF_PAD_M, 0.5, 0.0)
	await get_tree().physics_frame
	_expect(_battle.vehicles.size() == count, "a second one does not fit on the busy pad")
	_battle.remove_vehicle(bought.net_id)
	st.free()


# ------------------------------------------------------------------ 7. goals and script spawns

func _check_goals(at: Vector3) -> void:
	print("vehicle goals:")
	var rt := _battle.mission as TVMissionRuntime
	rt.script_data["actors"] = rt.script_data.get("actors", {})
	var actors: Dictionary = rt.script_data.actors
	var a := at + Vector3(80, 0, -100)
	var b := at + Vector3(-80, 0, -250)
	actors["goalA"] = [a.x, a.y, a.z]
	actors["goalB"] = [b.x, b.y, b.z]
	var ahead := at + Vector3(0, 0, -GROUND_MOVE_M)
	actors["goalAhead"] = [ahead.x, ahead.y, ahead.z]
	_soldier().spawn_protection = 600.0
	_soldier().apply_spawn_protection()
	await _check_patrol(rt, at, a, b)
	await _check_move(rt, at, ahead)
	await _check_expel(rt, at)
	await _check_rook(rt, at)


func _goal_rec(key: String, label: String, at: Vector3) -> Dictionary:
	return {"vehicle": "%s:%s" % [PACK, key], "pos": [at.x, at.y, at.z], "basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], "label": label,
		"team_name": "", "ai_goals": false}


## VehiclePatrol: an allied Pod that is given a patrol goal is crewed and flies by both nodes.
func _check_patrol(rt: TVMissionRuntime, at: Vector3, a: Vector3, b: Vector3) -> void:
	var f := TVVehicleFleet.new(rt)
	var e := f.add_entry(_goal_rec("POD", "goal_pod", at))
	var goal := {"kind": "vehicle_patrol", "name": "patrol1", "priority": 60, "points": ["goalA", "goalB"], "once": false}
	_expect(f.apply_goal("goal_pod", "add", "patrol1", goal), "the goal finds the vehicle by its label")
	f.sync(at)
	var v := e.vehicle as Herc
	_expect(v != null and VehicleOccupancy.of(v).is_ai_piloted(), "given a goal, the parked allied Pod is crewed")
	var near_a := INF
	var near_b := INF
	var t := 0.0
	while t < PATROL_SECONDS and (near_a > PATROL_REACH_M or near_b > PATROL_REACH_M):
		await _wait(GOAL_STEP_SECONDS)
		t += GOAL_STEP_SECONDS
		f.sync(at)
		near_a = minf(near_a, v.global_position.distance_to(a))
		near_b = minf(near_b, v.global_position.distance_to(b))
	_expect(near_a <= PATROL_REACH_M and near_b <= PATROL_REACH_M,
		"the patrol passes both nodes (%.0f m and %.0f m at closest in %.0f s)" % [near_a, near_b, t])
	_battle.remove_vehicle(v.net_id)


## VehicleMoveTo: a crewed Tank drives to the node; the goal is achieved and dropped.
func _check_move(rt: TVMissionRuntime, at: Vector3, ahead: Vector3) -> void:
	var f := TVVehicleFleet.new(rt)
	var rec := _goal_rec("TANK", "goal_tank", at)
	rec["crewed"] = true
	var e := f.add_entry(rec)
	f.apply_goal("goal_tank", "add", "move1", {"kind": "vehicle_move", "name": "move1", "priority": 60, "dest": "goalAhead"})
	f.sync(at)
	var v := e.vehicle as Herc
	var t := 0.0
	var gap := INF
	while t < GROUND_MOVE_SECONDS and not (e.goals as Dictionary).is_empty():
		await _wait(GOAL_STEP_SECONDS)
		t += GOAL_STEP_SECONDS
		f.sync(at)
		gap = Vector2(v.global_position.x - ahead.x, v.global_position.z - ahead.z).length()
	_expect((e.goals as Dictionary).is_empty() and gap <= TVVehicleGoals.REACHED_GROUND_M * 1.5,
		"the Tank drove to the node and the goal is achieved (%.0f m off after %.0f s)" % [gap, t])
	_battle.remove_vehicle(v.net_id)


## VehicleExpellOccupant: the crewed Rover's pilot is put out, and the Rover stands parked and empty where it was.
func _check_expel(rt: TVMissionRuntime, at: Vector3) -> void:
	var f := TVVehicleFleet.new(rt)
	var rec := _goal_rec("BUGGY", "goal_rover", at)
	rec["crewed"] = true
	var e := f.add_entry(rec)
	f.sync(at)
	var v := e.vehicle as Herc
	_expect(v != null and VehicleOccupancy.of(v).is_ai_piloted(), "the supply rover is driven by its pilot")
	f.apply_goal("goal_rover", "add", "out", {"kind": "expel", "name": "out", "occupant": "nobody"})
	var parked := e.vehicle as Herc
	_expect(parked != v and VehicleOccupancy.of(parked).is_empty() and parked.global_position.distance_to(at) < PAD_MAX_OFF_M,
		"the expel goal puts the pilot out: the rover is parked and empty where it stood")
	_battle.remove_vehicle(parked.net_id)


## ActionSpawnRook of a Vehicle class: a crewed vehicle of the other side appears, in the air, called by the script's label.
func _check_rook(rt: TVMissionRuntime, at: Vector3) -> void:
	var p := at + Vector3(0, 40, 0)
	rt.apply_spawn_vehicle("VehiclePod", "script_rook", "TeamInfoBeagle0", [p.x, p.y, p.z])
	var found: Array = rt.fleet._named("script_rook")
	var v: Herc = (found[0] as Dictionary).vehicle if not found.is_empty() else null
	_expect(v != null and VehicleOccupancy.of(v).is_ai_piloted() and v.team == TVMissionRuntime.ENEMY_TEAM,
		"a script-spawned Pod is crewed, of the other team")
	if v != null:
		_expect(v.global_position.y > at.y + 20.0, "it appears at the script's air node (%.0f m up)" % (v.global_position.y - at.y))
		_battle.remove_vehicle(v.net_id)

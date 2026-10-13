extends Node
## Regression test of the Starsiege campaign features (headless):
##   godot --headless --audio-driver Dummy --path game res://tests/test_ss_campaign_features.tscn
## HA0  interiors placed by the map with collision; the player starts inside the mole tunnel; the
##      downed flyer is a parked Flyer.
## HA4  a laser turret fires at the player in range and hits; not out of its pitch arc, not out of
##      range; hit points, ammunition, rearm period and fire from the mission record; indestructible
##      perimeter walls; dominant and flyby cameras follow / watch their objects and skip back to the
##      player's view; the turret burns once under its fire threshold and is destructible.
## CC1  snowfall around the camera (map environment.weather); CD1 rain and Winter Wasteland's
##      blizzard decode into falling particles along the wind.
## HE1  the intro cut-scene flies the camera paths with the player's input locked, then returns control;
##      a second load skips it (fast-forward) and the mission's init() has run.
## Prints PASS/FAIL lines and "SS CAMPAIGN FEATURES: n failed".

const PHASES := ["HA0", "HA4", "HE1", "HE1-skip", "CC1"]
const TIME_SCALE := 4.0
const LOAD_TIMEOUT := 30.0
const TURRET := "MissionGroup/base/Turrets/turret1"
const PERIMETER := "MissionGroup/base/hPerimeter1"
## HA4.mis turret1: sustainable damage 8000, reload/rearm period 5 s; hPerimeter1 is indestructible.
const TURRET_RECORD_HIT_POINTS := 8000.0
const TURRET_REARM_PERIOD := 5.0
const CAMERA_TOLERANCE := 1.0
const IN_RANGE_DISTANCE := 300.0
const OUT_OF_RANGE_DISTANCE := 900.0
const OVERHEAD_HEIGHT := 200.0
const OBSERVE_SECONDS := 6.0
const CUTSCENE_TIMEOUT := 90.0
## HE1's intro: 0.5 s + paths 4, 5, 1, 2, 3 (6.75 + 5.5 + 8 + 7.5 s) + 5.5 s to lockUserInput(false).
const HE1_INTRO_SECONDS := 33.75
const HE1_INTRO_TOLERANCE := 4.0

var phase := -1
var battle: Node
var ms: StarsiegeMissionRuntime
var t := 0.0
var step := 0
var mark := 0.0
var failures := 0
var _turret: SSTurret
var _turret_hits := 0
var _pin := Vector3.INF     # the player is held here (a Herc in the air would fall)
var _flyby_from := Vector3.ZERO
var _burn_from := 0.0


func _ready() -> void:
	Engine.time_scale = TIME_SCALE
	_next_phase()


func _check(ok: bool, what: String) -> void:
	print("%s %s: %s" % ["PASS" if ok else "FAIL", PHASES[phase], what])
	if not ok:
		failures += 1


func _next_phase() -> void:
	if battle:
		battle.queue_free()
		battle = null
	ms = null
	phase += 1
	t = 0.0
	step = 0
	if phase >= PHASES.size():
		print("SS CAMPAIGN FEATURES: %d failed" % failures)
		get_tree().quit(1 if failures > 0 else 0)
		return
	var mid: String = PHASES[phase].split("-")[0]
	battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "mission_name": "starsiege:" + mid, "respawn": false,
		"roster": {1: {"name": "Tester", "vehicle": "starsiege:pi_eman", "team": 0, "loadout": []}}}
	get_tree().root.add_child.call_deferred(battle)


func _physics_process(delta: float) -> void:
	if phase >= PHASES.size() or battle == null:
		return
	t += delta
	if _pin != Vector3.INF and is_instance_valid(battle.player):
		battle.player.global_position = _pin
		battle.player.velocity = Vector3.ZERO
	if ms == null:
		ms = battle.get("mission") as StarsiegeMissionRuntime
		if ms == null and t > LOAD_TIMEOUT:
			_check(false, "mission loaded")
			_next_phase()
		return
	var done := false
	match PHASES[phase]:
		"HA0":
			done = _phase_interiors()
		"HA4":
			done = _phase_turret()
		"HE1":
			done = _phase_cutscene()
		"HE1-skip":
			done = _phase_skip()
		"CC1":
			done = _phase_weather()
	if done:
		_next_phase()


# ------------------------------------------------------------------ HA0: interiors, parked flyer

func _phase_interiors() -> bool:
	if t < 2.0:
		return false
	var bodies := _interior_bodies()
	_check(bodies.size() == 2, "2 interiors placed with trimesh collision (%d)" % bodies.size())
	var drop: Vector3 = SSObjectTree.position_of_def(ms.m.drop_points[0])
	var q := PhysicsRayQueryParameters3D.create(drop + Vector3.UP * 3.0, drop + Vector3.DOWN * 20.0, 0xFFFFFFFF,
		[battle.player.get_rid()])
	var hit: Dictionary = battle.get_world_3d().direct_space_state.intersect_ray(q)
	_check(not hit.is_empty() and hit.collider in bodies, "tunnel floor under the drop point collides")
	var p: Herc = battle.player
	_check(p != null and absf(p.global_position.y - drop.y) < 10.0, "player starts inside the tunnel (y %.1f, drop %.1f)" % [
		p.global_position.y if p else 0.0, drop.y])
	var fl = ms.tree.node_of(ms.ss_resolve("MissionGroup/flyerGroup/flyer1"))
	_check(fl is Flyer and (fl as Flyer).ai == null, "downed flyer spawned as a parked Flyer")
	return true


func _interior_bodies() -> Array:
	var out := []
	for c in battle.get_children():
		if c is StaticBody3D and String(c.name).begins_with("starsiege_itr_"):
			for col in c.get_children():
				if col is CollisionShape3D and col.shape is ConcavePolygonShape3D:
					out.append(c)
	return out


# ------------------------------------------------------------------ HA4: turret

func _phase_turret() -> bool:
	match step:
		0:
			if t < 1.0:
				return false
			_turret = ms.tree.node_of(ms.ss_resolve(TURRET)) as SSTurret
			_check(_turret != null and _turret.guns.size() == 2, "turret1 is an armed SSTurret")
			if _turret == null:
				return true
			battle.player.damaged.connect(func(_h, attacker): if attacker == _turret: _turret_hits += 1)
			_place_player(Vector3(IN_RANGE_DISTANCE, 0, 0), false)
			_begin_observing()
		1:
			if t - mark < OBSERVE_SECONDS:
				return false
			_check(_turret.shots_fired > 0 and _turret_hits > 0, "fires at and hits the player in range (%d shots, %d hits)" % [
				_turret.shots_fired, _turret_hits])
			_place_player(Vector3(10.0, OVERHEAD_HEIGHT, 0), true)
			_begin_observing()
		2:
			if t - mark < OBSERVE_SECONDS:
				return false
			_check(_turret.shots_fired == 0, "holds fire with the player overhead, out of the pitch arc (%d shots)" % _turret.shots_fired)
			_place_player(Vector3(OUT_OF_RANGE_DISTANCE, 0, 0), false)
			_begin_observing()
		3:
			if t - mark < OBSERVE_SECONDS:
				return false
			_check(_turret.shots_fired == 0, "holds fire out of range (%d shots)" % _turret.shots_fired)
			_check_turret_data()
			_check_indestructible()
			ms.ss_builtin("setdominantcamera", [ms.ss_resolve(TURRET), _player_id()])
			mark = t
			step = 4
		4:
			if t - mark < 0.5:
				return false
			_check_dominant_camera()
			ms.ss_builtin("setflybycamera", [_player_id(), -6, 40, 20])
			_flyby_from = ms.cutscene.camera.global_position
			mark = t
			step = 5
		5:
			if t - mark < 1.0:
				return false
			_check_flyby_camera()
			_press_skip()
			mark = t
			step = 6
		6:
			if t - mark < 0.5:
				return false
			_check(not ms.cutscene.is_running(), "skip leaves the object camera")
			_check(get_viewport().get_camera_3d() != ms.cutscene.camera, "player's camera back after the skip")
			_turret.hp = _turret.fire_threshold - 1.0
			_burn_from = _turret.hp
			mark = t
			step = 7
		7:
			if t - mark < 1.0:
				return false
			_check(_turret.is_burning() and _turret.hp < _burn_from - _turret.burn_rate * 0.5,
				"burns under its fire threshold (%.0f -> %.0f hp)" % [_burn_from, _turret.hp])
			_pin = Vector3.INF
			ms.ss_builtin("damageobject", [ms.ss_resolve(TURRET), 1e9])
			_check(not _turret.alive, "destroyed by damage")
			return true
	return false


## Hit points, ammunition and rearm period come from the mission record.
func _check_turret_data() -> void:
	var want := TURRET_RECORD_HIT_POINTS * ms.damage_factor
	_check(is_equal_approx(_turret.max_hp, want), "hit points from the record (%.0f, expected %.0f)" % [_turret.max_hp, want])
	_check(is_equal_approx(_turret.rearm_period, TURRET_REARM_PERIOD), "rearm period from the record (%.1f s)" % _turret.rearm_period)
	var gun: SSTurretGun = _turret.guns[0]
	_check(gun.weapon.ammo_max > 0 and gun.weapon.ammo < gun.weapon.ammo_max,
		"guns use ammunition (%d of %d left)" % [gun.weapon.ammo, gun.weapon.ammo_max])
	gun.weapon.ammo = 0
	_check(not gun.is_ready(), "an empty gun does not fire")
	gun.apply_rearm(TURRET_REARM_PERIOD * 0.5, _turret.rearm_period)
	_check(gun.is_empty(), "still empty before the rearm period")
	gun.apply_rearm(TURRET_REARM_PERIOD * 0.6, _turret.rearm_period)
	_check(gun.weapon.ammo == gun.weapon.ammo_max, "rearmed after the rearm period")


func _check_indestructible() -> void:
	var wall := ms.tree.node_of(ms.ss_resolve(PERIMETER)) as SSStructure
	if wall == null:
		_check(false, "perimeter wall built")
		return
	var before := wall.hp
	wall.apply_hit(0.0, 1e9, battle.player, wall.global_position)
	_check(wall.indestructible and wall.alive and wall.hp == before, "indestructible flag from the record")


func _player_id() -> int:
	return ms.tree.player_objs.keys()[0]


func _check_dominant_camera() -> void:
	var cs := ms.cutscene
	_check(cs.is_following() and get_viewport().get_camera_3d() == cs.camera, "dominant camera is current")
	var want := SSObjectCamera.make_point(_turret, SSObjectCamera.DOMINANT_OFFSET)
	_check(cs.camera.global_position.distance_to(want) < CAMERA_TOLERANCE, "dominant camera behind and above object0")
	var to_player: Vector3 = (battle.player.global_position - cs.camera.global_position).normalized()
	_check(-cs.camera.global_basis.z.dot(to_player) > 0.95, "dominant camera looks at object1")


func _check_flyby_camera() -> void:
	var cs := ms.cutscene
	_check(cs.is_following() and cs.camera.global_position.distance_to(_flyby_from) < 0.01,
		"flyby camera stays where it was placed")
	var aim := SSObjectCamera.make_point(battle.player, SSObjectCamera.OBJECT_OFFSET)
	_check(-cs.camera.global_basis.z.dot((aim - cs.camera.global_position).normalized()) > 0.99,
		"flyby camera watches its object")


func _press_skip() -> void:
	var ev := InputEventAction.new()
	ev.action = "ui_accept"
	ev.pressed = true
	Input.parse_input_event(ev)


func _begin_observing() -> void:
	_turret.shots_fired = 0
	mark = t
	step += 1


## Holds the player at `offset` from the turret; on the ground unless `airborne`.
func _place_player(offset: Vector3, airborne: bool) -> void:
	var p: Vector3 = _turret.global_position + offset
	if airborne:
		p = _turret.head_origin() + offset
	else:
		p.y = ms.ground_height_at(p) + 0.5
	_pin = p


# ------------------------------------------------------------------ HE1: cut-scene

func _phase_cutscene() -> bool:
	var cs := ms.cutscene
	match step:
		0:
			if ms.sim_time < 2.0:
				return false
			_check(cs != null and cs.is_flying(), "camera path flying")
			_check(cs != null and cs.input_locked and battle.pilot.process_mode == Node.PROCESS_MODE_DISABLED,
				"player input locked")
			_check(cs != null and get_viewport().get_camera_3d() == cs.camera, "cut-scene camera is current")
			step = 1
		1:
			if cs.is_running() and ms.sim_time < CUTSCENE_TIMEOUT:
				return false
			_check(not cs.is_running(), "cut-scene ends")
			_check(absf(ms.sim_time - HE1_INTRO_SECONDS) < HE1_INTRO_TOLERANCE,
				"original callback timing (%.1f s, expected %.2f)" % [ms.sim_time, HE1_INTRO_SECONDS])
			step = 2
			mark = t
		2:
			if t - mark < 0.5:
				return false
			_check(battle.pilot.process_mode == Node.PROCESS_MODE_INHERIT, "player controls back")
			_check(get_viewport().get_camera_3d() != cs.camera, "battle camera back")
			return true
	return false


func _phase_skip() -> bool:
	var cs := ms.cutscene
	match step:
		0:
			if ms.sim_time < 2.0:
				return false
			_check(cs.is_running(), "cut-scene running before the skip")
			_press_skip()
			step = 1
			mark = t
		1:
			if t - mark < 0.5:
				return false
			_check(not cs.is_running(), "ui_accept skips the cut-scene")
			_check(SSScript.truthy(ms.vm.globals.get("missionstart", false)), "the skipped script ran init()")
			_check(battle.pilot.process_mode == Node.PROCESS_MODE_INHERIT, "player controls back after the skip")
			return true
	return false


# ------------------------------------------------------------------ CC1: weather

func _phase_weather() -> bool:
	if t < 2.0:
		return false
	var weather: MapWeather = null
	for n in battle.find_children("*", "", true, false):
		if n is MapWeather:
			weather = n
	_check(weather != null and weather.kind == "snow" and weather.particles.emitting, "CC1 snowfall built")
	if weather:
		var cam := get_viewport().get_camera_3d()
		var want := cam.global_position - weather.velocity * weather.particles.lifetime * 0.5
		_check(weather.global_position.distance_to(want) < 1.0, "snow box follows the camera")
		_check(weather.particles.amount == MapWeather.SNOW_AMOUNT, "intensity 1 = full amount (%d)" % weather.particles.amount)
	_check_map_weather("starsiege:CD1", "rain", 0.5)
	_check_map_weather("starsiege:CTF_Winter_Wasteland", "snow", 1.0)
	return true


func _check_map_weather(map_id: String, kind: String, intensity: float) -> void:
	var w = MapBuilder.load_map(map_id).get("environment", {}).get("weather")
	var node := MapWeather.make(w) if w is Dictionary else null
	_check(node != null and node.kind == kind and is_equal_approx(node.intensity, intensity),
		"%s weather: %s at %.1f" % [map_id, kind, intensity])
	if node:
		_check(node.velocity.y < 0.0, "%s particles fall (%s m/s)" % [map_id, node.velocity])
		node.free()

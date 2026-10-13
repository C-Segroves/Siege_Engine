extends Node
## Tribes base equipment, second part (docs/TRIBES_BASE_EQUIPMENT.md), on real battles:
##   ballistics  turret and infantry mortar shells reach the ranges their data engages at (Tribes 2 projectile
##               gravity from Tribes2.exe, not the missions' 20 m/s2);
##   turret rig  a turret's shape turns, elevates and deploys while it engages (Tribes 2: with its barrel mounted);
##   lights      base objects with glowing parts cast light; it goes out without power and comes back with it;
##   fields      Tribes 2 force fields are closed while powered and open when their generators die;
##   radar       an enemy shows on a team's radar only inside its sensor net (sensor range / a soldier's sight);
##   deploy      deploy packs place their object where the soldier aims by the game's rules (range, surface,
##               slope, spacing, turret frequency, team limit); placed objects work (self-powered turrets, sensors);
##   movers      Tribes 1 doors open for a teammate and close again, open without power; elevators carry him.
## godot --headless --audio-driver Dummy --path game res://tests/tribes_fixtures_check.tscn [-- --shots=<dir>]
## (with a window, --shots saves a lit and an unpowered generator: the render check of the base lights)

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const T2_MAP := "tribes2:Katabatic"
const T1_MOVER_MAP := "tribes:Siege"
const T1_RADAR_MAP := "tribes:Raindance"
const SETTLE_FRAMES := 30
const TIME_SCALE := 4.0
const TARGET_VEHICLE := "es1:SCORPION"
const SPOT_SHARES := [0.3, 0.5, 0.7]
const SPOT_BEARINGS := 12
const ENGAGE_SECONDS := 6.0
const HOLD_STEP := 0.25
## A spot this far from every base object and sensor is outside every sensor net (metres).
const FAR_AWAY := 3000.0
const MORTAR_TEST_DISTANCE := 150.0

var _failures := 0
## Pitch the soldier aims at when deploying (the player controls set it every frame: set just before use).
var _deploy_pitch := 0.0
var _shots := ""
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	_guard.back_up()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	await get_tree().process_frame
	_check_ballistics()
	if not MapBuilder.load_map(T2_MAP).is_empty():
		await _check_t2()
	if not MapBuilder.load_map(T1_RADAR_MAP).is_empty():
		await _check_t1_radar()
	if not MapBuilder.load_map(T1_MOVER_MAP).is_empty():
		await _check_movers()
	Engine.time_scale = 1.0
	_guard.restore()
	print("tribes_fixtures_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	await get_tree().create_timer(s, true, true).timeout


func _start_battle(map_id: String) -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": map_id, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": []}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	Engine.time_scale = TIME_SCALE
	return battle


func _end(battle: Battle) -> void:
	Engine.time_scale = 1.0
	battle.queue_free()
	await _frames(4)


func _spawn_dummy(battle: Battle, team: int, at: Vector3) -> Herc:
	var h := battle.spawn_ai(TARGET_VEHICLE, team, Transform3D(Basis(), at), [], "Dummy", {"skill": 0.0})
	for c in h.get_children():
		if c is AIPilot:
			c.queue_free()
	h.end_spawn_protection()
	return h


# ------------------------------------------------------------------ ballistics (data)

func _check_ballistics() -> void:
	print("ballistics:")
	for pack in ["tribes", "tribes2"]:
		var blocks: Dictionary = TribesBase.load_specs(pack).get("blocks", {})
		for key in blocks:
			var t = blocks[key].get("turret")
			if not (t is Dictionary):
				continue
			var gun := TribesTurretGun.make(str(t.weapon))
			if gun.make_gravity() > 0.0:
				var reach := gun.make_speed() * gun.make_speed() / gun.make_gravity()
				_expect(reach >= float(t.range) * 0.95, "%s shells reach %.0f m (engages to %.0f m)" % [key, reach, float(t.range)])
				var dir := gun.make_fire_direction(Vector3.ZERO, Vector3(MORTAR_TEST_DISTANCE, 0, 0))
				_expect(dir != Vector3.ZERO or reach < MORTAR_TEST_DISTANCE, "%s has a firing solution at %.0f m" % [key, MORTAR_TEST_DISTANCE])
	var mortar := Packs.weapon("tribes2:MORTAR")
	if not mortar.is_empty():
		var g := float(mortar.projectile.gravity)
		_expect(g > 0.0 and g < 15.0, "Tribes 2 infantry mortar falls at the engine's projectile gravity (%.2f)" % g)


# ------------------------------------------------------------------ Tribes 2: rig, lights, fields, radar

func _check_t2() -> void:
	print("%s:" % T2_MAP)
	var battle := await _start_battle(T2_MAP)
	var base := TribesBase.of(battle)
	var turret := _find_turret(base)
	_expect(turret != null and turret.rig != null and turret.rig.can_aim(), "an armed turret has its turn / elevate rig")
	if turret:
		_expect(turret.rig.barrel != null, "the Tribes 2 turret's barrel is mounted")
		await _check_rig(battle, turret)
	var lit := base.objects.filter(func(o: TribesBaseObject) -> bool: return o.lights != null)
	_expect(not lit.is_empty(), "%d base objects glow and cast light" % lit.size())
	var fields := base.fixtures_of(TribesForceField)
	_expect(not fields.is_empty(), "%d force fields" % fields.size())
	_expect(fields.all(func(f: TribesForceField) -> bool: return f.is_closed() == f.powered), "fields are closed exactly while powered")
	await _check_power_cut(base, lit, fields)
	_check_permeability(fields)
	await _check_radar(battle, base, true)
	await _check_deployables_t2(battle, base)
	await _end(battle)


func _find_turret(base: TribesBase) -> TribesTurret:
	for o in base.objects_of(TribesBaseObject.KIND_TURRET):
		var t := o as TribesTurret
		if t and t.team == 0 and t.is_armed() and t.is_working():
			return t
	return null


func _check_rig(battle: Battle, turret: TribesTurret) -> void:
	var rest := _pose_of(turret.rig.base)
	var enemy := _spawn_dummy(battle, 1, turret.global_position + Vector3(0, 500, 0))
	var spot := false
	for share in SPOT_SHARES:
		for k in SPOT_BEARINGS:
			var p := turret.global_position + Vector3.FORWARD.rotated(Vector3.UP, TAU * k / SPOT_BEARINGS) * turret.engage_range * float(share)
			p.y = MapBuilder.ground_height(battle, p) + 0.5
			enemy.global_position = p
			if turret.is_in_arc(p - turret.make_muzzle()) and turret.has_line_of_sight(enemy):
				spot = true
				break
		if spot:
			break
	_expect(spot, "found a spot in the turret's sight")
	var hold := enemy.global_position
	for i in int(ENGAGE_SECONDS / HOLD_STEP):
		if is_instance_valid(enemy) and enemy.alive:
			enemy.global_position = hold      # a parked Herc slides down slopes out of the turret's sight
			enemy.velocity = Vector3.ZERO
		await _seconds(HOLD_STEP)
	_expect(turret.deployed >= 1.0 or not enemy.alive, "the turret deployed (%.2f; target %s, working %s, sees %s, enemy at %s)" % [
		turret.deployed, turret.target, turret.is_working(), turret.find_target(), enemy.global_position])
	_expect(_pose_of(turret.rig.base) != rest, "its shape turned toward the enemy")
	enemy.global_position += Vector3(0, 2000, 0)
	await _seconds(3.0)
	_expect(turret.deployed < 1.0, "with no target it folds again (%.2f)" % turret.deployed)


static func _pose_of(shape: ShapeInstance) -> Array:
	return shape.nodes.map(func(n: Node3D) -> Transform3D: return n.transform)


func _check_power_cut(base: TribesBase, lit: Array, fields: Array) -> void:
	var gens := base.objects_of(TribesBaseObject.KIND_GENERATOR)
	var always := base.grid.make_powered_groups([])      # providesPower groups keep their power
	var shown := lit.filter(func(o: TribesBaseObject) -> bool: return o.needs_power() and not always.has(o.power_group))
	shown.sort_custom(func(a: TribesBaseObject, b: TribesBaseObject) -> bool: return a.kind == "inventory" and b.kind != "inventory")
	var lit_image := await _shot_lights(base, shown, "lit")
	for g in gens:
		for i in 4:
			g.apply_hit(0.0, g.max_hp, null)
	await _seconds(TribesBase.STATE_CHECK_SECONDS * 2.0)
	var powered_lit := lit.filter(func(o: TribesBaseObject) -> bool: return o.needs_power() and not always.has(o.power_group))
	_expect(not powered_lit.is_empty() and powered_lit.all(func(o: TribesBaseObject) -> bool: return not o.lights.light.visible),
		"without power the base's lights go out (%d objects)" % powered_lit.size())
	var cut := fields.filter(func(f: TribesForceField) -> bool: return not always.has(f.power_group))
	_expect(cut.all(func(f: TribesForceField) -> bool: return not f.is_closed()), "without power the force fields open (%d)" % cut.size())
	var dark_image := await _shot_lights(base, shown, "unpowered")
	if lit_image and dark_image:
		_expect(_make_brightness(lit_image) > _make_brightness(dark_image), "render: the %s is brighter powered (%.3f) than unpowered (%.3f)" % [
			shown[0].display_name, _make_brightness(lit_image), _make_brightness(dark_image)])
	for g in gens:
		g.apply_repair(g.max_hp)
	await _seconds(TribesBase.STATE_CHECK_SECONDS * 2.0)
	_expect(powered_lit.any(func(o: TribesBaseObject) -> bool: return o.lights.light.visible), "power back: the lights come back on")
	_expect(fields.any(func(f: TribesForceField) -> bool: return f.is_closed()), "power back: the force fields close")


## Saves a picture of a base object that glows while powered (needs a window and --shots).
func _shot_lights(base: TribesBase, subjects: Array, tag: String) -> Image:
	if _shots == "" or DisplayServer.get_name() == "headless" or subjects.is_empty():
		return null
	var subject: Node3D = subjects[0]
	var view := SubViewport.new()
	view.size = Vector2i(640, 360)
	view.world_3d = base.get_viewport().world_3d
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var cam := Camera3D.new()
	view.add_child(cam)
	base.add_child(view)
	var box := TribesBaseObject.make_shape_bounds(subject, (subject as TribesBaseObject).shape)
	var centre := subject.global_transform * box.get_center()
	cam.global_position = _make_open_view(subject, centre, maxf(box.size.length() * 1.2, 4.0))
	cam.look_at(centre)
	cam.current = true
	await get_tree().create_timer(0.3, true, false, true).timeout
	await RenderingServer.frame_post_draw
	var image := view.get_texture().get_image()
	image.save_png("%s/tribes_base_%s.png" % [_shots, tag])
	view.queue_free()
	return image


static func _make_brightness(image: Image) -> float:
	var small := image.duplicate() as Image
	small.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	return small.get_pixel(0, 0).get_luminance()


## A camera spot `reach` metres from `centre` in the most open of eight directions (rooms have walls).
static func _make_open_view(subject: Node3D, centre: Vector3, reach: float) -> Vector3:
	var best := centre + Vector3(reach, 1.0, 0.0)
	var best_free := 0.0
	var space := subject.get_world_3d().direct_space_state
	for k in 8:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * k / 8.0)
		var q := PhysicsRayQueryParameters3D.create(centre + Vector3.UP, centre + Vector3.UP + dir * reach, 0xFFFFFFFF, [subject.get_rid()])
		var hit := space.intersect_ray(q)
		var free: float = reach if hit.is_empty() else (centre + Vector3.UP).distance_to(hit.position) * 0.9
		if free > best_free:
			best_free = free
			best = centre + Vector3.UP + dir * free
	return best


func _check_permeability(fields: Array) -> void:
	if not fields.is_empty():
		var ff := fields[0] as TribesForceField
		ff.apply_power(false)
		_expect(not ff.is_closed() and not ff.visible_box(), "a field without power is open and not drawn")
		ff.apply_power(true)
		_expect(ff.is_closed() and ff.visible_box(), "with power it is closed and drawn")
	for f in fields:
		var ff := f as TribesForceField
		_expect(ff.is_permeable_to(ff.team) == ff.team_permeable and ff.is_permeable_to(ff.team + 1) == ff.other_permeable,
			"field %s passes its team: %s, others: %s" % [ff.name, ff.team_permeable, ff.other_permeable])


## An enemy near a working team-0 sensor is on team 0's radar; far from every sensor (and, Tribes 2, out of
## every soldier's sight) he is not; teammates always are.
func _check_radar(battle: Battle, base: TribesBase, player_sensor: bool) -> void:
	var viewer := battle.player
	viewer.team = 0
	var sensor := _find_sensor(base)
	_expect(sensor != null, "team 0 has a working sensor")
	if sensor == null:
		return
	var enemy := _spawn_dummy(battle, 1, sensor.global_position + Vector3(0, 500, 0))
	var friend := _spawn_dummy(battle, 0, sensor.global_position + Vector3(FAR_AWAY, 500, 0))
	enemy.global_position = _make_spot_near(battle, sensor)
	await _seconds(TribesSensorNet.REFRESH_SECONDS * 3.0)
	_expect(TribesBase.is_on_radar(viewer, enemy), "an enemy %.0f m from the %s is on the radar" % [
		enemy.global_position.distance_to(sensor.global_position), sensor.display_name])
	enemy.global_position = sensor.global_position + Vector3(-FAR_AWAY, 300, -FAR_AWAY)
	await _seconds(TribesSensorNet.REFRESH_SECONDS * 3.0)
	_expect(not TribesBase.is_on_radar(viewer, enemy), "far from every sensor he is not")
	_expect(TribesBase.is_on_radar(viewer, friend), "a teammate always is")
	if player_sensor:
		viewer.global_position = sensor.global_position + Vector3(-FAR_AWAY, 300, -FAR_AWAY)
		enemy.global_position = viewer.global_position - viewer.aim_basis().z * 40.0
		await _seconds(TribesSensorNet.REFRESH_SECONDS * 3.0)
		_expect(TribesBase.is_on_radar(viewer, enemy) or not viewer.alive, "Tribes 2: a soldier in sight of a teammate is on the radar")
	enemy.queue_free()
	friend.queue_free()


func _find_sensor(base: TribesBase) -> TribesBaseObject:
	for o in base.objects:
		if o.team == 0 and o.is_working() and o.kind == TribesBaseObject.KIND_SENSOR:
			return o
	return null


## A spot within the sensor's range and in its sight (just beside it).
func _make_spot_near(battle: Battle, sensor: TribesBaseObject) -> Vector3:
	var reach := float(sensor.spec.sensor.range) * 0.3
	var p := sensor.global_position + Vector3(reach, 0, 0)
	p.y = maxf(MapBuilder.ground_height(battle, p), sensor.global_position.y) + 3.0
	return p


# ------------------------------------------------------------------ Tribes 1 radar

func _check_t1_radar() -> void:
	print("%s radar:" % T1_RADAR_MAP)
	var battle := await _start_battle(T1_RADAR_MAP)
	await _check_radar(battle, TribesBase.of(battle), false)
	await _check_deployables_t1(battle, TribesBase.of(battle))
	await _end(battle)


# ------------------------------------------------------------------ Tribes 1 doors and elevators

func _check_movers() -> void:
	print("%s:" % T1_MOVER_MAP)
	var battle := await _start_battle(T1_MOVER_MAP)
	var base := TribesBase.of(battle)
	var doors := base.fixtures_of(TribesDoor)
	var lifts := base.fixtures_of(TribesElevator)
	_expect(not doors.is_empty() and not lifts.is_empty(), "%d doors and %d elevators" % [doors.size(), lifts.size()])
	var s := battle.player as Infantry
	var door := _powered(doors) as TribesDoor
	if door and s:
		_expect(not door.is_open(), "a powered door rests closed")
		_expect(door.is_trigger_opened(), "Siege's doors open by their GroupTrigger (triggerOpen)")
		s.team = door.team
		s.global_position = door.global_position + Vector3.UP * 0.5
		await _seconds(0.5)
		_expect(not door.is_open() or door.is_in_trigger(s), "touching a trigger-opened door does not open it")
		s.global_position = (door._triggers[0][0] as Transform3D).origin
		await _seconds(0.5)
		_expect(door.is_open(), "a teammate inside its trigger opens it")
		s.global_position += Vector3(0, 0, 40)
		await _seconds(1.0)
		_expect(not door.is_open(), "and it closes when he leaves the trigger")
		await _check_door_damage(door)
	var lift := _powered(lifts) as TribesElevator
	if lift and s:
		s.team = lift.team
		s.global_position = lift.global_position + Vector3.UP * 0.5
		await _seconds(1.0)
		_expect(lift.goal > 0, "an elevator moves when a teammate steps on it")
	for g in base.objects_of(TribesBaseObject.KIND_GENERATOR):
		g.apply_hit(0.0, g.max_hp * 4.0, null)
	await _seconds(TribesBase.STATE_CHECK_SECONDS * 2.0 + 0.5)
	var other := doors.filter(func(d: TribesDoor) -> bool: return d != door and not d.stopped and d.power_group >= 0)
	if not other.is_empty():
		_expect((other[0] as TribesDoor).is_open(), "without power a door opens")
	await _end(battle)


## A destroyable door: plasma hurts it at its $DoorScale, bullets not at all; destroyed it stops where it is.
func _check_door_damage(door: TribesDoor) -> void:
	_expect(door.max_hp > 0.0, "the door is destroyable (%.0f hp)" % door.max_hp)
	DamageTypes.apply_typed_hit(door, [0.0, door.max_hp * 10.0, null, door.global_position], "bullet")
	_expect(not door.stopped and is_equal_approx(door.hp, door.max_hp), "bullets do not hurt it ($DoorScale 0)")
	DamageTypes.apply_typed_hit(door, [0.0, door.max_hp * 2.0, null, door.global_position], "missile")
	_expect(door.stopped, "a heavy missile hit destroys it: it stops")


static func _powered(list: Array) -> Node:
	for m in list:
		if m.powered and m.waypoints.size() > 1:
			return m
	return null


# ------------------------------------------------------------------ deployables

## Stands the player on open ground (far from the bases) looking down `pitch` radians at the ground ahead.
func _stand_for_deploy(battle: Battle, s: Infantry, at: Vector3, pitch: float) -> void:
	s.global_position = Vector3(at.x, MapBuilder.ground_height(battle, at) + 0.2, at.z)
	s.velocity = Vector3.ZERO
	_deploy_pitch = pitch
	await _frames(4)


func _aim_down(s: Infantry) -> void:
	s.rotation.y = 0.0
	s.pitch = _deploy_pitch


func _deploy(battle: Battle, s: Infantry, pack_id: String) -> String:
	s.kit.pack_id = pack_id
	_aim_down(s)
	var before := TribesBase.of(battle).objects.size()
	var rules := TribesDeployables.rules_of(pack_id)
	var check: Dictionary = TribesDeployRules.make(rules).make_placement(s, [], 8)
	if str(check.get("error", "")) != "":
		print("    (%s refused: %s)" % [pack_id, check.error])
	_aim_down(s)
	TribesDeployables.of(battle).apply_deploy(1, s)
	await _frames(2)
	return "placed" if TribesBase.of(battle).objects.size() > before else "refused"


func _find_open_ground(battle: Battle, base: TribesBase) -> Vector3:
	var centre := Vector3.ZERO
	for o in base.objects:
		centre += o.global_position
	centre /= maxf(1.0, base.objects.size())
	for r in [300.0, 400.0, 500.0, 200.0, 600.0, 100.0]:
		for k in 16:
			var p: Vector3 = centre + Vector3.FORWARD.rotated(Vector3.UP, TAU * k / 16.0) * float(r)
			p.y = MapBuilder.ground_height(battle, p)
			if _is_flat_around(battle, p):
				return p
	return centre


## Flat where the soldier stands and on the ground he aims at (ahead, -z) and beside it (the later spots).
static func _is_flat_around(battle: Battle, p: Vector3) -> bool:
	for off in [Vector3.ZERO, Vector3(0, 0, -2), Vector3(10, 0, -2), Vector3(-30, 0, -2), Vector3(40, 0, -2), Vector3(45, 0, 4)]:
		if _ground_normal(battle, p + off).dot(Vector3.UP) < 0.95:
			return false
	return true


static func _ground_normal(battle: Battle, p: Vector3) -> Vector3:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 20.0, p - Vector3.UP * 20.0)
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(q)
	return hit.normal if hit else Vector3.UP


func _check_deployables_t1(battle: Battle, base: TribesBase) -> void:
	print("tribes deployables:")
	var s := battle.player as Infantry
	var spot := _find_open_ground(battle, base)
	await _stand_for_deploy(battle, s, spot, -0.9)
	_expect(await _deploy(battle, s, "tribes:TURRET_PACK") == "placed", "a remote turret is placed where the soldier aims")
	var turret := base.objects[base.objects.size() - 1]
	_expect(turret is TribesTurret and turret.is_working() and turret.team == s.team, "it works on its own power, for his team")
	_expect(s.kit.pack_id == "", "the turret pack is used up")
	await _stand_for_deploy(battle, s, spot + Vector3(4, 0, 0), -0.9)
	_expect(await _deploy(battle, s, "tribes:TURRET_PACK") == "refused", "a second remote turret 4 m away: frequency overload")
	await _stand_for_deploy(battle, s, spot + Vector3(30, 0, 0), 0.6)
	_expect(await _deploy(battle, s, "tribes:PULSE_SENSOR_PACK") == "refused", "aiming at the sky: out of range")
	_deploy_pitch = -0.9
	_expect(await _deploy(battle, s, "tribes:PULSE_SENSOR_PACK") == "placed", "a pulse sensor is placed")
	var sensor := base.objects[base.objects.size() - 1]
	_expect(sensor.is_in_group(TribesBase.SENSOR_GROUP) and sensor.is_working(), "the deployed pulse sensor senses for the team")
	await _stand_for_deploy(battle, s, spot + Vector3(-30, 0, 0), -0.9)
	_expect(await _deploy(battle, s, "tribes:DEPLOYABLE_INV_PACK") == "placed", "a deployable inventory station is placed")
	var stations: TribesStations = battle.get_node("Stations")
	_expect(stations.stations.any(func(st: Dictionary) -> bool: return st.get("object") == base.objects[base.objects.size() - 1]),
		"it works as an inventory station")


func _check_deployables_t2(battle: Battle, base: TribesBase) -> void:
	print("tribes2 deployables:")
	var s := battle.player as Infantry
	var spot := _find_open_ground(battle, base)
	await _stand_for_deploy(battle, s, spot, -0.9)
	_expect(await _deploy(battle, s, "tribes2:TURRET_OUTDOOR_DEPLOYABLE") == "placed", "a landspike turret is placed on terrain")
	var turret := base.objects[base.objects.size() - 1]
	_expect(turret is TribesTurret and (turret as TribesTurret).is_armed() and turret.is_working(), "it is armed and self-powered")
	await _stand_for_deploy(battle, s, spot + Vector3(10, 0, 0), -0.9)
	_expect(await _deploy(battle, s, "tribes2:TURRET_OUTDOOR_DEPLOYABLE") == "refused", "another 10 m away: interference (space radius)")
	await _stand_for_deploy(battle, s, spot + Vector3(40, 0, 0), -0.9)
	_expect(await _deploy(battle, s, "tribes2:TURRET_INDOOR_DEPLOYABLE") == "refused", "a spider clamp turret needs a building")
	s.kit.pack_id = "tribes2:MOTION_SENSOR_DEPLOYABLE"
	_aim_down(s)
	TribesDeployables.of(battle).apply_deploy(1, s)
	await _frames(2)
	_expect(s.kit.pack_id == "tribes2:MOTION_SENSOR_DEPLOYABLE", "a motion sensor pack holds a second sensor (maxSensors)")
	await _stand_for_deploy(battle, s, spot + Vector3(45, 0, 6), -0.9)
	_aim_down(s)
	TribesDeployables.of(battle).apply_deploy(1, s)
	await _frames(2)
	_expect(s.kit.pack_id == "", "after the second it is used up")
	var interior := _find_interior_floor(battle)
	if interior != Vector3.INF:
		s.global_position = interior
		s.velocity = Vector3.ZERO
		_deploy_pitch = -0.9
		await _frames(4)
		var r := await _deploy(battle, s, "tribes2:TURRET_INDOOR_DEPLOYABLE")
		_expect(r == "placed" and base.objects[base.objects.size() - 1].datablock.contains("floor"),
			"a spider clamp turret is placed on a building floor (floor variant): %s" % r)


## A spot standing on a building floor (inside an interior with room above), or Vector3.INF.
func _find_interior_floor(battle: Battle) -> Vector3:
	var space := battle.get_world_3d().direct_space_state
	for n in battle.get_tree().get_nodes_in_group(MapBuilder.INTERIOR_GROUP):
		var c: Vector3 = (n as Node3D).global_position
		for dx in [0.0, 3.0, -3.0]:
			var top := c + Vector3(dx, 6.0, 0.0)
			var q := PhysicsRayQueryParameters3D.create(top, top - Vector3.UP * 12.0)
			var hit := space.intersect_ray(q)
			if hit and (hit.collider as Node).is_in_group(MapBuilder.INTERIOR_GROUP) and hit.normal.dot(Vector3.UP) > 0.95:
				return hit.position + Vector3.UP * 0.2
	return Vector3.INF

extends Node
## Infantry, second wave (docs/formats/tribes_infantry.md sections 6-7, tribes_vehicles.md section 6):
##   1 seat switching (seat_next) and gunner seats (TurretCrew: the Beowulf turret and the Thundersword belly
##     turret crewed by a second soldier while the pilot drives; the pilot fires when nobody guns);
##   2 armed passengers firing their own weapons within the seat's view arc (Havoc, LPC);
##   3 the jump key gets out of a Tribes vehicle (and not out of a Herc);
##   4 fall damage from the armour data;
##   5 grenades, mines, repair kits and backpacks (energy, repair, shield, ammo, jammer), the new actions;
##   6 per-damage-type armour scales;
##   7 infantry bots: spawn per config, move, board an empty vehicle and drive it with the AI pilot, get out of
##     a crippled one, look for a station to refill.
##   godot --headless --audio-driver Dummy --path game res://tests/infantry2_check.tscn [-- --shots=<dir>]
## --shots (needs a window): infantry2_*.png. LAN replication: tests/e2e_driver.gd lan_host / lan_join --bots=4.

const MAP := "tribes2:Katabatic"
const SETTLE_FRAMES := 20
const BOTS := 4
## Bots on foot must cover this path in this time (a soldier runs 11 m/s).
const BOT_MIN_PATH := 5.0
const BOT_MOVE_SECONDS := 6.0
const BOT_SAMPLE_SECONDS := 0.5
const NEW_ACTIONS := ["seat_next", "grenade_throw", "mine_drop", "pack_use", "repair_kit_use"]

var _failures := 0
var _shots := ""
## Test sites: candidates on rings of SITE_RING_STEP_M, SITE_DIRECTIONS per ring; level = within SITE_LEVEL_M over
## SITE_CLEAR_M ahead.
const SITE_RINGS := [0, 1, 2, 3, 4, 5, 6]
const SITE_DIRECTIONS := 8
const SITE_RING_STEP_M := 25.0
const SITE_CLEAR_M := 30.0
const SITE_LEVEL_M := 1.5


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	await get_tree().process_frame
	_check_data()
	_check_bindings()
	var battle := await _start_battle()
	_hold_bots(battle, true)   # sections 1-6 test one soldier: the bots' fight must not reach him (section 7 frees them)
	await _check_gunner_seats(battle)
	await _check_armed_passengers(battle)
	await _check_jump_out(battle)
	await _check_fall_damage(battle)
	await _check_grenades(battle)
	await _check_packs(battle)
	_check_damage_scales(battle)
	_hold_bots(battle, false)
	await _check_bots(battle)
	print("infantry2_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
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


func _shot(battle: Battle, tag: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await _frames(4)
	await RenderingServer.frame_post_draw
	var path := "%s/infantry2_%s.png" % [_shots, tag]
	battle.get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()   # deliver it now, not on the next idle frame
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()


# ------------------------------------------------------------------ data

func _check_data() -> void:
	print("data:")
	var g1 := InfantryGear.item("tribes:GRENADE")
	var g2 := InfantryGear.item("tribes2:GRENADE")
	_expect(is_equal_approx(float(g1.get("fuse_s", 0)), 2.0) and is_equal_approx(float(g2.get("fuse_s", 0)), 1.5),
		"grenade fuses: T1 Handgrenade 2 s, T2 GrenadeThrown 1.5 s")
	_expect(is_equal_approx(float(g1.get("damage", 0)), 1500.0) and str(g1.get("damage_type")) == "shrapnel",
		"T1 grenade 0.5 x 3000, shrapnel")
	var mine := InfantryGear.item("tribes2:MINE")
	_expect(is_equal_approx(float(mine.get("proximity", 0)), 2.5) and is_equal_approx(float(mine.get("arm_s", 0)), 2.2),
		"T2 mine: proximity 2.5 m, armTime 2.2 s")
	var light := InfantryCatalog.armor("tribes2:LIGHT")
	_expect(int(light.hand_items.get("tribes2:GRENADE", 0)) == 5 and (light.default_items as Dictionary).has("tribes2:REPAIR_KIT"),
		"T2 scout: 5 grenades, spawn kit has a repair kit")
	_expect(InfantryGear.packs_of(light).has("tribes2:SHIELD_PACK") and not InfantryGear.packs_of(light).has("tribes2:CLOAKING_PACK"),
		"offered packs: the modelled ones (shield yes, cloak recorded only)")
	_expect(is_equal_approx(float(light.fall_min_speed), 45.0) and is_equal_approx(float(light.fall_damage_per_mps), 12.0),
		"T2 fall: minImpactSpeed 45, speedDamageScale 0.004 x 3000")
	_expect(is_equal_approx(float(InfantryCatalog.armor("tribes:LIGHT").fall_min_speed), 25.0), "T1 fall: minDamageSpeed 25")
	_expect(is_equal_approx(float(light.damage_scale.get("bullet", 0)), 1.2)
		and is_equal_approx(float(InfantryCatalog.armor("tribes:HEAVY").damage_scale.get("bullet", 0)), 0.6),
		"damage scales: T2 light bullet 1.2, T1 heavy bullet 0.6")
	_expect(str(Packs.weapon("tribes:CHAINGUN").get("damage_type")) == "bullet"
		and str(Packs.weapon("tribes2:SPINFUSOR").get("damage_type")) == "disc", "weapons carry their damage type")
	_expect(VehicleSeats.make_role("tribes2:THUNDERSWORD", 1) == VehicleSeats.GUNNER
		and VehicleSeats.make_role("tribes2:THUNDERSWORD", 2) == VehicleSeats.ARMED
		and VehicleSeats.make_role("tribes2:HAVOC", 3) == VehicleSeats.ARMED
		and VehicleSeats.make_role("tribes:LAPC", 1) == VehicleSeats.ARMED
		and VehicleSeats.make_role("tribes2:BEOWULF", 1) == VehicleSeats.GUNNER, "seat roles")


func _check_bindings() -> void:
	print("bindings:")
	for action in NEW_ACTIONS:
		_expect(InputMap.has_action(action) and InputMap.action_get_events(action).size() >= 2, "%s bound (keyboard + pad)" % action)
		_expect(BindingContexts.CONTEXTS.infantry.has(action), "%s live on foot" % action)
	for context in ["infantry", "battle"]:
		var seen := {}
		var clash := ""
		for action in BindingContexts.CONTEXTS[context]:
			for ev in InputMap.action_get_events(action) if InputMap.has_action(action) else []:
				var key := ev.as_text() if not (ev is InputEventJoypadMotion) else "axis%d%s" % [ev.axis, signf(ev.axis_value)]
				if seen.has(key) and seen[key] != action and context == "infantry":
					clash = "%s / %s" % [seen[key], action]
				seen[key] = action
		_expect(clash == "", "no default binding twice in the %s context %s" % [context, clash])


# ------------------------------------------------------------------ battle

func _start_battle() -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 500, "ai": [], InfantryBots.CONFIG_KEY: BOTS}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _spawn_parked(battle: Battle, vehicle_id: String, at: Vector3, team := 0) -> Herc:
	var id := battle.spawner.allocate_id()
	at.y = MapBuilder.ground_height(battle, at)
	battle.send_spawn({"net_id": id, "vehicle": vehicle_id, "team": team, "owner": 0,
		"xf": Transform3D(Basis(), at), "loadout": [], "name": vehicle_id, "ai": {}, "parked": true})
	return battle.vehicles.get(id)


func _touch(s: Infantry, v: Herc) -> void:
	s.global_position = v.global_position + Vector3(BoardingRules.make_hull_radius(v) + 0.2, 0.3, 0)
	s.velocity = Vector3.ZERO


## A quiet spot far from the bots for the vehicle checks: the first of a ring of candidates around `offset` from the
## player whose ground stays level for SITE_CLEAR_M metres ahead (-z: where the grenade and mine checks throw), so a
## changed spawn point never puts the site at the foot of a slope.
func _test_site(battle: Battle, offset: Vector3) -> Vector3:
	var origin := (battle.player as Infantry).global_position + offset
	for ring in SITE_RINGS:
		for k in SITE_DIRECTIONS:
			var a := TAU * float(k) / SITE_DIRECTIONS
			var p: Vector3 = origin + Vector3(cos(a), 0, sin(a)) * ring * SITE_RING_STEP_M
			if not battle.bounds.bounds.is_outside(p) and _is_level_ahead(battle, p):   # outside, BattleBounds would hurt the soldier
				p.y = MapBuilder.ground_height(battle, p)
				return p
	origin.y = MapBuilder.ground_height(battle, origin)
	return origin


## Level ground with a real floor under every probe (a physics ray finds it within SITE_LEVEL_M of the terrain
## height: no terrain hole, no interior roof, inside the built terrain).
static func _is_level_ahead(battle: Battle, p: Vector3) -> bool:
	var lo := INF
	var hi := -INF
	for d in range(0, int(SITE_CLEAR_M) + 1, 2):
		for side in [-3.0, 0.0, 3.0]:
			var q := p + Vector3(side, 0, -d)
			var h := MapBuilder.ground_height(battle, q)
			var hit := battle.get_world_3d().direct_space_state.intersect_ray(
				PhysicsRayQueryParameters3D.create(Vector3(q.x, h + 50.0, q.z), Vector3(q.x, h - 50.0, q.z)))
			if hit.is_empty() or absf(float(hit.position.y) - h) > SITE_LEVEL_M:
				return false
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return hi - lo <= SITE_LEVEL_M


func _check_gunner_seats(battle: Battle) -> void:
	print("1 seat switching and gunner seats:")
	var s := battle.player as Infantry
	var tank := _spawn_parked(battle, "tribes2:BEOWULF", _test_site(battle, Vector3(80, 0, 0)))
	await _frames(3)
	_touch(s, tank)
	await _frames(3)
	var occ := VehicleOccupancy.of(tank)
	_expect(occ.pilot() == 1 and battle.player == tank, "touching the Beowulf: driver seat")
	_press("seat_next")
	await _frames(3)
	var crew := TurretCrew.find(tank)
	_expect(occ.seat_of(1) == 1 and crew != null and crew.gunner == 1, "seat_next: the turreteer seat (gunner %d)" % (crew.gunner if crew else 0))
	_expect(battle.pilot is GunnerPilot and battle.player == tank, "gunner controls on the tank")
	_expect(_last_message(battle) == "Gunner - Beowulf turret", "the gunner seat is announced ('%s')" % _last_message(battle))
	var driver := battle.spawn_soldier_for(77, 0, "Driver", Transform3D(Basis(), tank.global_position + Vector3(0, 0, 30)))
	await _frames(2)
	battle.occupancy.apply_board(77, tank, 0)
	await _frames(2)
	_expect(occ.pilot() == 77 and tank.owner_peer == 77, "a second soldier drives (owner peer 77)")
	var gp := battle.pilot as GunnerPilot
	gp.set_physics_process(false)
	crew.torso_target = 1.2
	crew.pitch_target = 0.3
	crew.apply_fire_groups(true, false)
	tank.throttle = 0.7
	tank.torso_target = -1.0   # the driver's own aim: the gunner wins
	await _seconds(0.6)
	_expect(absf(tank.torso_yaw - 1.2) < 0.05, "the turret follows the gunner (%.2f)" % tank.torso_yaw)
	_expect(tank.weapons.any(func(w: Weapon) -> bool: return w.trigger and w.group == 0), "the gunner fires the chaingun")
	_expect(tank.speed > 1.0, "the driver keeps driving (%.1f m/s)" % tank.speed)
	await _shot(battle, "gunner_beowulf")
	_press("seat_next")   # seat 0 is taken: no free seat after the gunner's -> stays
	await _frames(3)
	_expect(occ.seat_of(1) == 1, "seat_next with no free seat keeps the seat")
	crew.apply_idle()
	battle.occupancy.apply_exit(1, tank)
	await _frames(3)
	_expect(crew.gunner == VehicleOccupancy.EMPTY and battle.player == s, "out: the gunner seat is empty, back on foot")
	tank.torso_target = -1.0
	await _seconds(0.6)
	_expect(absf(tank.torso_yaw + 1.0) < 0.05, "nobody guns: the driver aims the turret again (pilot-fires fallback)")
	battle.occupancy.apply_exit(77, tank)
	await _check_bomber_gunner(battle, s)


func _check_bomber_gunner(battle: Battle, s: Infantry) -> void:
	var bomber := _spawn_parked(battle, "tribes2:THUNDERSWORD", _test_site(battle, Vector3(-80, 0, 40)))
	await _frames(3)
	battle.occupancy.apply_board(1, bomber, 1)
	await _frames(3)
	var crew := TurretCrew.find(bomber)
	_expect(crew != null and crew.gunner == 1 and battle.pilot is GunnerPilot, "Thundersword bombardier seat: the belly turret")
	_expect(_last_message(battle).begins_with("Gunner - Thundersword"), "the bombardier seat is announced ('%s')" % _last_message(battle))
	crew.torso_target = PI * 0.5
	crew.pitch_target = -0.8
	var aim := -bomber.aim_basis().z
	_expect(aim.y < -0.5, "the belly guns aim where the bombardier looks (down %.2f)" % aim.y)
	var range := VehicleSeats.make_gunner_pitch_range(bomber)
	_expect(is_equal_approx(rad_to_deg(range.y), 0.0) and is_equal_approx(rad_to_deg(range.x), -90.0),
		"belly turret arc thetaMin 90 / thetaMax 180: level to straight down")
	await _shot(battle, "gunner_thundersword")
	battle.occupancy.apply_exit(1, bomber)
	await _frames(3)
	s.global_position += Vector3(0, 0, -20)


func _check_armed_passengers(battle: Battle) -> void:
	print("2 armed passengers:")
	var s := battle.player as Infantry
	var havoc := _spawn_parked(battle, "tribes2:HAVOC", _test_site(battle, Vector3(0, 0, 90)))
	await _seconds(4.2)   # past the remount delay of earlier exits
	_touch(s, havoc)
	await _frames(3)
	_press("seat_next")
	await _frames(3)
	var occ := VehicleOccupancy.of(havoc)
	_expect(occ.seat_of(1) == 1 and battle.player == s and s.stowed and battle.pilot is InfantryPilot,
		"Havoc seat 1: the soldier keeps his own controls")
	_expect(s.seat != null and s.seat.is_armed() and s.owner_peer == 1, "an armed passenger seat; his input reaches his soldier")
	_expect(_last_message(battle).begins_with("Passenger - Havoc") and not _last_message(battle).contains("piloting"),
		"the passenger seat is announced ('%s')" % _last_message(battle))
	var centre := s.seat.make_center_yaw()
	_expect(absf(wrapf(s.make_allowed_yaw(centre + PI) - centre, -PI, PI)) <= InfantrySeat.ARC_HALF + 0.01,
		"aim outside the seat's arc is held at its edge")
	var w := s.current_weapon()
	s.torso_target = centre
	await _frames(2)
	w.trigger = true
	await _frames(3)
	w.trigger = false
	_expect(w.cooldown > 0.0 or w.ammo < w.ammo_max, "fires his %s from the seat" % w.display_name)
	var eye := s.aim_origin()
	_expect(eye.distance_to(havoc.global_position) < 12.0, "rides at his seat (%.1f m from the hull origin)" % eye.distance_to(havoc.global_position))
	await _shot(battle, "havoc_passenger")
	battle.occupancy.apply_exit(1, havoc)
	await _frames(3)
	var lapc := _spawn_parked(battle, "tribes:LAPC", _test_site(battle, Vector3(-60, 0, 90)))
	await _frames(3)
	var rider := battle.spawn_soldier_for(79, 0, "Rider", Transform3D(Basis(), lapc.global_position + Vector3(0, 0, 25)))
	rider.apply_armor("tribes2:MEDIUM", ["tribes2:CHAINGUN"])
	await _frames(2)
	battle.occupancy.apply_board(79, lapc, 2)
	await _frames(2)
	_expect(rider.seat != null and rider.seat.is_armed() and rider.owner_peer == 79, "LPC passenger (T1: keeps his weapon) is armed")
	battle.occupancy.apply_exit(79, lapc)
	rider.global_position += Vector3(0, 0, 300)


func _check_jump_out(battle: Battle) -> void:
	print("3 jump to get out:")
	var s := battle.player as Infantry
	var scout := _spawn_parked(battle, "tribes2:SHRIKE", _test_site(battle, Vector3(40, 0, -90)))
	await _frames(3)
	_touch(s, scout)
	await _frames(3)
	_expect(battle.player == scout, "flying the Shrike")
	_press("ascend")
	await _frames(3)
	_expect(battle.player == s and not s.stowed, "the jump key gets out of a Tribes vehicle")
	var herc := _spawn_parked(battle, "es1:RAPTOR", _test_site(battle, Vector3(-40, 0, -90)))
	await _frames(3)
	s.global_position = herc.global_position + herc.global_basis.x.normalized() * (BoardingRules.make_hull_radius(herc) + 1.5) + Vector3.UP * 0.3
	s.velocity = Vector3.ZERO
	await _seconds(0.3)   # past the enter / exit debounce
	_press("vehicle_enter_exit")
	await _frames(3)
	_expect(battle.player == herc, "boards a Raptor through the hatch")
	await _seconds(0.3)
	_press("ascend")
	await _frames(3)
	_expect(battle.player == herc, "the jump key does not leave a Herc")
	await _seconds(0.3)
	_press("vehicle_enter_exit")
	await _frames(3)
	_expect(battle.player == s, "vehicle_enter_exit still leaves it")


func _check_fall_damage(battle: Battle) -> void:
	print("4 fall damage:")
	var s := battle.player as Infantry
	battle.pilot.set_physics_process(false)
	s.end_spawn_protection()
	var p := _test_site(battle, Vector3(0, 0, -150))
	s.global_position = p + Vector3.UP * 0.5
	s.velocity = Vector3.ZERO
	await _seconds(0.5)
	var hp0 := float(s.components[0].hp)
	s.global_position = p + Vector3.UP * 1.5
	await _seconds(0.8)
	_expect(is_equal_approx(float(s.components[0].hp), hp0), "a short drop does no harm")
	s.global_position = p + Vector3.UP * 80.0
	s.velocity = Vector3.ZERO
	await _seconds(3.5)
	var lost := hp0 - float(s.components[0].hp)
	var floor_speed := sqrt(2.0 * Infantry.TRIBES_GRAVITY * 79.0)
	var expected := floor_speed * float(s.armor.fall_damage_per_mps) * float(s.armor.damage_scale.get("ground", 1.0))
	_expect(lost > 0.0 and absf(lost - expected) < expected * 0.15 or not s.alive,
		"an 80 m fall (%.0f m/s) hurts: %.0f (expected about %.0f)" % [floor_speed, lost, expected])
	await _respawn_if_dead(battle, s)
	battle.pilot.set_physics_process(true)


## Freezes (`on`) or frees the infantry bots: their soldiers and brains stop processing, so no bot shot, grenade
## or mine can land on the soldier the earlier sections test (the cause of the flaky pack checks: a hit from a bot
## during the repair second, or a player already killed by one).
static func _hold_bots(battle: Battle, on: bool) -> void:
	for b in battle.infantry.bots.make_bot_soldiers():
		(b as Node).process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT


## The thrown items of `s` only (the match's bots throw grenades too).
static func _own_items(gear: InfantryGearDirector, s: Infantry) -> Array:
	return gear.make_items().filter(func(t: ThrownItem) -> bool: return t.thrower == s)


func _respawn_if_dead(battle: Battle, s: Infantry) -> void:
	if not s.alive:
		s.respawn(Transform3D(Basis(), _test_site(battle, Vector3(0, 1, 0))))
	await _frames(2)


func _check_grenades(battle: Battle) -> void:
	print("5 grenades and mines:")
	var s := battle.player as Infantry
	var gear := battle.infantry.gear
	s.global_position = _test_site(battle, Vector3(30, 0.5, -150))
	s.torso_target = 0.0
	s.pitch_target = 0.3
	var id := s.kit.grenade_id
	var n0 := s.kit.count(id)
	_expect(id == "tribes2:GRENADE" and n0 == 5, "spawn kit: %d grenades (%s)" % [n0, id])
	var dummy := battle.spawn_soldier_for(80, 1, "Dummy", Transform3D(Basis(), s.global_position + Vector3(0, 0, -14)))
	await _frames(2)
	dummy.end_spawn_protection()
	var hp0 := float(dummy.components[0].hp)
	var ev := InputEventAction.new()
	ev.action = "grenade_throw"
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	await _seconds(0.3)
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await _frames(2)
	_expect(s.kit.count(id) == n0 - 1 and _own_items(gear, s).size() == 1, "grenade_throw (hold, release): one grenade thrown")
	gear.request_throw(InfantryGearDirector.SLOT_GRENADE, 1.0)
	_expect(s.kit.count(id) == n0 - 1, "the throw timeout (0.8 s) holds the next throw")
	await _shot(battle, "grenade_flight")
	await _seconds(InfantryGear.item(id).fuse_s + 0.3)
	_expect(_own_items(gear, s).is_empty(), "it bursts on its fuse %s" % [_own_items(gear, s).map(func(t): return "(age %.2f, at rest %s)" % [t._age, t.at_rest])])
	await _shot(battle, "grenade_burst")
	_expect(float(dummy.components[0].hp) < hp0 or not dummy.alive, "the burst hurts a soldier nearby (%.0f -> %.0f)" % [hp0, float(dummy.components[0].hp)])
	await _respawn_if_dead(battle, s)   # on level ground a short throw may land within its own burst radius
	var mine_id := InfantryKit.make_mine_id(s.armor)
	s.kit.counts[mine_id] = 1
	dummy.global_position += Vector3(0, 0, -200)
	await _seconds(1.0)
	gear.apply_throw(1, InfantryGearDirector.SLOT_MINE, 0.0)
	await _frames(2)
	var own := _own_items(gear, s)
	var mine: ThrownItem = own[0] if not own.is_empty() else null
	_expect(mine != null and mine.is_mine() and s.kit.count(mine_id) == 0, "mine_drop throws a mine")
	s.global_position += Vector3(0, 0, 30)
	await _seconds(InfantryGear.item(mine_id).arm_s + 1.5)
	_expect(mine != null and is_instance_valid(mine) and mine.at_rest, "the mine lies armed")
	var walker := battle.spawn_soldier_for(82, 1, "Walker", Transform3D(Basis(), s.global_position + Vector3(0, 0, 40)))
	await _frames(2)
	if mine and is_instance_valid(mine):
		walker.global_position = mine.global_position + Vector3(1.0, 0.5, 0.0)
		walker.velocity = Vector3.ZERO
	await _seconds(InfantryGear.item(mine_id).arm_s + 0.3)   # armed arm_s after it came to rest
	_expect(not is_instance_valid(mine), "someone near: the mine goes off")
	dummy.global_position += Vector3(0, 0, -300)
	walker.global_position += Vector3(0, 0, -300)


func _check_packs(battle: Battle) -> void:
	print("5 packs and repair kits:")
	var s := battle.player as Infantry
	var gear := battle.infantry.gear
	await _respawn_if_dead(battle, s)   # the grenade / mine section may have killed him
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN", "tribes2:SPINFUSOR"], "tribes2:CONCUSSION_GRENADE", "tribes2:SHIELD_PACK")
	_expect(s.kit.pack_id == "tribes2:SHIELD_PACK" and s.kit.count("tribes2:CONCUSSION_GRENADE") == 5 and s.kit.count("tribes2:GRENADE") == 0,
		"inventory: shield pack, concussion grenades (one grenade type)")
	s.end_spawn_protection()
	_press("pack_use")
	await _frames(2)
	_expect(s.kit.pack_active, "pack_use switches the shield on")
	s.capacitor = s.capacitor_max
	var hp0 := float(s.components[0].hp)
	s.apply_hit(0.0, 600.0, null)
	_expect(is_equal_approx(float(s.components[0].hp), hp0) and s.capacitor < s.capacitor_max - 10.0,
		"the shield takes the hit out of the energy (%.0f left)" % s.capacitor)
	await _shot(battle, "shield_pack")
	_press("pack_use")
	await _frames(2)
	_expect(not s.kit.pack_active, "pack_use again: off")
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "tribes2:AMMO_PACK")
	var cg := s.weapons[0] as InfantryWeapon
	_expect(cg.ammo_max == int(s.armor.ammo["tribes2:CHAINGUN"]) + 150, "ammo pack: chaingun %d rounds" % cg.ammo_max)
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "tribes2:ENERGY_PACK")
	_expect(InfantryPack.make_recharge_bonus(s.kit) > 4.0, "energy pack: faster recharge")
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "tribes2:REPAIR_PACK")
	s.apply_hit(0.0, 900.0, null)
	var hurt := float(s.components[0].hp)
	gear.apply_pack_toggle(1)
	await _seconds(1.0)
	_expect(float(s.components[0].hp) > hurt + 100.0, "repair pack on: repairs its wearer (%.0f -> %.0f)" % [hurt, float(s.components[0].hp)])
	gear.apply_pack_toggle(1)
	s.kit.counts["tribes2:REPAIR_KIT"] = 1
	hurt = float(s.components[0].hp)
	_press("repair_kit_use")
	await _frames(2)
	_expect(float(s.components[0].hp) > hurt + 500.0 and s.kit.count("tribes2:REPAIR_KIT") == 0, "repair_kit_use: +600")
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "tribes2:SENSOR_JAMMER_PACK")
	gear.apply_pack_toggle(1)
	await _frames(2)
	_expect(InfantryPack.is_hidden_at(s, 100.0) and not InfantryPack.is_hidden_at(s, 10.0) and s.has_meta("ecm_jam_deg"),
		"sensor jammer: hidden beyond its radius, missiles deflected")
	gear.apply_pack_toggle(1)
	await _frames(2)
	s.apply_armor("tribes2:LIGHT", s.armor.default_loadout)


func _check_damage_scales(battle: Battle) -> void:
	print("6 damage-type scales:")
	var t := battle.spawn_soldier_for(81, 1, "Heavy", Transform3D(Basis(), _test_site(battle, Vector3(0, 0, 200))))
	t.apply_armor("tribes2:HEAVY", [])
	t.end_spawn_protection()
	var hp0 := float(t.components[0].hp)
	DamageTypes.apply_typed_hit(t, [0.0, 1000.0, null, t.global_position], "bullet")
	_expect(is_equal_approx(hp0 - float(t.components[0].hp), 600.0), "heavy armour takes bullets x0.6 (%.0f)" % (hp0 - float(t.components[0].hp)))
	hp0 = float(t.components[0].hp)
	t.apply_hit(0.0, 100.0, null)
	_expect(is_equal_approx(hp0 - float(t.components[0].hp), 100.0), "untyped hits are not scaled")
	var cg := Packs.weapon("tribes2:CHAINGUN")
	t.set_physics_process(false)   # holds still, high above the terrain, for the shot
	t.global_position += Vector3.UP * 40.0
	var gun := StaticBody3D.new()   # a still shooter: nothing inherited from a moving one
	battle.add_child(gun)
	var p := Weapon.make_projectile(cg, gun, t.global_position + Vector3(0, 1, 8), Vector3(0, 0, -1), null)
	hp0 = float(t.components[0].hp)
	battle.add_child(p)
	p.global_position = t.global_position + Vector3(0, 1, 8)
	for i in 20:
		await get_tree().physics_frame
	t.set_physics_process(true)
	gun.queue_free()
	_expect(is_equal_approx(hp0 - float(t.components[0].hp), float(cg.armor_damage) * 0.6),
		"a chaingun bullet hit is scaled by type (%.0f)" % (hp0 - float(t.components[0].hp)))
	t.global_position += Vector3(0, 0, 400)


func _check_bots(battle: Battle) -> void:
	print("7 infantry bots:")
	var bots := battle.infantry.bots.make_bot_soldiers()
	_expect(bots.size() == BOTS, "%d bots spawned (config infantry_bots)" % bots.size())
	_expect(bots.any(func(b: Infantry) -> bool: return b.team == 0) and bots.any(func(b: Infantry) -> bool: return b.team == 1),
		"bots on both teams")
	_expect(bots.all(func(b: Infantry) -> bool: return b.get_node_or_null("Bot") is InfantryBot), "each bot has a brain")
	var paths := await _measure_bot_paths(bots)
	var walkers := paths.keys()
	var still := walkers.filter(func(b: Infantry) -> bool: return float(paths[b]) < BOT_MIN_PATH)
	_expect(walkers.size() >= BOTS / 2 and still.is_empty(),
		"every bot on foot covers %.0f m in %.0f s (%s; %d of %d were on foot and alive throughout)" % [BOT_MIN_PATH,
		BOT_MOVE_SECONDS, ", ".join(walkers.map(func(b: Infantry) -> String: return "%s %.0f m" % [b.display_name, paths[b]])),
		walkers.size(), BOTS])
	_expect(bots.any(func(b: Infantry) -> bool: return (b.get_node("Bot") as InfantryBot).target != null),
		"bots find enemies")
	await _look_at(battle, bots.filter(func(b: Infantry) -> bool: return b.alive and not b.stowed)[0])
	await _shot(battle, "bots")
	await _check_bot_boarding(battle, bots)
	await _check_bot_refill(battle, bots)


## Path length (sampled every BOT_SAMPLE_SECONDS over BOT_MOVE_SECONDS) of each bot alive and on foot all the
## while: a bot that strafes round its target moves as much as one that runs across the map.
func _measure_bot_paths(bots: Array) -> Dictionary:
	var paths := {}
	var last := {}
	for b in bots:
		paths[b] = 0.0
		last[b] = (b as Infantry).global_position
	for i in roundi(BOT_MOVE_SECONDS / BOT_SAMPLE_SECONDS):
		await _seconds(BOT_SAMPLE_SECONDS)
		for b in paths.keys():
			if not b.alive or b.stowed:
				paths.erase(b)
				continue
			paths[b] = float(paths[b]) + b.global_position.distance_to(last[b])
			last[b] = b.global_position
	return paths


func _check_bot_boarding(battle: Battle, bots: Array) -> void:
	var light: Array = bots.filter(func(b: Infantry) -> bool:
		return b.alive and not b.stowed and b.team == 0 and bool(b.armor.get("can_pilot", false)))
	var herc: Herc = null
	for h in battle.vehicles.values():   # the player's parked Raptor, on its flat spawn
		if not (h is Infantry) and h.vehicle_id == "es1:RAPTOR" and h.team == 0 and h.alive and VehicleOccupancy.of(h).is_empty():
			herc = h
	if light.is_empty() or herc == null:
		_expect(false, "a light-armour bot of team 0 and the player's empty Raptor")
		return
	var bot := light[0] as Infantry
	var brain := bot.get_node("Bot") as InfantryBot
	var site := herc.global_position
	for e in battle.vehicles.values():   # no enemy anywhere near: it may go for a vehicle
		if e is Herc and (e as Herc).team != bot.team:
			(e as Herc).global_position = site + Vector3(0, 300, 900)
			if (e as Herc).get_node_or_null("Bot"):
				(e as Herc).get_node("Bot").set_physics_process(false)
	bot.components[0].hp = float(bot.components[0].max)   # sound and loaded: no reason to refill first
	bot.integrity = 1.0
	for w in bot.weapons:
		w.reload()
	bot.global_position = battle.infantry.make_on_ground(site + herc.global_basis.z * 12.0)
	bot.velocity = Vector3.ZERO
	battle.infantry.bots.apply_release(brain.bot_id)
	brain.task = InfantryBot.Task.ROAM   # decide afresh here
	var boarded := false
	for i in 100:
		await _frames(15)
		var driven := _find_bot_driven(battle)   # this Raptor, or the empty vehicle nearest a bot
		if driven:
			herc = driven
			bot = battle.occupancy.soldier_of(VehicleOccupancy.of(herc).pilot())
			brain = bot.get_node("Bot") as InfantryBot
			boarded = true
			break
	_expect(boarded, "a light bot walks to an empty vehicle and boards it (task %d, %.1f m off the Raptor, target %s)" % [brain.task,
		bot.global_position.distance_to(herc.global_position) - BoardingRules.make_hull_radius(herc), brain.target])
	_expect((herc.get_node_or_null("BotDriver") is AIPilot or (herc is Flyer and (herc as Flyer).ai != null)) and herc.has_meta("ai"),
		"the existing AI pilot drives the %s" % herc.display_name)
	await _look_at(battle, herc)
	await _shot(battle, "bot_driving")
	herc.end_spawn_protection()
	herc.integrity = 0.2
	await _seconds(1.0)
	_expect(not bot.stowed and VehicleOccupancy.of(herc).is_empty(), "the bot gets out of the crippled vehicle")
	for e in battle.vehicles.values():
		if is_instance_valid(e) and e.get_node_or_null("Bot"):
			e.get_node("Bot").set_physics_process(true)
	var driver := herc.get_node_or_null("BotDriver") as AIPilot
	_expect((driver == null or not driver.is_physics_processing()) and not herc.has_meta("ai"), "the vehicle's AI pilot stops with him")


## Puts the player's soldier 14 m behind `h`, looking at it (the screenshots).
func _look_at(battle: Battle, h: Herc) -> void:
	var s := battle.player as Infantry
	if s == null or not is_instance_valid(h):
		return
	var back := h.global_basis.z.normalized() * 14.0 + Vector3.UP * 3.0
	s.global_position = battle.infantry.make_on_ground(h.global_position + back)
	s.velocity = Vector3.ZERO
	var to := h.global_position - s.aim_origin()
	(battle.pilot as InfantryPilot).aim_yaw = atan2(-to.x, -to.z)
	(battle.pilot as InfantryPilot).aim_pitch = atan2(to.y + 1.0, Vector2(to.x, to.z).length())
	await _frames(3)


func _find_bot_driven(battle: Battle) -> Herc:
	for h in battle.vehicles.values():
		if is_instance_valid(h) and not (h is Infantry) and InfantryBots.is_bot(VehicleOccupancy.of(h).pilot()):
			return h
	return null


func _check_bot_refill(battle: Battle, bots: Array) -> void:
	var stations := battle.get_node_or_null("Stations") as TribesStations
	var on_foot := bots.filter(func(b: Infantry) -> bool: return b.alive and not b.stowed)
	if on_foot.is_empty():
		await _seconds(BattleRules.RESPAWN_TIME)
		on_foot = bots.filter(func(b: Infantry) -> bool: return b.alive and not b.stowed)
	var bot := on_foot[0] as Infantry
	var brain := bot.get_node("Bot") as InfantryBot
	bot.components[0].hp = float(bot.components[0].max) * 0.3
	bot.integrity = 0.3
	var nearest := stations.find_nearest(bot, ["inventory"], INF) if stations else -1
	if nearest < 0:
		print("  (map without a usable inventory station: refill not checked)")
		return
	bot.global_position = (stations.stations[nearest].xf as Transform3D).origin + Vector3(20, 1, 0)
	await _seconds(InfantryBot.THINK_SECONDS * 2.0)
	_expect(brain.task == InfantryBot.Task.REFILL, "a hurt bot heads for an inventory station (task %d)" % brain.task)


func _last_message(battle: Battle) -> String:
	var msgs: Array = battle.overlay.hud.messages
	return str(msgs[msgs.size() - 1][0]) if not msgs.is_empty() else ""

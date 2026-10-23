extends Node
## The shared cloak (engine/stealth, docs/formats/cloaking.md):
##   1 profile values of each game, read from the game's data (Tribes 2 scripts, Starsiege datIntMounts / datSensor);
##   2 CloakState on a stand-in unit: energy drain, the break conditions (shot above / below the energy gate, hard /
##     soft hit, timed cloak), glitch and failure, the fade, a puppet following the host;
##   3 who sees a cloaked unit: eyes, plain / motion sensors, Starsiege sensor modes;
##   4 Tribes 2 soldiers in a battle: the pack is offered to light armour only, pack_use cloaks the wearer, enemy
##     radar / T-targeting / turrets / bots lose him (teammates keep him), the motion sensor and a close enemy do not;
##   5 the snapshot flag and the shader override;
##   6 Starsiege: a Herc with a cloak component, the cloak order and key, hidden from enemy pilots and radar;
##   7 Starsiege component slots: the slots and what fits (mount sizes), the garage fitting a cloak, the spawn
##     giving the Herc that cloak and Ctrl+X toggling it.
##   godot --headless --audio-driver Dummy --path game res://tests/cloak_check.tscn

const MAP := "tribes2:Katabatic"
const SETTLE_FRAMES := 20
const T2_PACK := "tribes2:CLOAKING_PACK"
const T2_PROFILE := "tribes2:cloaking_pack"
const SS_HERC := "starsiege:rb_eman"
const SS_UNCLOAKED_HERC := "starsiege:ca_basl"
const SS_MEDIUM_SLOT_HERC := "starsiege:rb_eman"
const CHAMELEON := 830
const CUTTLEFISH := 831
const STATION_FLASH_S := 0.5
const PAD_CLOAK_S := 4.8
const STEP := 0.1
const SITE_RINGS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
const SITE_DIRECTIONS := 8
const SITE_RING_STEP_M := 25.0
const SITE_CLEAR_M := 40.0
const SITE_LEVEL_M := 1.5
const FAR_M := 20.0
const NEAR_M := 5.0

var _failures := 0


## A stand-in for a Herc / soldier: the properties the cloak reads.
class Unit extends Node3D:
	var capacitor := 60.0
	var alive := true
	var integrity := 1.0
	var is_puppet := false
	var speed := 0.0
	var max_speed := 11.0
	var team := 1
	var cloak := CloakState.new()
	var velocity := Vector3.ZERO


func _ready() -> void:
	await get_tree().process_frame
	_check_profiles()
	_check_state()
	_check_visibility()
	var battle := await _start_battle()
	await _check_soldiers(battle)
	await _check_network(battle)
	battle.queue_free()
	await _frames(3)
	await _check_starsiege()
	await _check_starsiege_components()
	print("cloak_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
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


func _make_unit(profile: CloakProfile) -> Unit:
	var u := Unit.new()
	u.cloak.apply_profile(profile)
	add_child(u)
	return u


func _run(u: Unit, seconds: float) -> void:
	for i in int(round(seconds / STEP)):
		u.cloak.apply_step(u, STEP)


# ------------------------------------------------------------------ 1 data

func _check_profiles() -> void:
	print("1 profiles:")
	var t2 := CloakProfile.of(T2_PROFILE)
	_expect(t2.is_real() and is_equal_approx(t2.energy_per_s, 12.0) and is_equal_approx(t2.min_energy, 3.0),
		"Tribes 2 pack: stateEnergyDrain 12/s, minEnergy 3")
	_expect(is_equal_approx(t2.recloak_delay_s, 0.5) and is_equal_approx(t2.recloak_min_energy, 20.0)
		and is_equal_approx(t2.damage_break_min, 300.0) and t2.breaks_on_fire and t2.breaks_on_damage,
		"recloak after 500 ms when the energy is above 20; a hit above 0.1 (300 points) or a shot breaks it")
	_expect(is_equal_approx(t2.reveal_range_m, 8.0) and t2.jams_sensors_when_worn and not t2.ai_uses,
		"the AI sees a cloaked enemy within 8 m; the worn pack jams sensors; the stock AI never switches it on")
	_expect(is_equal_approx(t2.respawn_cloak_s, 6.0) and is_equal_approx(t2.vehicle_pad_cloak_s, 4.8),
		"timed cloaks: respawn 6 s ($InvincibleTime), new vehicle 4.8 s")
	var chameleon := CloakProfile.of_component("starsiege", 830)
	var cuttlefish := CloakProfile.of_component("starsiege", 831)
	_expect(chameleon.is_real() and cuttlefish.is_real() and chameleon.sensor_modes.has("a") and chameleon.sensor_modes.has("p"),
		"Starsiege: Chameleon 830 and Cuttlefish 831 with the standard sensor's modes")
	_expect(is_equal_approx(chameleon.glitch_health, 0.5) and is_equal_approx(chameleon.fail_health, 0.2)
		and float(chameleon.sensor_modes.a.camo) == -2.0 and float(chameleon.sensor_modes.p.camo) == -0.6,
		"newCloak glitch 0.5 / fail 0.2; camo modifier -2.0 against active sensors, -0.6 against passive")
	_expect(not CloakProfile.of("tribes:cloaking_pack").is_real() and not CloakProfile.of("es1:cloak").is_real(),
		"no cloak in Tribes 1 or Earthsiege")
	var light := InfantryCatalog.armor("tribes2:LIGHT")
	var medium := InfantryCatalog.armor("tribes2:MEDIUM")
	_expect(InfantryGear.packs_of(light).has(T2_PACK) and not InfantryGear.packs_of(medium).has(T2_PACK),
		"the pack is offered to light armour only")


# ------------------------------------------------------------------ 2 state

func _check_state() -> void:
	print("2 state:")
	var t2 := CloakProfile.of(T2_PROFILE)
	var u := _make_unit(t2)
	u.cloak.apply_wanted(true, u)
	_run(u, 1.0)
	_expect(u.cloak.is_cloaked() and is_equal_approx(u.capacitor, 48.0), "on: cloaked, 12 energy gone after a second (%.1f)" % u.capacitor)
	u.capacitor = 50.0
	u.cloak.apply_fired(u)
	u.cloak.apply_step(u, STEP)
	_expect(not u.cloak.is_cloaked(), "a shot above 20 energy breaks it")
	_run(u, 0.3)
	_expect(not u.cloak.is_cloaked(), "still off after 0.4 s")
	_run(u, 0.3)
	_expect(u.cloak.is_cloaked(), "back on after 0.5 s")
	u.capacitor = 15.0
	u.cloak.apply_fired(u)
	u.cloak.apply_step(u, STEP)
	_expect(u.cloak.is_cloaked(), "a shot at 20 energy or less does not break it (projectiles.cs ShapeBaseImageData::onFire)")
	u.capacitor = 50.0
	u.cloak.apply_damaged(299.0)
	u.cloak.apply_step(u, STEP)
	_expect(u.cloak.is_cloaked(), "a hit of 299 does not")
	u.cloak.apply_damaged(301.0)
	u.cloak.apply_step(u, STEP)
	_expect(not u.cloak.is_cloaked(), "a hit of 301 does")
	_run(u, 0.6)
	_expect(u.cloak.is_cloaked(), "and it comes back")
	u.alive = false
	u.cloak.apply_step(u, STEP)
	_expect(not u.cloak.is_cloaked() and not u.cloak.is_wanted(), "death switches it off")
	u.alive = true
	u.capacitor = 2.0
	u.cloak.apply_wanted(true, u)
	_expect(not u.cloak.is_wanted(), "it will not start below minEnergy")
	u.capacitor = 60.0
	u.cloak.apply_forced(6.0)
	_run(u, 1.0)
	_expect(u.cloak.is_cloaked(), "a timed cloak runs without the switch")
	u.cloak.apply_fired(u)
	u.cloak.apply_step(u, STEP)
	_expect(not u.cloak.is_cloaked(), "a shot ends the respawn cloak for good")
	_check_fade_and_puppet(t2)
	_check_glitch()


func _check_fade_and_puppet(t2: CloakProfile) -> void:
	var u := _make_unit(t2)
	u.cloak.apply_wanted(true, u)
	_run(u, 0.3)
	_expect(u.cloak.fade > 0.0 and u.cloak.fade < 1.0, "the shimmer fades in (%.2f)" % u.cloak.fade)
	_run(u, t2.fade_in_s)
	_expect(is_equal_approx(u.cloak.fade, 1.0), "fully cloaked")
	u.cloak.apply_wanted(false, u)
	_run(u, t2.fade_out_s + 0.1)
	_expect(u.cloak.fade == 0.0, "and out again")
	var puppet := _make_unit(t2)
	puppet.is_puppet = true
	puppet.cloak.apply_remote(true)
	_run(puppet, 1.0)
	_expect(puppet.cloak.is_cloaked() and puppet.capacitor == 60.0, "a puppet follows the host's flag and spends nothing")


func _check_glitch() -> void:
	var u := _make_unit(CloakProfile.of_component("starsiege", 830))
	u.cloak.apply_wanted(true, u)
	_run(u, 1.0)
	_expect(u.cloak.is_cloaked() and u.capacitor == 60.0, "Starsiege cloak: no energy cost, on")
	u.integrity = 0.4
	var on := 0
	var off := 0
	for i in 40:
		u.cloak.apply_step(u, STEP)
		if u.cloak.is_cloaked():
			on += 1
		else:
			off += 1
	_expect(on > 5 and off > 5, "below glitch_health it drops out and returns (%d on, %d off)" % [on, off])
	u.integrity = 0.1
	_run(u, 2.0)
	_expect(not u.cloak.is_cloaked(), "below fail_health it is dead")


# ------------------------------------------------------------------ 3 who sees it

func _check_visibility() -> void:
	print("3 visibility:")
	var t2 := _make_unit(CloakProfile.of(T2_PROFILE))
	t2.cloak.apply_wanted(true, t2)
	_run(t2, 0.1)
	_expect(CloakRules.is_hidden_from_eyes(t2, FAR_M) and not CloakRules.is_hidden_from_eyes(t2, 6.0),
		"eyes: hidden at %.0f m, seen at 6 m" % FAR_M)
	var plain := {"detects_cloaked": false}
	var motion := {"detects_cloaked": true, "min_velocity": 2.0}
	_expect(CloakRules.is_hidden_from_sensor(t2, plain, 30.0) and CloakRules.is_hidden_from_sensor(t2, motion, 30.0),
		"a still cloaked unit is hidden from plain and motion sensors")
	t2.velocity = Vector3(3.0, 0, 0)
	_expect(CloakRules.is_hidden_from_sensor(t2, plain, 30.0) and not CloakRules.is_hidden_from_sensor(t2, motion, 30.0),
		"moving at 3 m/s a motion sensor (detectsCloaked, 2 m/s) sees it, a plain sensor does not")
	t2.velocity = Vector3.ZERO
	var plain_unit := _make_unit(CloakProfile.NONE)
	_expect(not CloakRules.is_hidden_from_eyes(plain_unit, 100.0), "a unit without a cloak is never hidden")
	var ss := CloakProfile.of_component("starsiege", 830)
	var d := _make_unit(ss)
	_expect(is_zero_approx(CloakRules.make_detect_chance(ss, d, true)), "Starsiege active sensor: 0.6 - 2.0 - 0.1 + 0.4 -> 0")
	_expect(is_equal_approx(CloakRules.make_detect_chance(ss, d, false), 0.15),
		"passive sensor against an emitting stopped unit: 0.35 - 0.6 - 0.2 + 0.6 = 0.15")
	RadarMode.apply_emitting(d, false)
	_expect(is_zero_approx(CloakRules.make_detect_chance(ss, d, false)), "a quiet stopped unit (passive): none")
	d.velocity = Vector3(10, 0, 0)
	RadarMode.apply_emitting(d, true)
	_expect(CloakRules.make_detect_chance(ss, d, false) > 0.15, "moving fast and emitting it is easier to find")
	var motion_sensor := CloakProfile.make_sensor_modes_by_id("starsiege", 434)
	_expect(CloakRules.make_detect_chance(ss, d, true, motion_sensor) > 0.5 and is_zero_approx(CloakRules.make_detect_chance(ss, d, true)),
		"the Cybrid Motion Sensor (camo -0.5) finds a moving cloak that a standard active sensor (camo -2.0) loses (HB1: 'compensated for our cloaks')")


# ------------------------------------------------------------------ 4 Tribes 2 soldiers

func _start_battle() -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 500, "ai": [], InfantryBots.CONFIG_KEY: 1}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _test_site(battle: Battle) -> Vector3:
	var origin := (battle.player as Infantry).global_position
	for ring in SITE_RINGS:
		for k in SITE_DIRECTIONS:
			var a := TAU * float(k) / SITE_DIRECTIONS
			var p: Vector3 = origin + Vector3(cos(a), 0, sin(a)) * ring * SITE_RING_STEP_M + Vector3(0, 0, 400)
			if not battle.bounds.bounds.is_outside(p) and _is_level_ahead(battle, p):
				p.y = MapBuilder.ground_height(battle, p)
				return p
	origin.y = MapBuilder.ground_height(battle, origin)
	return origin


func _is_level_ahead(battle: Battle, p: Vector3) -> bool:
	var h0 := MapBuilder.ground_height(battle, p)
	for step in range(5, int(SITE_CLEAR_M) + 1, 5):
		if absf(MapBuilder.ground_height(battle, p + Vector3(0, 0, step)) - h0) > SITE_LEVEL_M:
			return false
	return true


func _soldier(battle: Battle, peer: int, team: int, at: Vector3, pack := "") -> Infantry:
	at.y = MapBuilder.ground_height(battle, at) + 0.3
	var s := battle.spawn_soldier_for(peer, team, "S%d" % peer, Transform3D(Basis(), at))
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", pack)
	s.end_spawn_protection()
	s.set_physics_process(false)
	return s


func _check_soldiers(battle: Battle) -> void:
	print("4 Tribes 2 soldiers:")
	for b in battle.infantry.bots.make_bot_soldiers():
		(b as Node).process_mode = Node.PROCESS_MODE_DISABLED
	var site := _test_site(battle)
	var wearer := battle.player as Infantry
	wearer.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", T2_PACK)
	wearer.end_spawn_protection()
	wearer.global_position = Vector3(site.x, site.y + 0.3, site.z)
	wearer.velocity = Vector3.ZERO
	var enemy := _soldier(battle, 82, wearer.team + 1, site + Vector3(0, 0, FAR_M))
	var friend := _soldier(battle, 83, wearer.team, site + Vector3(8, 0, FAR_M))
	await _frames(2)
	_expect(wearer.cloak.profile.id == T2_PROFILE, "wearing the pack installs the Tribes 2 profile")
	await _seconds(0.6)
	_expect(RadarContacts.is_shown(enemy, wearer), "control: the enemy sees the uncloaked wearer %.0f m ahead" % FAR_M)
	wearer.capacitor = wearer.capacitor_max
	var gear := battle.infantry.gear
	gear.apply_pack_toggle(1)
	var energy0 := wearer.capacitor
	await _seconds(1.0)
	_expect(wearer.kit.pack_active and wearer.cloak.is_cloaked(), "pack_use cloaks the wearer")
	var recharged := wearer.capacitor_rate
	_expect(wearer.capacitor < energy0 + recharged - 6.0, "the cloak costs energy (%.1f of %.1f)" % [wearer.capacitor, energy0])
	await _seconds(0.5)
	_expect(not RadarContacts.is_shown(enemy, wearer) and not RadarContacts.is_on_scope(enemy, wearer), "the enemy's radar lost him")
	_expect(RadarContacts.is_shown(friend, wearer), "a teammate keeps him")
	_expect(not Targeting.make_candidates(enemy).has(wearer), "T-targeting does not offer him")
	_expect(not _turret_finds(wearer, {}), "a turret's search skips him")
	wearer.global_position = enemy.global_position + Vector3(0, 0, -NEAR_M)
	await _seconds(0.6)
	_expect(RadarContacts.is_shown(enemy, wearer), "closer than 8 m the enemy sees him")
	wearer.global_position = site
	wearer.global_position.y = MapBuilder.ground_height(battle, site) + 0.3
	_check_bot_search(battle, wearer)
	var motion := {"detects_cloaked": true, "min_velocity": 2.0}
	_expect(not _turret_finds(wearer, motion), "a motion-sensor turret does not see him standing still")
	wearer.velocity = Vector3(5, 0, 0)
	_expect(_turret_finds(wearer, motion), "but sees him moving")
	wearer.velocity = Vector3.ZERO
	await _check_breaks(wearer, enemy)
	gear.apply_pack_toggle(1)
	await _frames(2)
	await _seconds(0.6)
	_expect(not wearer.cloak.is_cloaked(), "pack_use again: visible")
	_check_worn_pack_jams(battle, wearer, enemy)
	await _check_jam_field(battle, wearer, site)
	await _check_timed(wearer, site)
	await _check_flashes(battle, wearer)


func _turret_finds(target: Node3D, sensor: Dictionary) -> bool:
	var profile := TargetProfile.make_turret().with_range(80.0)
	profile.sensor = sensor
	profile.hostile_rule = func(_a: int, _b: int) -> bool: return true
	return TargetSelector.pick(get_tree(), profile, {"from": target.global_position + Vector3(0, 1, 30), "team": -1,
		"accepts": func(v: Node3D, _p: Vector3) -> bool: return v == target}) == target


func _check_bot_search(battle: Battle, wearer: Infantry) -> void:
	var bots := battle.infantry.bots.make_bot_soldiers()
	if bots.is_empty():
		return
	var bot := bots[0] as Infantry
	var brain: Node = null
	for c in bot.get_children():
		if c is InfantryBot:
			brain = c
	if brain == null:
		return
	var team := bot.team
	wearer.team = team + 1
	bot.global_position = wearer.global_position + Vector3(0, 0, FAR_M)
	_expect(brain._find_target(200.0) != wearer, "a bot's target search does not find the cloaked wearer at %.0f m" % FAR_M)
	bot.global_position = wearer.global_position + Vector3(0, 0, NEAR_M)
	_expect(brain._find_target(200.0) == wearer, "but finds him at %.0f m" % NEAR_M)


func _check_breaks(wearer: Infantry, enemy: Infantry) -> void:
	wearer.capacitor = wearer.capacitor_max
	var chaingun := wearer.weapons[0] as Weapon
	wearer.cloak.apply_wanted(true, wearer)
	await _frames(2)
	chaingun.fire()
	await _frames(2)
	_expect(not wearer.cloak.is_cloaked(), "firing breaks the soldier's cloak")
	await _seconds(0.8)
	_expect(wearer.cloak.is_cloaked(), "and it returns")
	wearer.apply_hit(0.0, 50.0, enemy)
	_expect(wearer.cloak.is_cloaked(), "a light hit leaves it on")
	wearer.apply_hit(0.0, 600.0, enemy)
	await _frames(2)
	_expect(not wearer.cloak.is_cloaked(), "a hard hit breaks it")


func _check_worn_pack_jams(battle: Battle, wearer: Infantry, enemy: Infantry) -> void:
	_expect(CloakRules.is_passive_jammed(wearer) and not CloakRules.is_passive_jammed(enemy),
		"wearing the pack, on or off, jams sensors that do not detect jammed units")
	var net := TribesBase.of(battle).sensor_net if TribesBase.of(battle) else null
	_expect(net != null, "the map has a sensor net")


func _check_jam_field(battle: Battle, wearer: Infantry, site: Vector3) -> void:
	var jammer := _soldier(battle, 85, wearer.team + 1, site + Vector3(10, 0, 0), "tribes2:SENSOR_JAMMER_PACK")
	jammer.kit.pack_active = true
	jammer.set_physics_process(true)
	wearer.kit.pack_active = false
	await _frames(3)
	wearer.capacitor = wearer.capacitor_max
	wearer.kit.pack_active = true
	await _frames(3)
	_expect(not wearer.cloak.is_wanted() and not wearer.kit.pack_active,
		"inside a sensor jammer's field the cloak cannot run and the pack switches off")
	jammer.kit.pack_active = false
	jammer.queue_free()
	await _frames(3)


## The scripts' own cloaks (defaultGame.cs respawn, setCloaked): they need no pack.
func _check_timed(wearer: Infantry, site: Vector3) -> void:
	wearer.respawn(Transform3D(Basis(), Vector3(site.x, site.y + 0.3, site.z)))
	await _frames(3)
	_expect(wearer.cloak.profile.id == "tribes2:timed_cloak" and wearer.cloak.is_cloaked() and not wearer.cloak.is_wanted(),
		"a respawned soldier is cloaked for $InvincibleTime with no pack")
	wearer.end_spawn_protection()
	(wearer.weapons[0] as Weapon).fire()
	await _frames(2)
	_expect(not wearer.cloak.is_cloaked(), "and firing ends the respawn cloak for good")
	wearer.cloak.apply_scripted(true)
	await _frames(2)
	_expect(wearer.cloak.is_cloaked(), "a script's setCloaked(true) cloaks him")
	wearer.cloak.apply_scripted(false)
	await _frames(2)
	_expect(not wearer.cloak.is_cloaked(), "and setCloaked(false) ends it")


## The inventory station flashes its buyer cloaked (station.cs:275-276, 0.5 s) and a vehicle leaving its pad is cloaked
## (serverVehicleHud.cs:144-148, 4.8 s).
func _check_flashes(battle: Battle, wearer: Infantry) -> void:
	var t2 := CloakProfile.of(CloakProfile.make_timed_id(wearer))
	_expect(is_equal_approx(t2.station_flash_s, STATION_FLASH_S), "the timed cloak's station flash is 0.5 s (station.cs)")
	wearer.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "")
	await _seconds(1.6)
	_expect(not wearer.cloak.is_cloaked(), "control: the soldier is plain before the purchase")
	TribesStations.apply_station_flash(wearer)
	await _seconds(0.2)
	_expect(wearer.cloak.is_cloaked(), "buying at the inventory station flashes the buyer cloaked")
	await _seconds(STATION_FLASH_S + 0.5)
	_expect(not wearer.cloak.is_cloaked(), "and the flash ends after the script's 500 ms")
	_expect(is_equal_approx(TribesStations.make_pad_cloak_s(wearer), PAD_CLOAK_S), "a vehicle off a pad is cloaked %.1f s (profile)" % PAD_CLOAK_S)
	var site := wearer.global_position + Vector3(0, 0, 60)
	var tribes_vehicles := Packs.vehicles.values().filter(func(d: Dictionary) -> bool: return str(d.get("pack", "")) == "tribes2" and str(d.get("category", "")) == "vehicle")
	var vehicle: Herc = battle.spawn_ai(str(tribes_vehicles[0].id), wearer.team, Transform3D(Basis(), site), [], "PadCloak", {})
	_expect(vehicle != null and not vehicle.cloak.is_equipped(), "control: a Tribes 2 vehicle has no cloak of its own")
	BattleSpawner.apply_pad_cloak(vehicle, TribesStations.make_pad_cloak_s(wearer))
	await _seconds(0.3)
	_expect(vehicle.cloak.is_cloaked(), "a vehicle launched from a pad is cloaked")
	await _seconds(PAD_CLOAK_S)
	_expect(not vehicle.cloak.is_cloaked(), "and shows again after the pad's 4.8 s")
	vehicle.queue_free()


# ------------------------------------------------------------------ 5 network and shader

func _check_network(battle: Battle) -> void:
	print("5 network and shader:")
	var wearer := battle.player as Infantry
	wearer.capacitor = wearer.capacitor_max
	wearer.cloak.apply_wanted(true, wearer)
	await _seconds(1.2)
	var state := BattleSnapshotStream.make_state(wearer)
	_expect(state.size() == SnapshotCodec.STATE_SIZE and state[SnapshotCodec.IDX_CLOAKED] == true, "the snapshot state carries the cloak flag")
	var groups := SnapshotCodec.encode_groups(state)
	var record := SnapshotCodec.make_record(wearer.net_id, SnapshotCodec.ALL_GROUPS, groups)
	var packet := SnapshotCodec.decode_packet(SnapshotCodec.make_packets(1, 30, PackedInt32Array(), [record])[0], {})
	_expect(not packet.is_empty() and packet.records[0].fields[SnapshotCodec.IDX_CLOAKED] == true
		and packet.records[0].fields[SnapshotCodec.IDX_ALIVE] == true, "it survives the status byte next to the alive bit")
	_check_meshes(wearer)
	var puppet_state := state.duplicate()
	var puppet := _soldier(battle, 84, wearer.team + 1, wearer.global_position + Vector3(10, 0, 0))
	puppet.is_puppet = true
	puppet.apply_snapshot(puppet_state, 0.05)
	puppet.cloak.apply_step(puppet, 0.05)
	_expect(puppet.cloak.is_cloaked(), "a puppet shows the cloak of the snapshot")
	puppet_state[SnapshotCodec.IDX_CLOAKED] = false
	puppet.apply_snapshot(puppet_state, 0.05)
	puppet.cloak.apply_step(puppet, 0.05)
	_expect(not puppet.cloak.is_cloaked(), "and drops it with the next one")
	var frame := InputFrame.make_quantized({"seq": 1, "cloak": true})
	_expect(bool(frame.cloak) and not bool(InputFrame.make_quantized({"seq": 2}).cloak), "the pilot's cloak wish rides in the input frame flags")


func _check_meshes(unit: Herc) -> void:
	var meshes := CloakVisual.make_meshes(unit)
	_expect(not meshes.is_empty() and meshes.all(func(m: MeshInstance3D) -> bool: return m.material_override is ShaderMaterial),
		"every mesh of the body draws through the cloak shader (%d meshes)" % meshes.size())
	unit.cloak.apply_wanted(false, unit)
	for i in 40:
		unit.cloak.apply_step(unit, STEP)
	_expect(meshes.all(func(m: MeshInstance3D) -> bool: return m.material_override == null), "and are plain again once it is off")


# ------------------------------------------------------------------ 6 Starsiege

func _check_starsiege() -> void:
	print("6 Starsiege:")
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "ai": []}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	var viewer := battle.player as Herc
	if Packs.vehicle(SS_HERC).is_empty() or viewer == null:
		_expect(false, "the Starsiege pack and a player Herc are installed")
		return
	var at := viewer.global_position + Vector3(0, 0, 300)
	var d: Herc = battle.spawn_ai(SS_HERC, viewer.team + 1, Transform3D(Basis(), at), [], "Cloaker", {"skill": 0.5, "group": 1, "order": 6, "path": []})
	await _frames(3)
	_expect(d != null and d.cloak.profile.id == "starsiege:830", "a Herc with a Chameleon component carries its profile")
	var plain: Herc = battle.spawn_ai("es1:RAPTOR", viewer.team + 1, Transform3D(Basis(), at + Vector3(40, 0, 0)), [], "Plain", {})
	await _frames(3)
	_expect(plain != null and not plain.cloak.is_equipped(), "an Earthsiege Herc has none")
	_expect(RadarContacts.is_shown(viewer, d), "control: the uncloaked Herc is on the radar")
	SSUnitDirector._order_cloak(d, [true])
	await _seconds(1.5)
	_expect(d.cloak.is_cloaked(), "the cloak order switches it on")
	_expect(not RadarContacts.is_shown(viewer, d) and not RadarContacts.is_on_scope(viewer, d), "an enemy radar cannot find a cloaked Herc")
	_expect(not Targeting.make_candidates(viewer).has(d), "T-targeting does not offer it")
	var pilot: AIPilot = null
	var hunter: Herc = battle.spawn_ai("es1:RAPTOR", viewer.team, Transform3D(Basis(), at + Vector3(-40, 0, 0)), [], "Hunter",
		{"skill": 0.5, "group": 2, "order": 6, "path": []})
	await _frames(3)
	for c in hunter.get_children():
		if c is AIPilot:
			pilot = c
	_expect(pilot != null and pilot._find_target(5000.0) != d, "an enemy pilot's search skips it")
	SSUnitDirector._order_cloak(d, [false])
	await _seconds(1.5)
	_expect(not d.cloak.is_cloaked() and RadarContacts.is_shown(viewer, d), "cloak off: seen again")
	var human := battle.player as Herc
	human.cloak.apply_profile(CloakProfile.of_component("starsiege", 831))
	human.cloak_input = true
	await _seconds(1.5)
	_expect(human.cloak.is_cloaked(), "the pilot's cloak_toggle wish cloaks his own Herc (Cuttlefish)")
	_expect(BattleNetSync.make_controls(human).get("cloak", false) == true, "and is sent to the host with the controls")
	battle.queue_free()
	await _frames(2)


# ------------------------------------------------------------------ 7 Starsiege component slots

func _check_starsiege_components() -> void:
	print("7 Starsiege component slots:")
	var v := Packs.vehicle(SS_UNCLOAKED_HERC)
	var medium := Packs.vehicle(SS_MEDIUM_SLOT_HERC)
	var slots := HercMounts.make_slots(v)
	_expect(slots.size() == 2 and slots[0].size == "L" and slots[1].size == "L", "%s has two large free slots (mountpoints 6 and 7)" % SS_UNCLOAKED_HERC)
	_expect(HercMounts.make_options(v, 0).size() == 2, "a large slot takes both cloaks (Chameleon M, Cuttlefish L)")
	var medium_ids := HercMounts.make_options(medium, 0).map(func(p: CloakProfile) -> int: return p.component_id_of("starsiege"))
	_expect(medium_ids == [CHAMELEON], "a medium slot takes the Chameleon only, not the large Cuttlefish")
	_expect(not HercMounts.is_allowed(v, 0, 900) and not HercMounts.has_slots(Packs.vehicle("es1:RAPTOR")), "no other part fits, and an Earthsiege Herc has no slots")
	_expect(not HercMounts.make_cloak(v, [0, 0]).is_real(), "the factory fit of %s has no cloak" % SS_UNCLOAKED_HERC)
	var mounts := HercMounts.make_sanitized(v, [])
	_expect(HercMounts.apply_set(v, mounts, 1, CHAMELEON) and HercMounts.make_cloak(v, mounts).id == "starsiege:830", "fitting a Chameleon gives its profile")
	_expect(not HercMounts.apply_set(medium, HercMounts.make_sanitized(medium, []), 0, CUTTLEFISH), "the slot-size rule refuses a Cuttlefish in a medium slot")
	var rows := HercMounts.make_rows(v, mounts)
	_expect(rows.size() == 2 and rows[1].current == CHAMELEON and rows[0].options.size() == 4, "the loadout rows list each slot: factory, empty and the cloaks")
	await _check_garage_fitting()
	await _check_spawn_and_toggle()


func _check_garage_fitting() -> void:
	var g := Garage.make([Garage.make_entry(SS_UNCLOAKED_HERC)], {})
	_expect(g.selected_entry().mounts == [0, 0], "a garage Herc starts with the factory fit")
	_expect(g.can_mount(0, CUTTLEFISH) and g.apply_mount(0, CUTTLEFISH) and g.selected_entry().mounts == [CUTTLEFISH, 0], "the garage fits a Cuttlefish")
	_expect(not g.apply_mount(0, 900) and g.selected_entry().mounts[0] == CUTTLEFISH, "and refuses what does not fit")
	var saved := Garage.from_dict(g.to_dict())
	_expect(saved.selected_entry().mounts == [CUTTLEFISH, 0], "the fitting survives a save")
	_expect(g.make_battle_entry().garage.mounts == [CUTTLEFISH, 0], "and rides into the battle with the garage tag")
	var editor := LoadoutEditor.new()
	add_child(editor)
	editor.setup(SS_UNCLOAKED_HERC, [], {}, [0, CHAMELEON])
	_expect(editor.find_children("*", "OptionButton", true, false).size() >= 2, "the hangar editor lists the component slots")
	editor.queue_free()


func _check_spawn_and_toggle() -> void:
	var config := BattleSetup.make_default_config(SS_UNCLOAKED_HERC)
	config.merge({"mode": "vs", "respawn": true, "teams": true, "ai": []}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	var human := battle.player as Herc
	_expect(human != null and human.vehicle_id == SS_UNCLOAKED_HERC and not human.cloak.is_equipped(), "a %s pilot starts with no cloak" % SS_UNCLOAKED_HERC)
	BattleSpawner.apply_mounts(human, {"mounts": [0, CHAMELEON]})
	_expect(human.cloak.profile.id == "starsiege:830", "the spawn's mounts install the fitted Chameleon")
	var pilot: PlayerPilot = battle.pilot if battle.pilot != null and battle.pilot.herc == human else PlayerPilot.make_for(human)
	_expect(pilot != null, "the player has a pilot")
	var key := InputEventAction.new()
	key.action = "cloak_toggle"
	key.pressed = true
	pilot._apply_command(key)
	await _seconds(1.5)
	_expect(human.cloak_input and human.cloak.is_cloaked(), "Ctrl+X (cloak_toggle) cloaks the Herc")
	pilot._apply_command(key)
	await _seconds(1.5)
	_expect(not human.cloak.is_cloaked(), "and toggles it off again")
	var bare := {"garage": {"mounts": [CUTTLEFISH, 0]}}
	BattleSpawner.apply_mounts(human, bare)
	_expect(human.cloak.profile.id == "starsiege:831", "a garage Herc's tag carries its mounts when the spec has none")
	battle.queue_free()
	await _frames(2)

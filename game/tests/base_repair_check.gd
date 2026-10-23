extends Node
## Base objects are never removed and can be repaired (docs/TRIBES_BASE_EQUIPMENT.md; RepairRules, BaseCapture), on a
## Tribes 1 and a Tribes 2 map in real battles:
##   units       the repair pack mends a hurt teammate and a vehicle in reach (not its wearer meanwhile) at the game's rate;
##   standing    a destroyed generator / turret stays in the world as a ruin (disabled, not removed); its power
##               effect holds: a generator down powers its base off;
##   faction     a guard soldier of the owner's side walks to the downed generator and repairs it (Task.REPAIR),
##               without capturing it; the base is powered again;
##   capture     a player (a team hostile to the owner) who repairs a downed turret with the repair pack captures
##               it: its team becomes his, it fires at its old faction; it returns to the owner when the time is up
##               and when it is destroyed; the owner's repair work takes it back; a captured generator powers the
##               capturer's side and not the owner's;
##   structures  (one Tribes 2 battle) a Herc holding the repair action mends an Earthsiege / Starsiege structure at a share
##               of its hit points per second, captures a hostile one, and cannot revive a destroyed or indestructible one;
##   sync        a client applies the host's team / repair messages (their receiving functions called as the RPC does).
## godot --headless --audio-driver Dummy --path game res://tests/base_repair_check.tscn

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const MAPS := ["tribes:Raindance", "tribes2:Katabatic"]
const GAMES := ["tribes", "tribes2", "es1", "es2", "starsiege"]
const SETTLE_FRAMES := 30
const TIME_SCALE := 4.0
const TARGET_VEHICLE := "es1:SCORPION"
const PLAYER_TEAM := 7
const OWNER_TEAM := 0
const SPOT_SHARES := [0.3, 0.5, 0.7]
const SPOT_BEARINGS := 12
const WAIT_STEP := 0.25
const FACTION_WAIT := 90.0
const REPAIR_WAIT := 30.0
const FIRE_WAIT := 8.0
const HIT_WAIT := 2.0
const CREW_DISTANCE := 7.0
const CREW_DROP := 4.0
const TEST_CAPTURE_SECONDS := 40.0
const MATE_GAP := 2.0
const HURT_SHARE := 0.5
const HERC_PEER := 99
const STRUCTURE_GAP := 12.0
const HOLD_WAIT := 3.0
const ES1_STRUCTURE := "es1:BASES_0"
const SS_STRUCTURE := "starsiege:htroopplanetdefense"
const STRUCTURE_HP := 15000.0

var _failures := 0
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	_guard.back_up()
	await get_tree().process_frame
	_check_rules()
	for map_id in MAPS:
		if MapBuilder.load_map(map_id).is_empty():
			print("skip %s: not installed" % map_id)
			continue
		await _check_map(map_id)
	Engine.time_scale = 1.0
	_guard.restore()
	print("base_repair_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Waits up to `limit` seconds (game time) until `done` is true; returns whether it became true.
func _until(done: Callable, limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if done.call():
			return true
		await get_tree().create_timer(WAIT_STEP, true, true).timeout
		t += WAIT_STEP * Engine.time_scale
	return done.call()


func _check_rules() -> void:
	print("rules:")
	for pack in GAMES:
		_expect(BaseCapture.is_on(pack) and BaseCapture.make_seconds(pack) > 0.0, "%s: capture is on, with a duration from data" % pack)
		var hold := RepairRules.hold(pack)
		_expect(float(hold.get("reach_m", 0.0)) > 0.0 and float(hold.get("hp_share_per_s", 0.0)) > 0.0,
			"%s: the hold repair has its reach and rate in data" % pack)
	_expect(RepairRules.make_unit_rate_source("tribes2") == RepairRules.UNIT_RATE_PACK and RepairRules.make_unit_rate_source("tribes") == "object",
		"Tribes 2 mends a teammate at the pack's own rate, Tribes 1 at the object rate (RepairGunImage / RepairBolt)")
	_expect(float(RepairRules.make_beam("tribes").get("range", 0.0)) > 0.0 and float(RepairRules.make_beam("tribes2").get("per_s", 0.0)) > 0.0,
		"both Tribes games have their repair beam's reach and rate")
	_expect(float(RepairRules.faction().get("search_m", 0.0)) > 0.0 and float(RepairRules.faction().get("reach_m", 0.0)) > 0.0,
		"the faction repair crew has its search and reach in data")


func _check_map(map_id: String) -> void:
	print("%s:" % map_id)
	var battle := await _start_battle(map_id)
	Engine.time_scale = TIME_SCALE
	var base := TribesBase.of(battle)
	var turret := _find_turret(base, OWNER_TEAM)
	_expect(base != null and turret != null, "team 0 has a base with an armed, powered turret")
	if base and turret:
		var gens := base.objects_of(TribesBaseObject.KIND_GENERATOR).filter(
			func(g: TribesBaseObject) -> bool: return base.grid.make_powered_groups([g.power_group]).has(turret.power_group))
		_expect(not gens.is_empty(), "the turret's group is fed by %d generator(s)" % gens.size())
		if not gens.is_empty():
			await _check_units(battle)
			if map_id == MAPS[-1]:
				await _check_structures(battle)
			await _check_standing(base, turret, gens)
			await _check_faction_repair(battle, base, turret, gens)
			await _check_capture(battle, base, turret)
			await _check_captured_generator(battle, base, turret, gens)
			_check_sync(base, turret)
	Engine.time_scale = 1.0
	battle.queue_free()
	await _frames(4)


func _start_battle(map_id: String) -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": map_id, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": []}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _find_turret(base: TribesBase, team: int) -> TribesTurret:
	var best: TribesTurret = null
	for o in base.objects_of(TribesBaseObject.KIND_TURRET):
		var t := o as TribesTurret
		if t and t.team == team and t.is_armed() and t.is_working() and (best == null or t.engage_range > best.engage_range):
			best = t
	return best


## Hits `o` until it is destroyed (a Tribes 2 shield takes the first hits).
static func _destroy(o: TribesBaseObject) -> void:
	for i in 6:
		o.apply_hit(0.0, o.max_hp, null)


# ------------------------------------------------------------------ standing

func _check_standing(base: TribesBase, turret: TribesTurret, gens: Array) -> void:
	print(" standing:")
	for g in gens:
		_destroy(g)
	_destroy(turret)
	await get_tree().create_timer(TribesBase.STATE_CHECK_SECONDS * 3.0, true, true).timeout
	_expect(gens.all(func(g: TribesBaseObject) -> bool: return not g.alive and g.make_damage_state() == "Destroyed"),
		"the generators are destroyed")
	_expect(gens.all(func(g: TribesBaseObject) -> bool: return _is_standing(base, g)), "a destroyed generator stays standing in the world")
	_expect(is_instance_valid(turret) and turret.is_inside_tree() and not turret.alive and base.objects.has(turret),
		"a destroyed turret stays standing too")
	_expect(not turret.powered and not turret.is_working(), "the base is powered off with its generators down")
	var shots := turret.shots_fired
	await get_tree().create_timer(1.0, true, true).timeout
	_expect(turret.shots_fired == shots, "a downed turret does not fire")


## A floor spot CREW_DISTANCE from `g` on the same level (a ray down from just above the generator's height).
func _find_crew_spot(g: TribesBaseObject) -> Vector3:
	var space := g.get_world_3d().direct_space_state
	for k in 8:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * k / 8.0)
		var top := g.global_position + dir * CREW_DISTANCE + Vector3.UP * CREW_DROP
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(top, top + Vector3.DOWN * CREW_DROP * 3.0))
		if not hit.is_empty() and (hit.normal as Vector3).y > 0.7:
			return (hit.position as Vector3) + Vector3.UP
	return g.global_position + Vector3(CREW_DISTANCE, 1.0, 0.0)


static func _is_standing(base: TribesBase, o: TribesBaseObject) -> bool:
	return is_instance_valid(o) and o.is_inside_tree() and not o.is_queued_for_deletion() and base.objects.has(o) 		and o.is_in_group(Structure.TARGET_GROUP)


# ------------------------------------------------------------------ faction crew

func _check_faction_repair(battle: Battle, base: TribesBase, turret: TribesTurret, gens: Array) -> void:
	print(" faction repair:")
	var pack: String = battle.infantry.pack
	var spec := battle.infantry.bots.make_bot_spec(pack, 0)
	var g: TribesBaseObject = gens[0]
	var from := _find_crew_spot(g)
	spec.team = OWNER_TEAM
	spec.xf = Transform3D(Basis(), from)
	var brain := battle.infantry.bots.spawn_bot(spec, 0.5)
	_expect(brain != null, "a guard soldier of the owner's side is fielded")
	if brain == null:
		return
	brain.guard_point = g.global_position
	brain.guard_radius = CREW_DISTANCE * 4.0
	var job := base.find_job_for(brain.soldier, brain.bot_id)
	_expect(job != null and job.team == OWNER_TEAM, "the base hands him a downed object of his side (%s)" % (job.display_name if job else "none"))
	var done := job != null and await _until(func() -> bool: return job.alive and job.is_enabled(), FACTION_WAIT)
	_expect(done, "the soldier walks to the downed generator and repairs it (task %d, %.0f/%.0f hp)" % [brain.task,
		job.hp if job else 0.0, job.max_hp if job else 0.0])
	_expect(gens.all(func(x: TribesBaseObject) -> bool: return x.team == OWNER_TEAM and not x.is_captured()),
		"faction repair does not capture: the generators stay the owner's")
	await get_tree().create_timer(TribesBase.STATE_CHECK_SECONDS * 3.0, true, true).timeout
	_expect(base.objects_of(TribesBaseObject.KIND_GENERATOR).any(func(x: TribesBaseObject) -> bool: return x.is_power_source()),
		"a repaired generator powers again")
	# the crew is done: it must not meddle with the capture checks
	brain.guard_radius = 0.0
	brain.set_physics_process(false)
	brain.soldier.global_position += Vector3(0, 3000, 0)


# ------------------------------------------------------------------ player capture

func _check_capture(battle: Battle, base: TribesBase, turret: TribesTurret) -> void:
	print(" player capture:")
	var s := battle.player as Infantry
	var pack_id := _repair_pack_id(s)
	_expect(pack_id != "", "the armour can wear a repair pack")
	if pack_id == "":
		return
	s.spawn_protection = 100000.0
	s.apply_spawn_protection()
	s.team = PLAYER_TEAM
	s.kit.pack_id = pack_id
	var enemy := _make_enemy(battle, turret)
	_expect(enemy != null, "an old-faction target in the turret's sight exists")
	_destroy(turret)
	_expect(not turret.alive and turret.team == OWNER_TEAM, "the owner's turret is down")
	s.global_position = turret.global_position + Vector3.UP * 0.5
	s.velocity = Vector3.ZERO
	s.kit.pack_active = true
	s.capacitor = s.capacitor_max
	_expect(RepairWork.find_pack_target(get_tree(), s) == turret, "the repair pack finds the downed enemy turret in reach")
	var captured := await _until(func() -> bool: return turret.is_captured(), REPAIR_WAIT)
	_expect(captured and turret.team == PLAYER_TEAM and turret.home_team == OWNER_TEAM,
		"repairing it captures it for the player's team (owner %d, now %d)" % [turret.home_team, turret.team])
	var up := await _until(func() -> bool: return turret.alive and turret.is_enabled(), REPAIR_WAIT)
	_expect(up, "the repair brings the turret back (%.0f / %.0f hp)" % [turret.hp, turret.max_hp])
	_expect(turret.is_working(), "a captured turret works on the capturer's own power")
	s.kit.pack_active = false
	s.global_position += Vector3(0, 3000, 0)
	if enemy:
		var hp0 := _health(enemy)
		var shots := turret.shots_fired
		turret._think_t = 0.0
		turret.energy = turret.energy_max      # the rebuilding hits drained its shield energy
		await _until(func() -> bool: return turret.shots_fired > shots or not enemy.alive, FIRE_WAIT)
		await get_tree().create_timer(HIT_WAIT, true, true).timeout
		_expect(turret.shots_fired > shots, "the captured turret fires at its old faction (%d shots)" % (turret.shots_fired - shots))
		_expect(not enemy.alive or _health(enemy) < hp0, "and hits it (%.0f -> %.0f)" % [hp0, _health(enemy)])
	# expiry
	turret.capture_left = 0.4
	var home := await _until(func() -> bool: return not turret.is_captured() and turret.team == OWNER_TEAM, 5.0)
	_expect(home, "when the time is up the turret returns to its owner")
	if enemy:
		enemy.team = OWNER_TEAM
		turret._think_t = 0.0
		await _frames(4)
		_expect(turret.find_target() == null, "back home it leaves its own faction alone")
	# destroyed while captured -> back to the owner
	turret.apply_capture(PLAYER_TEAM, TEST_CAPTURE_SECONDS)
	_expect(turret.team == PLAYER_TEAM and turret.is_captured(), "captured again")
	_destroy(turret)
	_expect(turret.team == OWNER_TEAM and not turret.is_captured() and not turret.alive,
		"a captured turret that is destroyed goes back to its owner as a ruin")
	# the owner's repair work after a capture takes it back
	turret.apply_capture(PLAYER_TEAM, TEST_CAPTURE_SECONDS)
	BaseCapture.apply_work(turret, OWNER_TEAM, 10.0)
	_expect(turret.team == OWNER_TEAM and not turret.is_captured(), "the owner repairing a captured object recaptures it")
	# an allied repairer does not capture
	_destroy(turret)
	TeamRelations.apply_stance(PLAYER_TEAM, OWNER_TEAM, TeamRelations.ALLIED)
	BaseCapture.apply_work(turret, PLAYER_TEAM, 10.0)
	_expect(turret.team == OWNER_TEAM and not turret.is_captured(), "an ally's repair work does not capture")
	TeamRelations.clear()
	s.team = OWNER_TEAM
	if is_instance_valid(enemy):
		enemy.global_position += Vector3(0, 3000, 0)
	turret.apply_repair(turret.max_hp)


## An old-faction (team 0) target the turret sees: a vehicle placed in its range, arc and sight.
func _make_enemy(battle: Battle, turret: TribesTurret) -> Herc:
	var enemy := _spawn_still_herc(battle, OWNER_TEAM, turret.global_position + Vector3(0, 500, 0))
	enemy.end_spawn_protection()
	for share in SPOT_SHARES:
		for k in SPOT_BEARINGS:
			var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * k / SPOT_BEARINGS)
			var p := turret.global_position + dir * turret.engage_range * float(share)
			p.y = MapBuilder.ground_height(battle, p) + 0.5
			enemy.global_position = p
			if turret.is_in_arc(p + Vector3.UP * TribesTurret.VEHICLE_AIM_HEIGHT - turret.make_muzzle()) and turret.has_line_of_sight(enemy):
				return enemy
	enemy.queue_free()
	return null


static func _health(h: Herc) -> float:
	return h.shield_front + h.shield_rear + h.integrity * 10000.0


func _repair_pack_id(s: Infantry) -> String:
	for id in InfantryGear.packs_of(s.armor):
		if str(InfantryGear.pack(id).get("effect", "")) == "repair":
			return str(id)
	return ""


# ------------------------------------------------------------------ captured generator

func _check_captured_generator(battle: Battle, base: TribesBase, turret: TribesTurret, gens: Array) -> void:
	print(" captured generator:")
	if not turret.alive:
		turret.apply_repair(turret.max_hp)
	for g in gens:
		if not g.alive:
			g.apply_repair(g.max_hp)
		_destroy(g)
	turret.apply_repair(turret.max_hp)
	await get_tree().create_timer(TribesBase.STATE_CHECK_SECONDS * 3.0, true, true).timeout
	_expect(not turret.powered, "with every generator down the owner's turret is off")
	var gen: TribesBaseObject = gens[0]
	gen.apply_capture(PLAYER_TEAM, TEST_CAPTURE_SECONDS)
	gen.apply_repair(gen.max_hp)
	await get_tree().create_timer(TribesBase.STATE_CHECK_SECONDS * 3.0, true, true).timeout
	_expect(gen.team == PLAYER_TEAM and gen.is_power_source() and gen.is_captured(), "the player holds the repaired generator")
	_expect(not turret.powered, "a captured generator does not power the owner's base")
	turret.apply_owner_team(PLAYER_TEAM)
	base.apply_power()
	_expect(turret.powered, "it powers the capturer's side of the base")
	turret.apply_owner_team(OWNER_TEAM)
	gen.apply_release()
	for g in gens:
		g.apply_repair(g.max_hp)
	await get_tree().create_timer(TribesBase.STATE_CHECK_SECONDS * 3.0, true, true).timeout
	_expect(gen.team == OWNER_TEAM and turret.powered, "released, the generator powers its owner's base again")


# ------------------------------------------------------------------ client sync

## A client gets the host's messages through these receiving functions: the team change, the repair, the destruction.
func _check_sync(base: TribesBase, turret: TribesTurret) -> void:
	print(" client sync:")
	var changes := []
	turret.state_changed.connect(func(o: TribesBaseObject) -> void: changes.append(o.team))
	turret._apply_team_state(PLAYER_TEAM, 30.0, OWNER_TEAM)
	_expect(turret.team == PLAYER_TEAM and turret.home_team == OWNER_TEAM and is_equal_approx(turret.capture_left, 30.0),
		"a client applies the host's capture (team, owner, time)")
	_expect(changes.has(PLAYER_TEAM), "and the object reports the change (power / targets follow)")
	turret._apply_destroyed()
	_expect(not turret.alive and turret.team == OWNER_TEAM and not turret.is_captured(),
		"a client sees a destroyed captured object go home")
	turret._apply_repaired(1.0)
	_expect(turret.alive and turret.is_enabled(), "and a repaired one stand up again")
	turret._apply_team_state(OWNER_TEAM, 0.0, OWNER_TEAM)
	_expect(turret.team == OWNER_TEAM and not turret.is_captured(), "the host's release returns it")


# ------------------------------------------------------------------ teammates and vehicles

## A parked Herc of `team` (its pilot stopped).
func _spawn_still_herc(battle: Battle, team: int, at: Vector3) -> Herc:
	var herc := battle.spawn_ai(TARGET_VEHICLE, team, Transform3D(Basis(), at), [], "Target", {"skill": 0.0})
	for c in herc.get_children():
		if c is AIPilot:
			(c as AIPilot).set_physics_process(false)
	herc.end_spawn_protection()
	return herc


## Hurts the first component of `unit` to HURT_SHARE of its hit points.
static func _hurt(unit: Herc) -> void:
	unit.components[0].hp = float(unit.components[0].max) * HURT_SHARE
	unit.integrity = HercDamage.integrity_of(unit.components)


static func _hp(unit: Herc) -> float:
	return float(unit.components[0].hp)


func _check_units(battle: Battle) -> void:
	print(" teammates and vehicles:")
	var s := battle.player as Infantry
	var pack_id := _repair_pack_id(s)
	if pack_id == "":
		return
	s.spawn_protection = 100000.0
	s.apply_spawn_protection()
	s.team = PLAYER_TEAM
	s.kit.pack_id = pack_id
	s.capacitor = s.capacitor_max
	s.velocity = Vector3.ZERO
	var beam := RepairRules.make_beam(pack_id)
	var spec := battle.infantry.bots.make_bot_spec(battle.infantry.pack, 0)
	spec.team = PLAYER_TEAM
	spec.xf = Transform3D(Basis(), s.global_position + Vector3(MATE_GAP, 0, 0))
	var brain := battle.infantry.bots.spawn_bot(spec, 0.5)
	_expect(brain != null, "a teammate soldier is fielded")
	if brain == null:
		return
	brain.set_physics_process(false)
	var mate := brain.soldier
	mate.spawn_protection = 100000.0
	mate.apply_spawn_protection()
	mate.global_position = s.global_position + Vector3(MATE_GAP, 0, 0)
	_hurt(mate)
	_hurt(s)
	var mate_hp := _hp(mate)
	var own_hp := _hp(s)
	s.kit.pack_active = true
	await _frames(3)
	_expect(RepairWork.find_pack_target(get_tree(), s) == mate, "the repair pack finds the hurt teammate in reach")
	var expected := RepairWork.make_pack_rate(s, mate)
	var by_pack := RepairRules.make_unit_rate_source(pack_id) == RepairRules.UNIT_RATE_PACK
	var wanted := float(InfantryGear.pack(pack_id).get("repair_per_s", 0.0)) if by_pack else float(beam.get("per_s", 0.0))
	_expect(is_equal_approx(expected, wanted), "his rate is the %s rate (%.0f /s)" % ["pack's own" if by_pack else "object", expected])
	await _until(func() -> bool: return _hp(mate) > mate_hp + expected * 0.5, REPAIR_WAIT)
	_expect(_hp(mate) > mate_hp, "the pack mends the teammate (%.0f -> %.0f)" % [mate_hp, _hp(mate)])
	_expect(is_equal_approx(_hp(s), own_hp), "and not its wearer meanwhile (%.0f)" % _hp(s))
	mate.components[0].hp = float(mate.components[0].max)
	mate.integrity = 1.0
	await _until(func() -> bool: return _hp(s) > own_hp, REPAIR_WAIT)
	_expect(_hp(s) > own_hp, "with nobody left to mend it heals its wearer (%.0f -> %.0f)" % [own_hp, _hp(s)])
	var ally := _spawn_still_herc(battle, PLAYER_TEAM, s.global_position + Vector3(MATE_GAP, 0, 0))
	ally.global_position = s.global_position + Vector3(MATE_GAP, 0, 0)
	_hurt(ally)
	var hull := _hp(ally)
	await _frames(3)
	_expect(RepairWork.find_pack_target(get_tree(), s) == ally, "it finds a hurt allied vehicle in reach too")
	await _until(func() -> bool: return _hp(ally) > hull, REPAIR_WAIT)
	_expect(_hp(ally) > hull, "the pack mends the vehicle (%.0f -> %.0f)" % [hull, _hp(ally)])
	ally.team = OWNER_TEAM
	await _frames(3)
	_expect(RepairWork.find_pack_target(get_tree(), s) != ally, "a hostile vehicle is not mended")
	s.kit.pack_active = false
	s.team = OWNER_TEAM
	ally.queue_free()
	mate.team = OWNER_TEAM         # the owner's side: neither hostile to the guard crew nor a target of the turret


# ------------------------------------------------------------------ Herc structures

## A structure of `team` beside `herc`, hurt to HURT_SHARE of its hit points.
func _make_structure(battle: Battle, herc: Herc, team: int, at_offset: Vector3, ss := false) -> Structure:
	var xf := Transform3D(Basis(), herc.global_position + at_offset)
	var st: Structure
	if ss:
		st = SSStructure.make(battle, SS_STRUCTURE, xf, battle.palette_id, team, STRUCTURE_HP)
	else:
		st = Structure.create(battle, ES1_STRUCTURE, xf, battle.palette_id, team, STRUCTURE_HP)
	st.hp = st.max_hp * HURT_SHARE
	st.integrity = HURT_SHARE
	return st


func _check_structures(battle: Battle) -> void:
	print(" Herc structures:")
	var herc := _spawn_still_herc(battle, PLAYER_TEAM, (battle.player as Node3D).global_position + Vector3(0, 0, 40))
	herc.owner_peer = HERC_PEER
	var director := battle.infantry.repair
	var share := float(RepairRules.hold("es1").get("hp_share_per_s", 0.0))
	var mine := _make_structure(battle, herc, PLAYER_TEAM, Vector3(STRUCTURE_GAP, 0, 0))
	director._apply_hold(HERC_PEER, true)
	await _until(func() -> bool: return mine.hp >= mine.max_hp * (HURT_SHARE + share * HOLD_WAIT), HOLD_WAIT * 4.0)
	director._apply_hold(HERC_PEER, false)
	_expect(mine.hp >= mine.max_hp * (HURT_SHARE + share * HOLD_WAIT * 0.5), "a Herc holding repair mends a friendly structure (%.0f / %.0f hp)" % [mine.hp, mine.max_hp])
	_expect(mine.team == PLAYER_TEAM and not mine.is_captured(), "and does not capture its own")
	var held := mine.hp
	await _frames(10)
	_expect(is_equal_approx(mine.hp, held), "releasing the action stops the work")
	mine.apply_repair(mine.max_hp)
	var foe := _make_structure(battle, herc, OWNER_TEAM, Vector3(0, 0, STRUCTURE_GAP * 2.0))
	director._apply_hold(HERC_PEER, true)
	await _until(func() -> bool: return foe.is_captured(), HOLD_WAIT * 4.0)
	director._apply_hold(HERC_PEER, false)
	_expect(foe.is_captured() and foe.team == PLAYER_TEAM and foe.home_team == OWNER_TEAM, "repairing a hostile structure captures it (owner %d, now %d)" % [foe.home_team, foe.team])
	BaseCapture.apply_work(foe, OWNER_TEAM, 1.0)
	_expect(foe.team == OWNER_TEAM and not foe.is_captured(), "its owner's repair work takes it back")
	foe.apply_capture(PLAYER_TEAM, TEST_CAPTURE_SECONDS)
	foe.capture_left = 0.3
	await _until(func() -> bool: return not foe.is_captured(), 2.0)
	_expect(foe.team == OWNER_TEAM, "a capture that runs out returns the structure")
	foe.apply_capture(PLAYER_TEAM, TEST_CAPTURE_SECONDS)
	foe.destroy(null)
	_expect(foe.team == OWNER_TEAM and not foe.is_captured() and not foe.alive, "a captured structure that is destroyed goes home as a ruin")
	var before := foe.hp
	BaseCapture.apply_work(foe, PLAYER_TEAM, 500.0)
	_expect(not foe.alive and foe.hp == before and not foe.is_captured(), "a destroyed Herc structure is not repaired back to life nor captured")
	var ss := _make_structure(battle, herc, OWNER_TEAM, Vector3(0, 0, -STRUCTURE_GAP * 2.0), true)
	BaseCapture.apply_work(ss, PLAYER_TEAM, 500.0)
	_expect(ss.is_captured() and ss.hp > STRUCTURE_HP * HURT_SHARE, "a Starsiege structure is repaired and captured by the same rules (%.0f hp)" % ss.hp)
	ss.apply_release()
	var rock := _make_structure(battle, herc, OWNER_TEAM, Vector3(-STRUCTURE_GAP * 2.0, 0, 0), true) as SSStructure
	rock.indestructible = true
	BaseCapture.apply_work(rock, PLAYER_TEAM, 500.0)
	_expect(rock.hp == rock.max_hp * HURT_SHARE and not rock.is_captured(), "an indestructible one takes no repair")
	for st in [mine, foe, ss, rock]:
		st.queue_free()
	herc.queue_free()

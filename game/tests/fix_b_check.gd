extends Node
## Playtest fix group B (docs/PLAYTEST_2026-10-11.md B1-B4), in real battles:
##   B1 collisions: the Earthsiege ramming rule (CollisionDamage) damages both vehicles and a rammed structure,
##      a vehicle running over a soldier damages him and is credited with his death;
##   B2 bounds: every map has a playable area (MapBounds); outside it a vehicle is warned, then damaged until it
##      dies (BattleBounds); a vehicle that fell below the world dies at once and respawns inside;
##   B3 teams: MapTeams counts the teams a map has starts for, a 4-team match on Four Way Dance starts each team
##      at its own starts, team kills decide a team match;
##   B4 structures: the mission structures of an Earthsiege 1, Earthsiege 2 and Starsiege mission are
##      targetable ("targetables", Herc-like fields) and destructible.
## godot --audio-driver Dummy --path game res://tests/fix_b_check.tscn [-- --shots=<dir>]  (shots need a window)

const VS_MAP := "tribes:Raindance"
const FOUR_TEAM_MAP := "tribes:FourWayDance"
const ES1_MISSION := "B0_C0_0A"
const ES2_MISSION := "C1_01"
## An Earthsiege 2 mission with a Cybrid base to destroy (C1_01 only has friendly structures).
const ES2_ENEMY_BASE_MISSION := "C1_07"
const SS_MISSION := "starsiege:HA4"
const SETTLE_FRAMES := 30
const TIME_SCALE := 4.0
const RAM_GAP := 14.0
## Off to one side so the chase view shows both Hercs, but close to head-on: the closing speed stays well above the
## ramming threshold (a 3 m offset at 4 m combined radius sat near it).
const RAM_SIDE_OFFSET := 1.0
## Physics frames the fell-through check may take (BattleBounds settles 2 s after a respawn).
const FELL_FRAMES := 240
const START_HEALTH := 10
const START_DAMAGE_TRIES := 8
const LOW_SOLDIER_HP := 50.0
const OUTSIDE_MARGIN := 60.0

var _failures := 0
var _shots := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	await get_tree().process_frame
	_check_team_data()
	_check_collision_rules()
	_check_ai_damage_scale()
	_check_bounds_data()
	var battle := await _start_battle({})   # an Earthsiege world: open, flat ground
	await _check_ramming(battle)
	await _check_run_over(battle)
	await _check_start_damage(battle)
	await _end(battle)
	battle = await _start_battle({"map": VS_MAP})
	await _check_bounds(battle)
	await _check_fell_through(battle)
	await _end(battle)
	await _check_four_teams()
	await _check_structures({"mode": "mission", "mission_name": ES1_MISSION}, "es1")
	await _check_structures({"mode": "mission", "mission": MissionCompiler.load_mission("es2:" + ES2_MISSION,
		PackedInt32Array(), 1, -1, {"resolve_texts": true}), "roster": _roster("es2:OUTLAW")}, "es2")
	await _check_structures({"mode": "mission", "mission": MissionCompiler.load_mission("es2:" + ES2_ENEMY_BASE_MISSION,
		PackedInt32Array(), 1, -1, {"resolve_texts": true}), "roster": _roster("es2:OUTLAW")}, "es2_enemy_base")
	await _check_structures({"mode": "mission", "mission_name": SS_MISSION, "roster": _roster("starsiege:pi_eman")}, "starsiege")
	Engine.time_scale = 1.0
	print("fix_b_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Waits `s` seconds of simulation time (physics steps; each one is time_scale / ticks long), never wall-clock time.
func _seconds(s: float) -> void:
	await _frames(int(ceilf(s * Engine.physics_ticks_per_second / maxf(Engine.time_scale, 0.001))))


func _roster(vehicle: String) -> Dictionary:
	return {1: {"name": "Tester", "vehicle": vehicle, "team": 0, "loadout": []}}


## DBSIM 0x1f82c: AI damage = table[difficulty] / 1024 in a single mission, table[3] in a campaign.
func _check_ai_damage_scale() -> void:
	var single := [0, 1, 2, 3].map(func(d): return EsDamageModel.make_ai_damage_scale({"mode": "single", "difficulty": d}))
	_expect(is_equal_approx(single[0], 2800.0 / 1024.0) and is_equal_approx(single[2], 1400.0 / 1024.0)
		and is_equal_approx(single[3], 1000.0 / 1024.0), "AI damage scale per difficulty %s" % [single])
	_expect(is_equal_approx(EsDamageModel.make_ai_damage_scale({"mode": "campaign", "difficulty": 0}), 1000.0 / 1024.0),
		"a campaign mission always uses the last table entry")


func _start_battle(extra: Dictionary) -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "start": BattleInfantry.START_IN_VEHICLE, "frag_limit": 50, "ai": []}, true)
	config.merge(extra, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _end(battle: Battle) -> void:
	Engine.time_scale = 1.0
	battle.queue_free()
	await _frames(4)


func _shot(battle: Battle, tag: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await get_tree().create_timer(0.3, true, false, true).timeout
	await RenderingServer.frame_post_draw
	var path := "%s/fix_b_%s.png" % [_shots, tag]
	battle.get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


## A parked AI vehicle (its brain removed) at `xf`, without spawn protection.
func _spawn_dummy(battle: Battle, vehicle: String, team: int, xf: Transform3D) -> Herc:
	var h := battle.spawn_ai(vehicle, team, xf, [], "Dummy", {"skill": 0.0})
	for c in h.get_children():
		if c is AIPilot:
			c.queue_free()
	h.end_spawn_protection()
	return h


## A transform `ahead` metres in front of `h`, on the ground, facing it.
static func _make_ahead(battle: Battle, h: Herc, ahead: float) -> Transform3D:
	var fwd := -h.global_basis.z
	fwd.y = 0.0
	var p := h.global_position + fwd.normalized() * ahead
	p.y = MapBuilder.ground_height(battle, p) + 0.5
	return Transform3D(Basis(Vector3.UP, h.rotation.y + PI), p)


static func _make_player_herc(battle: Battle) -> Herc:
	for h in battle.vehicles.values():
		if not (h is Infantry) and h.owner_peer == 1 and not h.has_meta("ai"):
			return h
	return null


# ------------------------------------------------------------------ B3 data, B1 rules

func _check_team_data() -> void:
	print("B3 map teams:")
	_expect(MapTeams.make_team_count({"id": FOUR_TEAM_MAP}) == 4, "Four Way Dance has starts for 4 teams")
	_expect(MapTeams.make_team_count({"map": VS_MAP}) == 2, "Raindance has 2 teams")
	_expect(MapTeams.make_team_count({"id": "starsiege:DM_Impact"}) == 4, "Starsiege DM_Impact: 4 team drop points")
	_expect(MapTeams.make_team_count({"id": "tribes:TripleThreat"}) == 3, "Triple Threat: 3 teams")
	_expect(MapTeams.make_team_count({}) == MapTeams.MIN_TEAMS, "no map: 2 teams")
	_expect(MapTeams.make_team_name(2, {"id": "starsiege:DM_Impact"}) == "Yellow", "Starsiege team 2 is yellow")
	_expect(MapTeams.make_team_color(0) != MapTeams.make_team_color(1), "team colours differ")


func _check_collision_rules() -> void:
	print("B1 collision rules:")
	var full := CollisionDamage.ES1_MPS_PER_SPEED_UNIT * Packs.code_to_world("es1") * 190.0
	var impact := CollisionDamage.make_ram_impact(6000.0, full, 6000.0, 0.0)
	_expect(absf(impact - 300.0 * (6000.0 * 190.0 / 1024.0) / 1024.0) < 1.0, "ram impact = 300 * mass * v / 1024^2 (%.0f)" % impact)
	_expect(impact > CollisionDamage.RAM_THRESHOLD, "a Raptor at full speed rams (> 200)")
	_expect(CollisionDamage.make_ram_impact(6000.0, full * 0.2, 6000.0, 0.0) < CollisionDamage.RAM_THRESHOLD, "a slow bump does not")
	_expect(CollisionDamage.make_ram_impact(6000.0, full, 6000.0, full) < 1.0, "same speed, same way: no impact")
	_expect(CollisionDamage.make_run_over_damage({}, 2.0) == 0.0, "walking pace: no run-over damage")
	_expect(CollisionDamage.make_run_over_damage({}, 25.0) > 1980.0, "25 m/s kills light armour (1980)")
	var own := {"run_over": {"threshold_mps": 10.0, "multiplier": 0.5}}
	_expect(CollisionDamage.make_run_over_damage(own, 9.0) == 0.0, "below the vehicle's own threshold: no damage")
	_expect(is_equal_approx(CollisionDamage.make_run_over_damage(own, 25.0), 25.0 * 0.5 * 3000.0),
		"vehicle's own rule: speed x multiplier x 3000")
	_check_installed_run_over("tribes2:BEOWULF")


## The installed Tribes 2 tank runs over by the collDamage* values imported from the user's scripts
## (RUN_OVER_DEFAULT when the pack predates the "run_over" field).
func _check_installed_run_over(id: String) -> void:
	var vdef: Dictionary = Packs.vehicles.get(id, {})
	if not vdef.get("run_over") is Dictionary:
		print("  (skip) %s has no imported run_over values; re-import tribes2" % id)
		return
	var rule: Dictionary = vdef.run_over
	_expect(float(rule.threshold_mps) > 0.0 and float(rule.multiplier) > 0.0, "%s run_over imported" % id)
	_expect(is_equal_approx(CollisionDamage.make_run_over_damage(vdef, 25.0), 25.0 * float(rule.multiplier) * 3000.0),
		"%s: speed x collDamageMultiplier x 3000" % id)


func _check_bounds_data() -> void:
	print("B2 bounds data:")
	var rect := MapBounds.make_rect_of({"min": [-700, -800], "max": [150, 100]})
	_expect(rect == Rect2(-700, -800, 850, 900), "map schema bounds -> area")
	var b := MapBounds.new()
	b.apply_area(rect)
	_expect(b.is_outside(Vector3(200, 0, 0)) and not b.is_outside(Vector3(0, 50, 0)), "outside / inside by x and z")
	_expect(BattleBounds._crossed(0.9, 1.1, 1.0) and not BattleBounds._crossed(1.1, 1.9, 1.0), "one tick per interval")
	_expect(is_equal_approx(BattleBounds.DAMAGE_DELAY, 4.0), "Tribes alertPlayer: damage 4 s after leaving")


# ------------------------------------------------------------------ B1 in battle

func _check_ramming(battle: Battle) -> void:
	print("B1 ramming:")
	var player := _make_player_herc(battle)
	_expect(player != null, "player Herc spawned")
	if player == null:
		return
	player.end_spawn_protection()
	var glancing := _make_ahead(battle, player, RAM_GAP)
	glancing.origin += player.global_basis.x * RAM_SIDE_OFFSET   # off to one side: the chase view shows both
	var target := _spawn_dummy(battle, "es1:RAPTOR", 1, glancing)
	await _frames(4)
	var hull_before := player.integrity
	battle.use_chase = true   # the shot shows both Hercs at the impact
	player.speed = player.max_speed
	player.throttle = 1.0
	for i in 120:
		await get_tree().physics_frame
		if target.integrity < 1.0:
			break
	_expect(target.integrity < 1.0, "the rammed Herc is damaged (%.2f)" % target.integrity)
	_expect(player.integrity < hull_before, "the rammer is damaged too (%.2f)" % player.integrity)
	await _shot(battle, "ram")
	battle.use_chase = false
	player.throttle = 0.0
	player.speed = 0.0
	var st := Structure.create(battle, "es1:BASES_1", _make_ahead(battle, player, RAM_GAP + 6.0), battle.palette_id, 1, 15000.0)
	target.global_position += Vector3(200, 0, 0)
	player.speed = player.max_speed
	player.throttle = 1.0
	for i in 150:
		await get_tree().physics_frame
		if st.hp < st.max_hp:
			break
	_expect(st.hp < st.max_hp and st.integrity < 1.0, "a rammed structure is damaged (%.0f / %.0f)" % [st.hp, st.max_hp])
	player.throttle = 0.0
	player.speed = 0.0
	st.queue_free()
	target.queue_free()
	battle.vehicles.erase(target.net_id)
	await _frames(2)


func _check_run_over(battle: Battle) -> void:
	print("B1 run over:")
	var player := _make_player_herc(battle)
	player.rotate_y(PI * 0.5)
	await _frames(2)
	var soldier := battle.spawn_soldier_for(77, 1, "Pedestrian", _make_ahead(battle, player, RAM_GAP))
	_expect(soldier != null, "a soldier stands in the Herc's way")
	if soldier == null:
		return
	soldier.end_spawn_protection()
	soldier.components[0].hp = LOW_SOLDIER_HP
	var kills_before := player.kills
	player.end_spawn_protection()
	player.speed = player.max_speed
	player.throttle = 1.0
	for i in 150:
		await get_tree().physics_frame
		if not soldier.alive:
			break
	_expect(not soldier.alive, "the soldier run over at %.1f m/s dies" % player.max_speed)
	_expect(player.kills == kills_before + 1, "the driver is credited with the kill")
	player.throttle = 0.0
	player.speed = 0.0


## A mission unit that starts damaged (record health < 100) starts damaged, never destroyed (it used to take a
## random component hit and could die at spawn, reported as "killed by the environment"): the Earthsiege pre-damage
## (DBSIM 0x12f20) blows a front quad off below 20 % and wounds the other parts by at most 87.5 %.
func _check_start_damage(battle: Battle) -> void:
	print("mission units starting damaged:")
	var player := _make_player_herc(battle)
	var all_alive := true
	var legs_lost := true
	var cockpits_whole := true
	var worst := 1.0
	for k in START_DAMAGE_TRIES:
		var xf := _make_ahead(battle, player, 400.0 + 30.0 * k)
		var h := battle.spawn_ai("es1:SCORPION", 1, xf, [], "Hurt", {"skill": 0.0, "group": 0, "health": START_HEALTH})
		all_alive = all_alive and h.alive
		worst = minf(worst, h.integrity)
		legs_lost = legs_lost and (h.components[7].hp <= 0.0 or h.components[8].hp <= 0.0)
		cockpits_whole = cockpits_whole and h.components[0].hp > 0.0 and h.components[1].hp > 0.0
		h.queue_free()
		battle.vehicles.erase(h.net_id)
	_expect(all_alive, "%d Scorpions at health %d all start alive" % [START_DAMAGE_TRIES, START_HEALTH])
	_expect(legs_lost and cockpits_whole and worst < 1.0, "each lost a front quad, both cockpits intact (lowest integrity %.2f)" % worst)
	_expect(HercDamage.make_start_level(85) == 0 and HercDamage.make_start_level(65) == 50 and HercDamage.make_start_level(45) == 80
		and HercDamage.make_start_level(25) == 120 and HercDamage.make_start_level(5) == 150, "health -> damage level as DBSIM 0x12f20")
	await _frames(2)


# ------------------------------------------------------------------ B2

func _check_bounds(battle: Battle) -> void:
	print("B2 bounds:")
	var b := battle.bounds.bounds
	_expect(b.has_area, "Raindance has a playable area (%s)" % b.area)
	var player := _make_player_herc(battle)
	_expect(battle.spawner.spawn_points.all(func(t: Transform3D) -> bool: return not b.is_outside(t.origin)),
		"every vehicle start is inside the area")
	var out := Vector3(b.area.end.x + OUTSIDE_MARGIN, 0, b.area.get_center().y)
	out.y = MapBuilder.ground_height(battle, out) + 1.0
	var dummy := _spawn_dummy(battle, "es1:RAPTOR", 1, Transform3D(Basis(), out))
	player.global_position = out + Vector3(0, 0, 30)
	player.global_position.y = MapBuilder.ground_height(battle, player.global_position) + 1.0
	player.end_spawn_protection()
	Engine.time_scale = TIME_SCALE
	await _seconds(BattleBounds.SETTLE_SECONDS + BattleBounds.DAMAGE_DELAY - 0.5)
	_expect(dummy.alive and is_equal_approx(dummy.integrity, 1.0), "warned, not yet damaged before %.1f s" % BattleBounds.DAMAGE_DELAY)
	_expect(battle.bounds.make_out_seconds(player) > 0.0, "the player is counted outside")
	await _shot(battle, "out_of_bounds")
	player.global_position = battle.spawner.spawn_points[0].origin
	await _frames(3)
	_expect(battle.bounds.make_out_seconds(player) == 0.0, "back inside: the count stops")
	await _seconds(2.0)
	_expect(dummy.integrity < 1.0, "then damaged every second (%.2f)" % dummy.integrity)
	await _seconds(14.0)
	_expect(not dummy.alive, "outside long enough it is destroyed")
	Engine.time_scale = 1.0


func _check_fell_through(battle: Battle) -> void:
	print("B2 fell out of the world:")
	var player := battle.player
	_expect(player != null, "the player's vehicle is there")
	if player == null:
		return
	await _until_alive(player)   # an earlier check may have killed it: wait for its respawn
	player.end_spawn_protection()
	player.global_position.y = battle.bounds.bounds.floor_y - 50.0
	for i in FELL_FRAMES:
		await get_tree().physics_frame
		if not player.alive:
			break
		player.global_position.y = battle.bounds.bounds.floor_y - 50.0   # held there until BattleBounds acts
	_expect(not player.alive, "a Herc below the world floor dies")
	await _until_alive(player)
	_expect(player.alive and not battle.bounds.bounds.is_outside(player.global_position)
		and player.global_position.y > battle.bounds.bounds.floor_y, "and respawns inside the map")


## Waits (physics frames, at most RESPAWN_TIME + 2 s of simulation) until `h` is alive.
func _until_alive(h: Herc) -> void:
	for i in int((BattleRules.RESPAWN_TIME + 2.0) * Engine.physics_ticks_per_second / maxf(Engine.time_scale, 0.001)):
		if h.alive:
			return
		await get_tree().physics_frame


# ------------------------------------------------------------------ B3

func _check_four_teams() -> void:
	print("B3 four teams on %s:" % FOUR_TEAM_MAP)
	var ai := []
	for team in [1, 2, 3]:
		ai.append({"vehicle": "es1:SCORPION", "team": team, "skill": 0.0, "name": "Team%d" % team})
	var battle := await _start_battle({"map": FOUR_TEAM_MAP, "teams": true, "team_count": 4, "ai": ai})
	var points: Dictionary = battle.spawner.team_points
	_expect(points.size() == 4, "the map gives starts for teams 0..3 (%s)" % [points.keys()])
	var placed := 0
	for v in battle.vehicles.values():
		if v is Infantry or not points.has(v.team):
			continue
		placed += 1
		_expect(_nearest_team(points, v.global_position) == v.team, "%s (team %d) starts at its team's starts" % [v.display_name, v.team])
	_expect(placed == 4, "one vehicle per team placed (%d)" % placed)
	_expect(BattleRules.plays_in_teams(battle.config), "a 4-team match is a team match")
	_expect(BattleRules.make_objective_text(battle.config).contains("4 teams"), "the objective names the teams")
	await _check_team_colors(battle)
	await _shot(battle, "four_teams")
	await _end(battle)


## The opposing teams show in their own colours (radar, target box) and stand in front of the player for the shot.
func _check_team_colors(battle: Battle) -> void:
	var player := _make_player_herc(battle)
	var colors := {}
	var k := 0
	for v in battle.vehicles.values():
		if v is Infantry or v == player:
			continue
		colors[TargetInfo.make_iff_color(player, v)] = true
		var p := _make_ahead(battle, player, 90.0 + 30.0 * k).origin + player.global_basis.x * (k - 1) * 45.0
		p.y = MapBuilder.ground_height(battle, p) + 0.5
		v.global_position = p
		k += 1
	_expect(MapTeams.shows_team_colors and colors.size() == 3, "three opposing teams, three radar colours (%d)" % colors.size())
	player.target = null   # every dot in its team colour (a target blinks)
	await _frames(6)
	for v in battle.vehicles.values():
		if not (v is Infantry) and v != player:
			print("    team %d at %s, %.0f m" % [v.team, v.global_position, v.global_position.distance_to(player.global_position)])


static func _nearest_team(points: Dictionary, p: Vector3) -> int:
	var best := -1
	var best_d := INF
	for team in points:
		for t in points[team]:
			var d := Vector2(p.x - t.origin.x, p.z - t.origin.z).length()
			if d < best_d:
				best_d = d
				best = team
	return best


# ------------------------------------------------------------------ B4

func _check_structures(extra: Dictionary, label: String) -> void:
	print("B4 %s mission structures:" % label)
	var battle := await _start_battle(extra)
	await _frames(SETTLE_FRAMES)
	var structures: Array = battle.mission.structures if battle.mission else []
	_expect(not structures.is_empty(), "%s mission has structures (%d)" % [label, structures.size()])
	var targetable := get_tree().get_nodes_in_group(Structure.TARGET_GROUP)
	var destructible := structures.filter(func(s) -> bool: return targetable.has(s))
	var scenery := structures.size() - destructible.size()
	_expect(not destructible.is_empty() and (label == "starsiege" or scenery == 0),
		"mission structures are targetable (%d of %d; Starsiege neutral scenery is not)" % [destructible.size(), structures.size()])
	var player := battle.player
	var st: Structure = null
	for s in destructible:   # the first hostile one the player can see from its approach (others may stand in front)
		if s.alive and player != null and TeamRelations.is_hostile(player.team, s.team):
			st = s
			await _place_camera_on(battle, player, s)
			if Targeting.is_visible_to(player, s):
				break
	if st == null and label == "es2":
		print("  (no hostile structure in this mission: its structures are the player's own)")
		await _end(battle)
		return
	_expect(st != null and st.display_name != "", "a hostile destructible one with a name (%s)" % (st.display_name if st else "-"))
	if st == null or player == null:
		await _end(battle)
		return
	_expect(Targeting.make_candidates(player).has(st), "it is a target candidate (Targeting)")
	_expect(await _cycle_to(player, st), "target cycling (target_next) reaches it (%.0f deg off, %s, %.0f m, front %d)" % [
		rad_to_deg(Targeting.make_off_angle(player, st)), "visible" if Targeting.is_visible_to(player, st) else "hidden",
		player.global_position.distance_to(st.global_position), Targeting.make_front_set(player).size()])
	var before := st.integrity
	st.apply_hit(0.0, st.hp * 0.5, player, st.global_position)
	_expect(absf(st.integrity - before * 0.5) < 0.02, "a hit shows on its integrity (%.2f -> %.2f)" % [before, st.integrity])
	await _shot(battle, "structure_%s" % label)
	st.apply_hit(0.0, st.max_hp, player, st.global_position)
	await _frames(10)
	_expect(not st.alive and st.integrity == 0.0, "and it is destroyed")
	await _shot(battle, "structure_%s_destroyed" % label)
	await _end(battle)


## Presses target_next (PlayerPilot.next_enemy) until `st` is the target; false when the cycle never reaches it.
func _cycle_to(player: Herc, st: Structure) -> bool:
	player.target = null
	for i in Targeting.make_candidates(player).size() + 1:
		player.target = Targeting.pick_next(player, player.target)
		if player.target == st:
			await _frames(2)
			return true
	return false


## Turns the player to face the structure so a screenshot shows it targeted.
func _place_camera_on(battle: Battle, player: Herc, st: Structure) -> void:
	var to := st.global_position - player.global_position
	to.y = 0.0
	if to.length() > 200.0:
		var p := st.global_position - to.normalized() * 120.0
		p.y = MapBuilder.ground_height(battle, p) + 1.0
		player.global_position = p
	player.rotation.y = atan2(-to.x, -to.z)
	await _frames(4)

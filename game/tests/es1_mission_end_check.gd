extends Node
## Earthsiege 1 mission end rules in the Battle runtime (MissionRuntime + ES1WinRules, playtest E1):
##   Godot --headless --audio-driver Dummy --path game res://tests/es1_mission_end_check.tscn
## * B0_C0_4A (EMP cannon pilot rescue, type 5 "guard herc 4"): killing a Cybrid fires its death region and
##   wakes the next wave; once every Cybrid is down and the pilot is safe the mission ends with success.
## * B0_C0_4A with the pilot destroyed: the guarded target is lost, the mission fails.
## * B0_C0_3B (protect the base, type 4 "guard group 1"): not won while the waves still come; won once
##   they are all destroyed; lost when the base is destroyed.
## * B0_C0_1A (type 0, co-op roster of two pilots, playtest E3): the second pilot walks the nav points and every
##   hostile unit (the waves their death regions wake) and structure is destroyed: the mission ends in success.
## * Objective flags (DBSIM 0x15f80): B0_C0_1A (recon) is met once the player targets the squad's order target;
##   B0_C0_3A (datalink) once the player stands close to the listening post, facing it, through the link timer.
## * Escorts (type 7: B0_C2_00, B0_C2_11, B0_C4_00, B0_C4_50, B0_C6_2A): with the player invulnerable at the meeting
##   point, then behind the escort, and every other hostile destroyed, the escorted unit travels its whole path and
##   the mission is won (mission.md section 5: the target reached the end of its path alive). Progress is logged.

const ROSTER := {1: {"name": "Tester", "vehicle": "es1:RAPTOR", "team": 0, "loadout": []}}
const SETTLE_FRAMES := 20
const END_WAIT_FRAMES := 60
## Herc record of the pilot to rescue in B0_C0_4A (MSN group 0 target).
const RESCUE_PILOT := 4
const RESCUE_WAVE_GROUPS := [4, 5, 6]
const MAX_KILL_ROUNDS := 20
const CASES := 12
const ESCORT_MISSIONS := ["B0_C2_00", "B0_C2_11", "B0_C4_00", "B0_C4_50", "B0_C6_2A"]
## Sim seconds an escort may take (the slowest original route is about 520 s at the escort's patrol speed).
const ESCORT_TIMEOUT := 900.0
## Escorts run at this time scale (the result does not depend on it; the run takes a quarter of the wall time).
const ESCORT_TIME_SCALE := 4.0
## The player waits this far behind the escort leader (metres).
const ESCORT_TRAIL := 40.0
const ESCORT_LOG_SECONDS := 60.0
## Every escorted Herc (leader and wingmen) must get at least this far from where it appeared (none trapped).
const ESCORT_MIN_TRAVEL := 50.0
## Datalink: the player is placed this far in front of the order target and waits at most DATALINK_WAIT seconds.
const DATALINK_STANDOFF := 20.0
const DATALINK_WAIT := 20.0
const COOP_ROSTER := {1: {"name": "Host", "vehicle": "es1:RAPTOR", "team": 0, "loadout": []},
	2: {"name": "Client", "vehicle": "es1:RAPTOR", "team": 0, "loadout": []}}
const COOP_ROUND_FRAMES := 10
const COOP_TIMEOUT_ROUNDS := 300

var _failures := 0
var _cases_done := 0


func _ready() -> void:
	await get_tree().process_frame
	await _check_rescue_won()
	await _check_rescue_pilot_lost()
	await _check_base_defence_won()
	await _check_base_defence_lost()
	await _check_coop_destroy_all()
	await _check_recon_flag()
	await _check_datalink_flag()
	for name in ESCORT_MISSIONS:
		await _check_escort(name)
	_expect(_cases_done == CASES, "all %d cases ran to the end (%d)" % [CASES, _cases_done])
	print("es1_mission_end_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


# ------------------------------------------------------------------ battle helpers

func _start(mission_name: String, roster := ROSTER) -> Battle:
	var mdef := MissionCompiler.load_mission(mission_name, PackedInt32Array(), 1, -1, {"resolve_texts": true})
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "respawn": false, "mission": mdef, "roster": roster.duplicate(true)}
	battle.set_meta("result", {})
	battle.match_finished.connect(func(r): battle.get_meta("result").merge(r))
	get_tree().root.add_child(battle)
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	_protect_player(battle)
	return battle


func _end(battle: Battle) -> void:
	_cases_done += 1
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _protect_player(battle: Battle) -> void:
	var p: Herc = battle.player
	if p and is_instance_valid(p):
		p.shield_front = p.shield_max
		p.shield_rear = p.shield_max
		for c in p.components:
			c.hp = c.max


func _protect_structure(s: Node3D) -> void:
	if s is Structure and (s as Structure).alive:
		(s as Structure).hp = (s as Structure).max_hp
		(s as Structure).integrity = 1.0


## Destroys every living Cybrid vehicle (their death regions wake the next waves).
func _kill_hostiles() -> void:
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v.team != 0 and v.alive:
			await _destroy(v)


## Hits `h` until it is destroyed (each hit wrecks one component).
func _destroy(h: Herc) -> void:
	for i in END_WAIT_FRAMES * 4:
		if h == null or not h.alive:
			return
		h.apply_hit(1e6, 1e6, null, h.global_position)
		await get_tree().physics_frame


func _hostiles_left(battle: Battle) -> int:
	var n := 0
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v.team != 0 and v.alive:
			n += 1
	for gi in battle.mission.dormant_groups:
		if int(battle.mission.m.groups[gi].get("team", 1)) != 0:
			n += 1
	return n


## Kills the waves round by round until none is left; returns the rounds needed (-1: never cleared).
func _clear_waves(battle: Battle) -> int:
	for round in MAX_KILL_ROUNDS:
		if _hostiles_left(battle) == 0:
			return round
		_protect_player(battle)
		await _kill_hostiles()
		await get_tree().physics_frame
	return -1


func _wait_end(battle: Battle) -> Dictionary:
	for i in END_WAIT_FRAMES:
		_protect_player(battle)
		await get_tree().physics_frame
		if not battle.get_meta("result").is_empty():
			break
	return battle.get_meta("result")


# ------------------------------------------------------------------ checks

func _check_rescue_won() -> void:
	print("B0_C0_4A pilot rescue, all Cybrids destroyed:")
	var battle := await _start("B0_C0_4A")
	var rt: MissionRuntime = battle.mission
	var pilot: Node = rt.unit_index.get("herc:%d" % RESCUE_PILOT)
	_expect(pilot != null and pilot.alive, "the pilot's Herc (record %d) is spawned and registered" % RESCUE_PILOT)
	_expect(RESCUE_WAVE_GROUPS.all(func(g): return rt.dormant_groups.has(g)), "the reinforcement waves wait for their death regions")
	_expect(not rt.win_rules.objective_met(), "not won while Cybrids hunt the pilot")
	var rounds := await _clear_waves(battle)
	_expect(rounds > 1, "each kill wakes the next wave (cleared in %d rounds)" % rounds)
	_expect(rt.dormant_groups.is_empty(), "every wave was woken")
	_expect(rt.win_rules.target_safe(rt.win_rules.squad_target()), "the pilot is safe once the Cybrids are down")
	var result := await _wait_end(battle)
	_expect(not result.is_empty() and bool(result.get("success", false)), "the mission ends with success (%s)" % str(result.get("code", "-")))
	_expect(rt.mission_vars[13] == 1, "var13 (prototype recovered) is set by the search region")
	await _end(battle)


func _check_rescue_pilot_lost() -> void:
	print("B0_C0_4A pilot destroyed:")
	var battle := await _start("B0_C0_4A")
	var rt: MissionRuntime = battle.mission
	var pilot: Herc = rt.unit_index.get("herc:%d" % RESCUE_PILOT)
	await _destroy(pilot)
	var result := await _wait_end(battle)
	_expect(not result.is_empty() and not bool(result.get("success", true)), "losing the pilot fails the mission")
	_expect(Campaign.is_failure(int(result.get("code", 0)), 5), "the failure code counts as failed for the campaign (%s)" % str(result.get("code", "-")))
	_expect(rt.mission_vars[13] == 0, "the pilot's death clears var13 (prototype lost)")
	await _end(battle)


func _check_base_defence_won() -> void:
	print("B0_C0_3B base defence, all waves destroyed:")
	var battle := await _start("B0_C0_3B")
	var rt: MissionRuntime = battle.mission
	_expect(battle.get_meta("result").is_empty(), "the mission does not end before the attack")
	_expect(not rt.win_rules.objective_met(), "not won while the first wave targets the base")
	var rounds := await _clear_waves(battle)
	_expect(rounds > 1, "the waves arrive one after another (cleared in %d rounds)" % rounds)
	var result := await _wait_end(battle)
	_expect(not result.is_empty() and bool(result.get("success", false)), "the defence ends with success")
	await _end(battle)


func _check_base_defence_lost() -> void:
	print("B0_C0_3B base destroyed:")
	var battle := await _start("B0_C0_3B")
	var rt: MissionRuntime = battle.mission
	for s in rt.structures:
		if s.team == 0 and s.alive:
			s.destroy(null)
	var result := await _wait_end(battle)
	_expect(not result.is_empty() and not bool(result.get("success", true)), "losing the base fails the mission")
	await _end(battle)


func _check_coop_destroy_all() -> void:
	print("B0_C0_1A co-op: the second pilot's nav points, every hostile destroyed:")
	var battle := await _start("B0_C0_1A", COOP_ROSTER)
	var rt: MissionRuntime = battle.mission
	var second: Herc = null
	for v in get_tree().get_nodes_in_group("vehicles"):
		if MissionRuntime._is_human_player(v) and v != battle.player:
			second = v
	_expect(second != null, "the second pilot's Herc is spawned")
	var walker: Herc = second if second else battle.player
	for round in COOP_TIMEOUT_ROUNDS:
		if not battle.get_meta("result").is_empty():
			break
		_protect_player(battle)
		if rt.nav_index < rt.nav_points.size():
			walker.global_position = rt.nav_points[rt.nav_index] + Vector3.UP * 2.0
		await _kill_hostiles()
		for st in rt.structures:
			if st.team != 0 and st.alive:
				st.destroy(battle.player)
		for i in COOP_ROUND_FRAMES:
			await get_tree().physics_frame
	var result: Dictionary = battle.get_meta("result")
	_expect(rt.nav_index >= rt.nav_points.size(), "the second pilot reached every nav point")
	_expect(not result.is_empty() and bool(result.get("success", false)), "the mission ends in success (dormant left: %s)" % [rt.dormant_groups.keys()])
	await _end(battle)


func _check_recon_flag() -> void:
	print("B0_C0_1A recon: target the squad's order target:")
	var battle := await _start("B0_C0_1A")
	var rt: MissionRuntime = battle.mission
	var wanted := rt.target_nodes(rt.win_rules.squad_target())
	_expect(not wanted.is_empty(), "the order target is on the map")
	_expect(not rt.win_rules.objective_met(), "not met before the target is identified")
	if not wanted.is_empty():
		battle.player.target = wanted[0]
	for i in 30:
		await get_tree().physics_frame
	_expect(rt.win_rules.recon_flag and rt.win_rules.objective_met(), "targeting it sets the recon flag and meets the objective")
	await _end(battle)


func _check_datalink_flag() -> void:
	print("B0_C0_3A datalink: stand at the listening post, facing it:")
	var battle := await _start("B0_C0_3A")
	var rt: MissionRuntime = battle.mission
	var link: Node3D = rt.win_rules._datalink_node()
	_expect(link != null, "the datalink target is on the map")
	_expect(not rt.win_rules.objective_met(), "not met before the link")
	var frames := 0
	var max_frames := int(DATALINK_WAIT * Engine.physics_ticks_per_second)
	while link != null and not rt.win_rules.datalink_flag and frames < max_frames:
		frames += 1
		_protect_player(battle)
		_protect_structure(link)   # the Cybrids' fire at the player also lands on their own listening post
		var p: Herc = battle.player
		var back := Vector3(0, 0, DATALINK_STANDOFF)
		p.global_position = link.global_position + back + Vector3.UP * 2.0
		p.velocity = Vector3.ZERO
		p.throttle = 0.0
		p.look_at(Vector3(link.global_position.x, p.global_position.y, link.global_position.z))
		p.torso_yaw = 0.0
		await get_tree().physics_frame
	_expect(rt.win_rules.datalink_flag and rt.win_rules.objective_met(), "the link completes after %.1f s of game time" % (float(frames) / Engine.physics_ticks_per_second))
	await _end(battle)


# ------------------------------------------------------------------ escorts

func _check_escort(mission_name: String) -> void:
	print("%s escort: the escorted unit travels its path to the end:" % mission_name)
	var battle := await _start(mission_name)
	var rt: MissionRuntime = battle.mission
	var t = rt.win_rules.squad_target()
	var meeting: Vector3 = rt.nav_points[mini(1, rt.nav_points.size() - 1)]
	Engine.time_scale = ESCORT_TIME_SCALE
	var sim := 0.0
	var next_log := 0.0
	var starts := {}     # escorted Herc -> where it appeared
	while sim < ESCORT_TIMEOUT and battle.get_meta("result").is_empty():
		_protect_player(battle)
		var escorted := _living(rt.target_nodes(t))
		for n in escorted:
			if not starts.has(n):
				starts[n] = n.global_position
		_clear_hostiles_except(escorted)
		_hold_player(battle, meeting if escorted.is_empty() else _trail_point(escorted[0]))
		await get_tree().physics_frame
		sim += get_physics_process_delta_time()
		if sim >= next_log:
			next_log += ESCORT_LOG_SECONDS
			print("    t %4.0f s  %s" % [sim, _escort_progress(escorted)])
	Engine.time_scale = 1.0
	var result: Dictionary = battle.get_meta("result")
	_expect(_living(rt.target_nodes(t)).any(func(n): return bool(n.get_meta(AIPilot.PATH_DONE_META, false))),
		"the escorted unit reached the end of its path (%.0f s)" % sim)
	_expect(bool(result.get("success", false)), "the mission is won (code %s)" % str(result.get("code", "-")))
	var trapped := _make_trapped_names(starts)
	_expect(trapped.is_empty(), "no escorted Herc stayed trapped where it appeared (%s)" % [trapped])
	await _end(battle)


## Names of the living Hercs of `starts` (Herc -> where it appeared) that never got ESCORT_MIN_TRAVEL away.
static func _make_trapped_names(starts: Dictionary) -> Array:
	var out := []
	for n in starts:
		if is_instance_valid(n) and n.alive and n.global_position.distance_to(starts[n]) < ESCORT_MIN_TRAVEL:
			out.append(str(n.name))
	return out


static func _living(nodes: Array) -> Array:
	return nodes.filter(func(n): return is_instance_valid(n) and n.alive)


func _clear_hostiles_except(keep: Array) -> void:
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v.team != 0 and v.alive and not keep.has(v):
			v.apply_hit(1e6, 1e6, null, v.global_position)


## Holds the player at `at` (on the ground: his own height), still.
func _hold_player(battle: Battle, at: Vector3) -> void:
	var p: Herc = battle.player
	if p and is_instance_valid(p):
		p.global_position = Vector3(at.x, p.global_position.y, at.z)
		p.velocity = Vector3.ZERO
		p.throttle = 0.0


func _trail_point(leader: Node3D) -> Vector3:
	return leader.global_position + leader.global_basis.z * ESCORT_TRAIL


func _escort_progress(escorted: Array) -> String:
	if escorted.is_empty():
		return "escort not on the map yet"
	var parts := PackedStringArray()
	for n in escorted:
		var h := n as Herc
		parts.append("%s at (%.0f, %.0f) %.1f m/s%s" % [h.name, h.global_position.x, h.global_position.z,
			h.velocity.length(), " path done" if h.get_meta(AIPilot.PATH_DONE_META, false) else ""])
	return "; ".join(parts)

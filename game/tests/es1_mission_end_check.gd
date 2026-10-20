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
const CASES := 17
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
	await _check_datalink_interrupt()
	for types in [ES1WinRules.NAV_TYPES, ES1WinRules.DESTROY_TYPES]:
		var name := _first_mission_of_types(types)
		_expect(name != "", "a mission of type %s exists" % [types])
		if name != "":
			await _check_type_won(name, types)
			await _check_player_lost(name)
	var skip_escorts := OS.get_cmdline_user_args().has("--skip-escorts")   # quick run: the escorts take minutes
	if not skip_escorts:
		for name in ESCORT_MISSIONS:
			await _check_escort(name)
	var cases := CASES - (ESCORT_MISSIONS.size() if skip_escorts else 0)
	_expect(_cases_done == cases, "all %d cases ran to the end (%d)" % [cases, _cases_done])
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
	# recon is won on its flag (a player targets the order target) plus safety, not by clearing the area
	_expect(not rt.win_rules.objective_met(), "not met before the order target is identified")
	var wanted := rt.target_nodes(rt.win_rules.squad_target())
	if not wanted.is_empty():
		battle.player.target = wanted[0]
	for i in 30:
		await get_tree().physics_frame
	_expect(rt.win_rules.recon_flag, "the flag latches before the target is destroyed")
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
	var log := []
	_record_messages(battle, log)
	var wanted := rt.target_nodes(rt.win_rules.squad_target())
	_expect(not wanted.is_empty(), "the order target is on the map")
	_expect(not rt.win_rules.objective_met(), "not met before the target is identified")
	if not wanted.is_empty():
		battle.player.target = wanted[0]
	for i in 30:
		await get_tree().physics_frame
	_expect(rt.win_rules.recon_flag and rt.win_rules.objective_met(), "targeting it sets the recon flag and meets the objective")
	_expect(_all_texts(log).has("Target identified."), "the identification is announced")
	await _end(battle)


## Holds the player `standoff` metres from the link, facing it (or turned `turn` radians away), still.
func _hold_at_link(battle: Battle, link: Node3D, standoff: float, turn := 0.0) -> void:
	var p: Herc = battle.player
	_protect_player(battle)
	_protect_structure(link)   # the Cybrids' fire at the player also lands on their own listening post
	p.global_position = link.global_position + Vector3(0, 2.0, standoff)
	p.velocity = Vector3.ZERO
	p.throttle = 0.0
	p.look_at(Vector3(link.global_position.x, p.global_position.y, link.global_position.z))
	p.rotate_y(turn)
	p.torso_yaw = 0.0


## System-channel texts the battle shows from now on, as [physics frame, text].
func _record_messages(battle: Battle, into: Array) -> void:
	battle.overlay.chat_log.added.connect(func(e: Dictionary):
		if e.get("channel") == ChatChannels.SYSTEM:
			into.append([Engine.get_physics_frames(), str(e.get("text"))]))


## The datalink texts (stages and abort) of a message log, in order.
func _all_texts(log: Array) -> Array:
	return log.map(func(e): return e[1])


func _texts(log: Array) -> Array:
	var link_texts: Array = ES1WinRules.DATALINK_TEXTS + [ES1WinRules.DATALINK_ABORT_TEXT]
	return log.map(func(e): return e[1]).filter(func(t): return t in link_texts)


func _check_datalink_flag() -> void:
	print("B0_C0_3A datalink (DBSIM 0x15f80): stages, messages, win only on the link plus safety:")
	var battle := await _start("B0_C0_3A")
	var rt: MissionRuntime = battle.mission
	var log := []
	_record_messages(battle, log)
	var link: Node3D = rt.win_rules._datalink_node()
	_expect(link != null, "the datalink target is on the map")
	_expect(not rt.win_rules.objective_met(), "not met before the link")
	var first := Engine.get_physics_frames()
	var frames := 0
	while link != null and not rt.win_rules.datalink_flag and frames < int(DATALINK_WAIT * Engine.physics_ticks_per_second):
		frames += 1
		_hold_at_link(battle, link, DATALINK_STANDOFF)
		await get_tree().physics_frame
	var texts := _texts(log).filter(func(t): return t in ES1WinRules.DATALINK_TEXTS)
	_expect(texts == ES1WinRules.DATALINK_TEXTS, "messages in order: %s" % [texts])
	var times := log.filter(func(e): return e[1] in ES1WinRules.DATALINK_TEXTS).map(func(e): return float(e[0] - first) / Engine.physics_ticks_per_second)
	# the rules tick runs a few times a second, so each stage lands within a tick of 0 / 5 / 10 s
	_expect(times.size() == 4 and absf(times[1] - times[0] - 5.0) < 0.6 and absf(times[2] - times[0] - 10.0) < 0.8 and times[3] - times[2] < 0.6,
		"stage times 0 / 5 / 10 s, completion right after: %s" % [times])
	_expect(rt.win_rules.datalink_flag and rt.win_rules.objective_met(), "the link sets the flag and meets the objective")
	_expect(not _texts(log).has(ES1WinRules.DATALINK_ABORT_TEXT), "no abort message while holding the position")
	# the mission ends only with the players safe (status 9 vs 10)
	for i in END_WAIT_FRAMES:
		_hold_at_link(battle, link, DATALINK_STANDOFF)
		await get_tree().physics_frame
	var result: Dictionary = battle.get_meta("result")
	if rt.win_rules.players_safe():
		_expect(bool(result.get("success", false)), "link done and safe: the mission is won")
	else:
		_expect(result.is_empty(), "link done but an enemy is close: the mission goes on")
		await _clear_waves(battle)
		result = await _wait_end(battle)
		_expect(bool(result.get("success", false)), "once the players are safe the mission is won")
	await _end(battle)


func _check_datalink_interrupt() -> void:
	print("B0_C0_3A datalink interrupted: turning away or leaving restarts from stage 0:")
	var battle := await _start("B0_C0_3A")
	var rt: MissionRuntime = battle.mission
	var log := []
	_record_messages(battle, log)
	var link: Node3D = rt.win_rules._datalink_node()
	var ticks := Engine.physics_ticks_per_second
	for i in int(7.0 * ticks):
		_hold_at_link(battle, link, DATALINK_STANDOFF)
		await get_tree().physics_frame
	_expect(_texts(log) == ES1WinRules.DATALINK_TEXTS.slice(0, 2), "after 7 s stages 0 and 1 have spoken: %s" % [_texts(log)])
	for i in int(1.0 * ticks):   # facing away (beyond 45 degrees)
		_hold_at_link(battle, link, DATALINK_STANDOFF, PI)
		await get_tree().physics_frame
	_expect(_texts(log).back() == ES1WinRules.DATALINK_ABORT_TEXT, "turning away shows the abort message")
	_expect(_texts(log).count(ES1WinRules.DATALINK_ABORT_TEXT) == 1 and rt.win_rules._datalink_stage == 0, "the link is reset, once")
	var again := Engine.get_physics_frames()
	var frames := 0
	while not rt.win_rules.datalink_flag and frames < int(DATALINK_WAIT * ticks):
		frames += 1
		_hold_at_link(battle, link, DATALINK_STANDOFF)
		await get_tree().physics_frame
	_expect(rt.win_rules.datalink_flag and float(frames) / ticks > 9.5, "it restarts from zero: %.1f s again" % (float(frames) / ticks))
	_expect(_texts(log).count(ES1WinRules.DATALINK_TEXTS[0]) == 2, "stage 0 speaks again")
	await _end(battle)


# ------------------------------------------------------------------ nav and destroy types

func _first_mission_of_types(types: Array) -> String:
	var idx = JSON.parse_string(FileAccess.get_file_as_string("res://../gamedata/es1/missions/index.json"))
	for n in idx.missions:
		var m: Dictionary = MissionCompiler.load_mission(n)
		if int(m.get("header", {}).get("mission_type", -1)) in types:
			return n
	return ""


## Nav types: the player visits every nav point; destroy types: the order target is destroyed. Either way the mission
## is won only once the players are safe, so the waves are cleared too.
func _check_type_won(mission_name: String, types: Array) -> void:
	print("%s (types %s) objective met, players safe:" % [mission_name, types])
	var battle := await _start(mission_name)
	var rt: MissionRuntime = battle.mission
	_expect(not rt.win_rules.objective_met(), "not met at the start")
	_expect(battle.get_meta("result").is_empty(), "the mission does not end by itself")
	if types == ES1WinRules.NAV_TYPES:
		for i in rt.nav_points.size() + 1:
			if rt.nav_index < rt.nav_points.size():
				_protect_player(battle)
				battle.player.global_position = rt.nav_points[rt.nav_index] + Vector3.UP * 2.0
			for f in COOP_ROUND_FRAMES:
				await get_tree().physics_frame
		_expect(rt.nav_index >= rt.nav_points.size(), "every nav point was reached")
	else:
		for n in rt.target_nodes(rt.win_rules.squad_target()):
			if n is Structure:
				n.destroy(battle.player)
			else:
				await _destroy(n)
		for f in COOP_ROUND_FRAMES:
			await get_tree().physics_frame
		_expect(rt.win_rules.target_status(rt.win_rules.squad_target()) == ES1WinRules.STATUS_DESTROYED, "the order target is destroyed")
	_expect(rt.win_rules.objective_met(), "the objective is met")
	if not rt.win_rules.players_safe():
		_expect(battle.get_meta("result").is_empty(), "an enemy is close: the mission goes on")
		await _clear_waves(battle)
	var result := await _wait_end(battle)
	_expect(bool(result.get("success", false)) or Campaign.is_failure(int(result.get("code", 0)), rt.win_rules.mission_type()) == false,
		"the mission ends in success (%s)" % str(result.get("code", "-")))
	await _end(battle)


func _check_player_lost(mission_name: String) -> void:
	print("%s the player is destroyed:" % mission_name)
	var battle := await _start(mission_name)
	var p: Herc = battle.player
	for i in 100:
		if not p.alive:
			break
		p.apply_hit(1e6, 1e6, null, p.global_position)
	_expect(not p.alive, "the player's Herc is destroyed")
	battle.mission._check_end()   # the rules tick, before anything else can revive the Herc
	var result: Dictionary = battle.get_meta("result")
	for i in END_WAIT_FRAMES * 4:
		if not result.is_empty():
			break
		await get_tree().physics_frame
	_expect(not result.is_empty() and not bool(result.get("success", true)), "losing the player fails the mission")
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

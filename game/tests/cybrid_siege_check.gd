extends Node
## The Cybrid siege, Varuna's Fall easter egg (engine/extraction/siege; docs/design/cybrid_siege.md):
##   1 data and pure blocks: rules, the hidden chain in order / wrong order / timeout, the closing order of the exfils, the
##     waves that escalate, the shrinking circle, the truce stances, the FailRule of the safe area
##   2 a raid on Varuna's Fall: relays buried at their sites (bands: hum, in reach), radio fragments as loot and echoes, the
##     chain woken in order -> broadcast, countdown and truce; waves attack everyone; the bot cap and the garrisons; the
##     Cybrid look; exfils close one by one; the safe area kills outside it; a siege extraction pays the bonus
##   3 the final stand: nothing but the Cybrids survives
##   4 every extraction counts in BattleStats
##   godot --headless --audio-driver Dummy --path game res://tests/cybrid_siege_check.tscn

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const SEED := 4242
const SETTLE_FRAMES := 20
const LAND_FRAMES := 3600
const FAR_CORNER := Vector3(2900.0, 0.0, 2900.0)

var _pilot := "QA Siege %d" % OS.get_process_id()
var _failures := 0
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	ExtractionRules.data()["bot_sleep"]["enabled"] = false   # the LOD director is switched on by hand where it is under test
	get_tree().create_timer(900.0, true, true).timeout.connect(func() -> void:
		print("TEST WATCHDOG: cybrid_siege_check timed out")
		get_tree().quit(2))
	_guard.back_up()
	Net.player_name = _pilot
	await get_tree().process_frame
	_run.call_deferred()


func _run() -> void:
	_check_rules()
	_check_chain()
	_check_timeline()
	_check_waves_and_zone()
	_check_truce_and_rule()
	if VarunaMap.is_available() and ExtractionRules.is_available():
		await _check_siege_raid()
		await _check_final_stand()
		await _check_plain_extraction()
	else:
		print("cybrid_siege_check: the Tribes 2 pack is not installed; the raid checks are skipped")
	_guard.restore()
	print("cybrid_siege_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


# ------------------------------------------------------------------ 1 data and pure blocks

func _check_rules() -> void:
	print("1a rules:")
	for key in ["trigger", "warning", "waves", "safe_area", "exfil", "final", "fragments"]:
		_expect(not CybridRules.section(key).is_empty(), "rules section '%s' exists" % key)
	var faction_ids: Array = ExtractionRules.factions().map(func(f: Dictionary) -> String: return str(f.id))
	_expect(CybridRules.make_cybrid_team() == ExtractionFactions.make_team(faction_ids.find("cybrid")), "the Cybrid team follows the rules' faction list (%d)" % CybridRules.make_cybrid_team())
	var json: Dictionary = VarunaMap.load_definition()
	_expect((json.get("cybrid_siege", {}).get("relays", []) as Array).size() == 3, "Varuna's Fall carries three relays in its data")
	var hints: Array = SiegeFragments.make_hints(["docks", "prow", "chapel"], json.cybrid_siege.fragments.lines)
	_expect(hints.size() == 3 and hints.all(func(h: String) -> bool: return h != "") and hints[0] != hints[1], "every rank of an order has its own fragment line")
	_expect(SiegeFragments.make_rank_of_item(SiegeFragments.make_item_id(2)) == 2 and SiegeFragments.make_rank_of_item("weapon/x") == -1, "fragment items map to their rank")


func _check_chain() -> void:
	print("1b hidden chain:")
	var ids := ["prow", "chapel", "docks"]
	var c := SiegeChain.make(ids, 600.0)
	_expect(c.apply_activate("prow") == SiegeChain.Result.STEP and c.apply_activate("chapel") == SiegeChain.Result.STEP, "relays in order step the chain")
	_expect(c.apply_activate("chapel") == SiegeChain.Result.IGNORED, "a lit relay does nothing twice")
	_expect(c.apply_activate("docks") == SiegeChain.Result.DONE, "the third in order completes it")
	var w := SiegeChain.make(ids, 600.0)
	w.apply_activate("prow")
	_expect(w.apply_activate("docks") == SiegeChain.Result.RESET and w.progress == 0 and not w.is_running(), "a wrong relay resets it quietly")
	var t := SiegeChain.make(ids, 600.0)
	var timed_out := [false]
	t.timed_out.connect(func() -> void: timed_out[0] = true)
	t.apply_activate("prow")
	t.apply_tick(599.0)
	_expect(t.progress == 1 and not timed_out[0], "inside the window it waits (%.0f s left)" % t.make_time_left())
	t.apply_tick(2.0)
	_expect(t.progress == 0 and timed_out[0], "past the window it resets")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var seen := {}
	for i in 40:
		seen[SiegeChain.make_shuffled(ids, rng)] = true
	_expect(seen.size() >= 4, "the per-raid order varies (%d of 6 seen)" % seen.size())


func _check_timeline() -> void:
	print("1c timeline:")
	var zones: Array = [Vector3(-1816, 0, -1624), Vector3(-500, 0, 650), Vector3(904, 0, 2504), Vector3(-1796, 0, -300), Vector3(2304, 0, -1464)]
	var closings := SiegeTimeline.make_closings(zones, 1)
	var rules := CybridRules.section("exfil")
	_expect(closings.size() == 5 and bool(closings[-1].last) and int(closings[-1].zone) == 1 and is_equal_approx(float(closings[-1].at_s), float(rules.last_close_s)),
		"five closings, the last zone last (at %.0f s)" % float(closings[-1].at_s))
	var dist_ok := true
	for i in range(1, 4):
		dist_ok = dist_ok and (zones[closings[i - 1].zone] as Vector3).distance_to(zones[1]) >= (zones[closings[i].zone] as Vector3).distance_to(zones[1])
	_expect(dist_ok and float(closings[1].at_s) - float(closings[0].at_s) == float(rules.interval_s), "the farthest close first, interval_s apart")
	var tl := SiegeTimeline.new()
	var log := []
	tl.announced.connect(func(s: int) -> void: log.append("say%d" % s))
	tl.arrived.connect(func() -> void: log.append("arrive"))
	tl.exfil_closing.connect(func(z: int, last: bool) -> void: log.append("close%d%s" % [z, "L" if last else ""]))
	tl.last_exfil_open.connect(func(z: int, left: float) -> void: log.append("open%d_%d" % [z, int(left)]))
	tl.final_stand.connect(func() -> void: log.append("final"))
	var warning := CybridRules.section("warning")
	tl.apply_warning(float(warning.countdown_s))
	for i in int(warning.countdown_s):
		tl.apply_tick(1.0)
	_expect(log == ["say60", "say30", "say10", "arrive"], "the countdown announces 60 / 30 / 10 and then arrives: %s" % [log])
	tl.apply_siege_start(zones, 1)
	tl.apply_tick(float(CybridRules.section("final").after_s) + 1.0)
	_expect(log.has("final") and log.count("close1L") == 1 and log.filter(func(e: String) -> bool: return e.begins_with("close")).size() == 5, "all five exfils close and the final stand follows")


func _check_waves_and_zone() -> void:
	print("1d waves and the circle:")
	var w1 := SiegeWaves.make_composition(1)
	var w10 := SiegeWaves.make_composition(10)
	_expect(int(w1.infantry) > 0 and int(w1.hercs) == 0 and int(w1.flyers) == 0, "wave 1: infantry only (%s)" % [w1])
	_expect(int(w10.infantry) > int(w1.infantry) and int(w10.hercs) > 0 and int(w10.flyers) > 0, "wave 10 is bigger and brings Hercs and flyers (%s)" % [w10])
	_expect(SiegeWaves.make_composition(80).infantry == int(CybridRules.section("waves").infantry.cap), "the counts are capped by the rules")
	var gaps := []
	for n in range(2, 40):
		gaps.append(SiegeWaves.make_arrival(n) - SiegeWaves.make_arrival(n - 1))
	_expect(is_equal_approx(SiegeWaves.make_arrival(1), float(CybridRules.section("waves").first_s)) and gaps[0] > gaps[-1] and is_equal_approx(gaps[-1], float(CybridRules.section("waves").interval_s[1])),
		"the waves come faster and faster down to %.0f s apart (%.1f -> %.1f)" % [gaps[-1], gaps[0], gaps[-1]])
	_expect(SiegeWaves.make_size(3, {"heavy_every": 4, "medium_every": 2}) == "HEAVY" and SiegeWaves.make_size(1, {"heavy_every": 4, "medium_every": 2}) == "MEDIUM", "armour sizes escalate by position")
	var z := SiegeZone.make(Vector2.ZERO, Vector2(-500, 650))
	var stages: Array = z.stages
	_expect(is_equal_approx(z.make_radius(0.0), float(stages[0][1])) and is_equal_approx(z.make_radius(99999.0), float(stages[-1][1])), "the circle runs from %d m to %d m" % [stages[0][1], stages[-1][1]])
	var nested := true
	var last_edge := INF
	for t in range(0, 1300, 20):
		var edge := z.make_centre(float(t)).distance_to(Vector2.ZERO) + z.make_radius(float(t))
		nested = nested and edge <= float(stages[0][1]) + 0.01 and z.make_radius(float(t)) <= z.make_radius(float(maxi(t - 20, 0))) + 0.01
		last_edge = edge
	_expect(nested and z.is_inside(Vector3(-500, 0, 650), 99999.0) and not z.is_inside(Vector3(2000, 0, 2000), 99999.0), "every circle lies in the one before and ends on the last exfil")


func _check_truce_and_rule() -> void:
	print("1e truce and the safe-area rule:")
	var rules := CybridRules.section("relations")
	_expect(SiegeRelations.make_stance("blood_eagle", "diamond_sword", rules) == TeamRelations.ALLIED, "feuding tribes become allies")
	_expect(SiegeRelations.make_stance("", "starwolf", rules) == TeamRelations.NEUTRAL, "a player is neutral to the tribes")
	_expect(SiegeRelations.make_stance("cybrid", "starwolf", rules) == TeamRelations.HOSTILE and SiegeRelations.make_stance("bioderm", "phoenix", rules) == TeamRelations.HOSTILE,
		"the Cybrids and the horde stay hostile to everyone")
	_expect(SiegeRelations.make_stance("", "", rules) == "", "two players are left as they were")
	var rule := LeftAreaRule.new(SiegeEnforcer.FAIL_CODE, "out", float(CybridRules.section("safe_area").lethal_grace_s))
	var world := SiegeUnitWorld.new()
	world.out_seconds = 39.0
	_expect(rule.make_verdict(world, 1.0) == null, "the FailRule waits out the grace")
	world.out_seconds = 41.0
	var verdict := rule.make_verdict(world, 1.0)
	_expect(verdict != null and not verdict.success, "and then rules the unit lost")


# ------------------------------------------------------------------ the raid

func _start_raid() -> Battle:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": VarunaMap.MAP_ID, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = SEED
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _land(battle: Battle) -> Infantry:
	var player := battle.player as Infantry
	for i in LAND_FRAMES:
		if not player.stowed:
			break
		await get_tree().physics_frame
	player.spawn_protection = 100000.0
	player.apply_spawn_protection()
	return player


func _end_raid(battle: Battle) -> void:
	battle.queue_free()
	await _frames(3)


## The player stands at `p` (on the ground there) and the host has scanned once.
func _stand_at(battle: Battle, player: Infantry, p: Vector3) -> void:
	player.global_position = battle.extraction.make_ground_point(p) + Vector3.UP * 0.5
	player.velocity = Vector3.ZERO
	battle.extraction.siege.host.apply_tick(1.0)


func _check_siege_raid() -> void:
	print("2 the siege on Varuna's Fall:")
	var battle := await _start_raid()
	var x := battle.extraction
	var siege := x.siege
	var host := siege.host
	_expect(siege.is_present() and host != null, "the siege is armed on Varuna's Fall")
	if host == null:
		await _end_raid(battle)
		return
	var player := await _land(battle)
	await _check_relays(battle, x, player)
	await _check_fragments(battle, x, player)
	await _check_chain_in_raid(battle, x, player)
	await _check_siege_waves(battle, x)
	_check_look_and_cap(battle, x)
	_check_exfil_closing(battle, x, player)
	_check_safe_area(battle, x, player)
	await _check_siege_extraction(battle, x, player)
	await _end_raid(battle)


func _relay_point(x: ExtractionDirector, index: int) -> Vector3:
	return x.siege.host.relays.points[x.siege.host.chain.order[index]]


func _check_relays(battle: Battle, x: ExtractionDirector, player: Infantry) -> void:
	print("2a relays:")
	var host := x.siege.host
	var near_sites := 0
	for relay_id in host.relays.points:
		var site := x.site_spawner.find_site({"prow": "prow_fortress", "chapel": "chapel_fortress", "docks": "crater_docks"}[relay_id])
		var d := Vector2(host.relays.points[relay_id].x - site.pos.x, host.relays.points[relay_id].z - site.pos.z).length()
		near_sites += 1 if d < float(site.pad_radius) * 3.0 + 200.0 else 0
	_expect(near_sites == 3, "the three relays are buried at their sites")
	_expect(host.chain.order.size() == 3 and host.chain.order.duplicate().size() == 3 and host.phase == SiegePhase.ARMED, "an order is rolled for this raid: %s" % [host.chain.order])
	var first := _relay_point(x, 0)
	_stand_at(battle, player, first + Vector3(60, 0, 0))
	_expect(host.relays.make_band(1) == SiegeRelays.Band.NONE and x.siege.make_relay_offer(player).is_empty(), "far away nothing is offered")
	_stand_at(battle, player, first + Vector3(9, 0, 0))
	_expect(host.relays.make_band(1) == SiegeRelays.Band.SENSE and x.siege.my_band == SiegeRelays.Band.SENSE, "close by the hum is heard (the host told this player)")
	var offer := x.siege.make_relay_offer(player)
	_expect(not offer.is_empty() and str(offer.text) == CybridRules.text("trigger", "sense"), "the interact key offers to listen: '%s'" % offer.get("text", ""))
	_stand_at(battle, player, first + Vector3(1, 0, 0))
	_expect(host.relays.make_band(1) == SiegeRelays.Band.REACH and x.siege.make_relay_offer(player).text == CybridRules.text("trigger", "reach"), "within reach the plate can be dug out")


func _check_fragments(battle: Battle, x: ExtractionDirector, player: Infantry) -> void:
	print("2b radio fragments:")
	var host := x.siege.host
	var recorders := x.containers.values().filter(func(c: LootContainer) -> bool: return c.kind == SiegeFragments.RECORDER_KIND)
	_expect(recorders.size() >= 3, "recorders lie at wreck sites (%d)" % recorders.size())
	var ranks := {}
	for r in recorders:
		ranks[SiegeFragments.make_rank_of_item(str(r.stacks[0][0]))] = true
	_expect(ranks.size() == 3, "every rank has a copy to find")
	var recorder: LootContainer = recorders[0]
	var before_hints := x.siege.my_hints.size()
	var echoes: Array = []
	host.fragments.echoed.connect(func(peer: int, rank: int) -> void: echoes.append([peer, rank]))
	_stand_at(battle, player, recorder.position)
	player.global_position = recorder.position + Vector3.UP * 0.3
	x._apply_pickup(1)
	_expect(x.siege.my_hints.size() == before_hints + 1, "looting a recorder tells its line to the looter: %s" % [x.siege.my_hints.values()])
	var lines := x.make_objective_lines().filter(func(l: Dictionary) -> bool: return str(l.text).begins_with("Static:"))
	_expect(lines.size() == 1, "and keeps it in the objective list")
	var echo_at: Array = VarunaMap.load_definition().cybrid_siege.fragments.echoes[0].pos
	_stand_at(battle, player, Vector3(float(echo_at[0]), 0.0, float(echo_at[1])))
	host.apply_tick(1.0)
	_expect(echoes.size() == 1, "static speaks a line to whoever walks into an echo place (%s)" % [echoes])
	_stand_at(battle, player, Vector3(float(echo_at[0]) + 200.0, 0.0, float(echo_at[1])))
	_stand_at(battle, player, Vector3(float(echo_at[0]), 0.0, float(echo_at[1])))
	_expect(echoes.size() == 1, "but only once to the same player")


func _check_chain_in_raid(battle: Battle, x: ExtractionDirector, player: Infantry) -> void:
	print("2c waking the chain:")
	var host := x.siege.host
	var order: Array = host.chain.order
	_stand_at(battle, player, _relay_point(x, 2))
	host.apply_dig(1)
	_expect(host.chain.progress == 0 and host.sink.lines_said == 0 and host.phase == SiegePhase.ARMED, "a relay out of order resets quietly (nothing broadcast)")
	_stand_at(battle, player, _relay_point(x, 0))
	host.apply_dig(1)
	_expect(host.chain.progress == 1, "the right first relay warms")
	host.chain.apply_tick(float(CybridRules.section("trigger").chain_window_s) + 1.0)
	_expect(host.chain.progress == 0 and host.sink.lines_said == 0, "after the window it is quiet again")
	for i in 3:
		_stand_at(battle, player, _relay_point(x, i))
		host.apply_dig(1)
	_expect(host.phase == SiegePhase.WARNING, "three relays in order start the warning (order %s)" % [order])
	host.apply_tick(0.1)
	await _frames(2)
	var warning := CybridRules.section("warning")
	_expect(host.sink.lines_said >= 1, "the broadcast goes to everyone (%d lines said)" % host.sink.lines_said)
	for i in 4:
		host.apply_tick(5.0)
	_expect(host.sink.lines_said >= (warning.lines as Array).size(), "all %d broadcast lines were said" % (warning.lines as Array).size())
	_expect(absf(host.timeline.make_warning_left() - (float(warning.countdown_s) - 20.0)) < 1.0, "the countdown runs (%.0f s left)" % host.timeline.make_warning_left())
	var team := host.cybrid_team
	var tribe_teams := x.faction_teams.keys().filter(func(t: int) -> bool: return ExtractionFactions.kind_of(str(x.faction_teams[t])) == ExtractionFactions.KIND_HUMAN)
	_expect(tribe_teams.size() >= 2 and TeamRelations.is_allied(tribe_teams[0], tribe_teams[1]), "the human factions are allied now")
	_expect(TeamRelations.is_hostile(team, tribe_teams[0]) and TeamRelations.is_hostile(team, x.make_player_team(1)) and TeamRelations.is_hostile(x.make_player_team(1), team),
		"the Cybrids are hostile to a faction and to the player")
	_expect(not TeamRelations.is_hostile(x.make_player_team(1), tribe_teams[0]), "the player and the tribes leave each other alone")
	var bioderm_teams := x.faction_teams.keys().filter(func(t: int) -> bool: return str(x.faction_teams[t]) == "bioderm")
	_expect(bioderm_teams.is_empty() or TeamRelations.is_hostile(bioderm_teams[0], tribe_teams[0]), "the horde still fights everyone")
	await _frames(30)
	_expect(x.siege.get_phase() == SiegePhase.WARNING and float(x.siege.state.t) > 0.0, "every peer's state shows the countdown (%.0f s)" % float(x.siege.state.t))


func _check_siege_waves(battle: Battle, x: ExtractionDirector) -> void:
	print("2d the waves:")
	var host := x.siege.host
	for i in 80:
		host.apply_tick(1.0)
		if host.phase == SiegePhase.SIEGE:
			break
	_expect(host.phase == SiegePhase.SIEGE and absf(x.transports.delay_factor - 0.5) < 0.001, "the Cybrids arrive after the countdown; exfil calls get faster")
	await _frames(30)
	_expect(x.siege.get_phase() == SiegePhase.SIEGE and float(x.siege.state.r) > 0.0, "every peer's state shows the siege and its circle (%d m)" % int(x.siege.state.r))
	for i in 14:
		host.apply_tick(1.0)
	var units := host.spawner.units
	_expect(host.wave_number >= 1 and not units.is_empty(), "wave 1 came (%d units) from a gate at %s" % [units.size(), host.spawner.last_gate])
	var edge := host.spawner.last_gate
	var m := x.map
	var to_edge := minf(absf(edge.x - m.bounds_min.x), minf(absf(edge.x - m.bounds_max.x), minf(absf(edge.z - m.bounds_min.y), absf(edge.z - m.bounds_max.y))))
	_expect(to_edge < 200.0, "it came in from the map's edge (%.0f m from it)" % to_edge)
	var u: Herc = units[0].unit
	_expect(u.team == host.cybrid_team and u is Infantry and u.has_meta("keep_awake"), "Cybrid-team infantry bots, pinned awake")
	_expect(units.all(func(r: Dictionary) -> bool: return TeamRelations.is_hostile((r.unit as Herc).team, x.make_player_team(1))), "all of it is hostile to the player")
	var faction_soldier: Infantry = null
	for h in battle.vehicles.values():
		if h is Infantry and h.alive and not h.stowed and x.faction_teams.has(h.team):
			faction_soldier = h
			break
	_expect(faction_soldier != null and units.all(func(r: Dictionary) -> bool: return TeamRelations.is_hostile((r.unit as Herc).team, faction_soldier.team)), "and to the factions' soldiers")
	var trooper: InfantryBot = units[0].brain
	faction_soldier.global_position = battle.infantry.make_on_ground((u as Infantry).global_position + Vector3(30, 0, 0)) + Vector3.UP * 0.2
	faction_soldier.velocity = Vector3.ZERO
	await _frames(10)
	trooper._reconsider()
	print("    trooper alive %s lod %d at %s; foe alive %s at %s team %d vs %d hostile %s" % [u.alive, trooper.ai_lod, u.global_position, faction_soldier.alive, faction_soldier.global_position, u.team, faction_soldier.team, TeamRelations.is_hostile(u.team, faction_soldier.team)])
	_expect(trooper.target != null and TeamRelations.is_hostile(u.team, trooper.target.team), "a Cybrid trooper picks a hostile target at once (%s)" % (trooper.target.display_name if trooper.target else "none"))
	for i in 70:
		host.apply_tick(5.0)
	var comp := SiegeWaves.make_composition(host.wave_number)
	_expect(host.wave_number > 3 and host.spawner.count_alive() > comp.infantry and host.spawner.count_alive("hercs") + host.spawner.count_alive("flyers") >= 1,
		"the waves escalate (wave %d, %d Cybrids, %d Hercs)" % [host.wave_number, host.spawner.count_alive(), host.spawner.count_alive("hercs")])
	var kinds := {}
	for r in host.spawner.units:
		kinds[str((r.unit as Herc).def.get("side", "infantry")) if r.kind != "infantry" else "infantry"] = true
	print("    kinds: %s, gates used %d" % [kinds.keys(), host.spawner.gates_used])
	_expect(host.spawner.gates_used > 1, "each wave uses a new gate")
	_expect(host.spawner.count_alive() <= int(CybridRules.section("waves").max_units), "the siege stays inside its unit cap (%d)" % host.spawner.count_alive())
	var cybrid_pool := SiegeSpawner.make_herc_pool(10)
	var sides: Array = cybrid_pool.map(func(id: String) -> String: return str(Packs.vehicle(id).get("side", "")))
	_expect(cybrid_pool.is_empty() or sides.all(func(s: String) -> bool: return s == "cybrid"), "the Hercs are Cybrid Hercs of ES1, ES2 and Starsiege (%d kinds)" % cybrid_pool.size())
	var saved: Array = CybridRules.data().herc_packs
	CybridRules.data()["herc_packs"] = ["no_such_pack"]
	var fallback := SiegeSpawner.make_herc_pool(10)
	CybridRules.data()["herc_packs"] = saved
	_expect(fallback.is_empty() == Packs.pilotable([], "herc").is_empty() and fallback.all(func(id: String) -> bool: return str(Packs.vehicle(id).get("side", "")) == "herc"),
		"with no Cybrid pack, Hercs of any game stand in (%d)" % fallback.size())


func _check_look_and_cap(battle: Battle, x: ExtractionDirector) -> void:
	print("2e the look, the cap and the LOD:")
	var host := x.siege.host
	var made := x.siege.apply_looks()
	var soldier: Infantry = null
	for r in host.spawner.units:
		if r.unit is Infantry:
			soldier = r.unit
			break
	var meshes := CloakVisual.make_meshes(soldier) if soldier != null else []
	_expect(made > 0 and not meshes.is_empty() and meshes.all(func(m: MeshInstance3D) -> bool: return m.material_override == CybridLook.get_material()),
		"Cybrid soldiers wear the made-up metal look (%d done, %d meshes)" % [made, meshes.size()])
	_expect(soldier != null and soldier.eye.get_node_or_null(CybridLook.VISOR_NAME) != null, "with a red visor")
	var live := BotBudget.count_live(battle)
	var garrison_before := x.site_spawner.count_total_alive()
	battle.config[BotBudget.CONFIG_KEY] = live + 3
	var unit_cap: Dictionary = CybridRules.section("waves")
	var saved_cap: Variant = unit_cap.max_units
	unit_cap["max_units"] = 500   # the bot cap, not the siege's own, is under test here
	host.spawner.spawn_wave(12)
	unit_cap["max_units"] = saved_cap
	_expect(BotBudget.count_live(battle) <= live + 3 + 1, "the bot cap holds (%d of %d live)" % [BotBudget.count_live(battle), live + 3])
	_expect(x.site_spawner.count_total_alive() < garrison_before, "and the garrisons gave way for the siege (%d -> %d)" % [garrison_before, x.site_spawner.count_total_alive()])
	battle.config.erase(BotBudget.CONFIG_KEY)
	ExtractionRules.data()["bot_sleep"]["enabled"] = true
	battle.bot_sleep.apply_tick()
	var asleep := host.spawner.units.filter(func(r: Dictionary) -> bool: return is_instance_valid(r.unit) and BotSleep.is_asleep(r.unit))
	_expect(asleep.is_empty(), "the LOD director never puts a siege unit to sleep (%d asleep)" % asleep.size())
	ExtractionRules.data()["bot_sleep"]["enabled"] = false


func _check_exfil_closing(battle: Battle, x: ExtractionDirector, player: Infantry) -> void:
	print("2f exfils close:")
	var host := x.siege.host
	var closings := host.timeline.closings
	var done := closings.filter(func(c: Dictionary) -> bool: return float(c.at_s) <= host.timeline.siege_s and not bool(c.last))
	_expect(x.transports.closed.size() == done.size() and done.size() >= 1 and x.transports.closed[0] == int(closings[0].zone),
		"the exfils close in order as the siege goes on (%d closed after %d s, the farthest first)" % [done.size(), int(host.timeline.siege_s)])
	_stand_at(battle, player, x.zones[int(closings[0].zone)])
	var msg := x.transports.request_exfil(1)
	var called := x.transports.exfils.keys()
	_expect(called.size() == 1 and not x.transports.closed.has(int(called[0])), "an exfil call goes to an open zone instead (%s)" % msg)
	var flushed := host.sink.lines_said
	host.timeline.apply_tick(float(closings[3].at_s) - host.timeline.siege_s + 1.0)
	for i in 12:
		host.announcer.apply_tick(10.0)
	_expect(x.transports.closed.size() == 4 and not x.transports.closed.has(host.last_zone), "one by one: four are closed, the last stays open (zone %s)" % ExtractionTransports.make_zone_name(host.last_zone))
	_expect(host.sink.lines_said - flushed >= 2, "each closing is announced to everyone (%d lines since)" % (host.sink.lines_said - flushed))
	var state := host.make_state()
	_expect(int(state.last_zone) == host.last_zone and float(state.last_left) > 0.0, "the state carries how long the last exfil stays open (%.0f s)" % float(state.last_left))
	x.transports.exfils.clear()
	x._exfil_update(x.transports.make_states())
	_expect(x.is_zone_closed(int(closings[0].zone)) and not x.is_zone_closed(host.last_zone), "every peer reads the closed zones from the synced states")


func _check_safe_area(battle: Battle, x: ExtractionDirector, player: Infantry) -> void:
	print("2g safe area:")
	var host := x.siege.host
	host.timeline.siege_s = 900.0
	var victim: Infantry = null
	for h in battle.vehicles.values():
		if h is Infantry and h.alive and not h.stowed and x.faction_teams.has(h.team):
			victim = h
	var inside_pos: Vector3 = x.zones[host.last_zone]
	_stand_at(battle, player, inside_pos)
	var hp_before := _hp(player)
	victim.global_position = battle.infantry.make_on_ground(FAR_CORNER)
	_expect(host.zone.make_overshoot(victim.global_position, 900.0) > 100.0 and host.zone.is_inside(player.global_position, 900.0), "the victim stands outside the circle, the player inside")
	var cybrid: Herc = host.spawner.units[0].unit
	var cybrid_hp := _hp(cybrid)
	cybrid.global_position = battle.infantry.make_on_ground(FAR_CORNER)
	var ticks := 0
	while victim.alive and ticks < 200:
		host.enforcer.apply_tick(0.5, 900.0)
		ticks += 1
	_expect(not victim.alive, "outside the safe area a soldier dies (%d s)" % int(ticks * 0.5))
	_expect(_hp(player) >= hp_before - 0.01, "inside it nothing is hurt")
	_expect(cybrid.alive and _hp(cybrid) >= cybrid_hp - 0.01, "the Cybrids ignore the border")
	host.timeline.siege_s = 0.0


static func _hp(h: Herc) -> float:
	var total := 0.0
	for c in h.components:
		total += float(c.hp)
	return total


func _check_siege_extraction(battle: Battle, x: ExtractionDirector, player: Infantry) -> void:
	print("2h extracting during the siege:")
	var host := x.siege.host
	var bonus: Dictionary = CybridRules.section("exfil").bonus
	_expect(host.make_extraction_bonus(1000) == int(bonus.flat) + int(round(1000.0 * float(bonus.fraction))), "a siege haul of 1000 cr gets %d cr on top" % host.make_extraction_bonus(1000))
	_stand_at(battle, player, x.zones[host.last_zone])
	var before := ExtractionProfile.load_for(_pilot).money
	var carried: int = x.inventories[1].money
	var key := battle.stats.make_pilot_key(player)
	x.apply_extract(1)
	await _frames(3)
	var after := ExtractionProfile.load_for(_pilot).money
	_expect(x.status[1] == ExtractionDirector.STATUS_EXTRACTED, "the player extracted")
	_expect(after - before >= carried + int(bonus.flat), "and was paid the siege bonus (%d cr, the bonus alone >= %d)" % [after - before, int(bonus.flat)])
	_expect(int(battle.stats.make_stats(key).extractions) == 1, "BattleStats counted the extraction")


# ------------------------------------------------------------------ 3 the final stand

func _check_final_stand() -> void:
	print("3 the final stand:")
	var battle := await _start_raid()
	var x := battle.extraction
	var host := x.siege.host
	var player := await _land(battle)
	player.spawn_protection = 0.0
	host.apply_warning()
	host.apply_siege_start()
	host.apply_tick(0.5)
	host.timeline.apply_tick(float(CybridRules.section("final").after_s) + 1.0)
	_expect(host.phase == SiegePhase.SIEGE and host.ender.has_verdict(), "at the final time the verdict is in, the end waits its grace")
	host.spawner.spawn_wave(1)
	var cybrids := host.spawner.count_alive()
	host.apply_tick(float(CybridRules.section("final").delay_s) + 1.0)
	await _frames(5)
	_expect(host.phase == SiegePhase.ENDED, "then the siege is over")
	var living := battle.vehicles.values().filter(func(h: Herc) -> bool: return is_instance_valid(h) and h.alive and not h.has_meta("transport") and h.team != host.cybrid_team)
	_expect(living.is_empty(), "nothing but the Cybrids survives (%d others alive)" % living.size())
	_expect(not player.alive and x.status[1] == ExtractionDirector.STATUS_DEAD, "the player is dead")
	_expect(host.spawner.count_alive() >= cybrids and cybrids > 0, "the Cybrids are still there (%d)" % host.spawner.count_alive())
	await _end_raid(battle)


# ------------------------------------------------------------------ 4 every extraction counts

func _check_plain_extraction() -> void:
	print("4 an extraction outside the siege:")
	var battle := await _start_raid()
	var x := battle.extraction
	var player := await _land(battle)
	var key := battle.stats.make_pilot_key(player)
	var before := ExtractionProfile.load_for(_pilot).money
	var carried: int = x.inventories[1].money
	x.apply_extract(1)
	await _frames(3)
	_expect(int(battle.stats.make_stats(key).extractions) == 1, "BattleStats counted it")
	_expect(ExtractionProfile.load_for(_pilot).money - before == carried, "and no siege bonus was paid (%d cr)" % (ExtractionProfile.load_for(_pilot).money - before))
	await _end_raid(battle)

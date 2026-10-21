extends Node
## The extraction map Varuna's Fall (docs/design/extraction_map_varuna.md):
##   1 availability: offered by MapBuilder, GameModes (extraction) and the map picker only with the Tribes 2 pack installed
##   2 terrain: about 6 x 6 km; mountains in the north and west, plains in the middle, lakes below the water level in the
##     south, uplands in the east, a mountain tarn; the water boxes exist
##   3 sites: at least 4 factions with 1-4 sites each, flags only in large bases, exfil zones >= 600 m from any flag and
##     >= 300 m from any site, 2-4 walkable spawn areas per site out of the exfil zones' sight, level site pads
##   4 a raid: sites populated by the spawn director, a population refills on its timer after kills (faster under attack,
##     the horde faster at night), patrols join another site of their faction, the horde raids the weakest site
##   godot --headless --audio-driver Dummy --path game res://tests/varuna_check.tscn

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
var _pilot := "QA Varuna %d" % OS.get_process_id()
const SEED := 4242
const SETTLE_FRAMES := 20
const REGION_SAMPLES := 400
## Longest the refill check waits (ticks of 30 s). Measured with patrols and raids paused: 20 ticks for 16 soldiers.
const REFILL_MAX_TICKS := 60

var _failures := 0
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	ExtractionRules.data()["bot_sleep"]["enabled"] = false   # these checks put units to sleep by hand; the LOD director would wake them
	get_tree().create_timer(600.0, true, true).timeout.connect(func() -> void:
		print("TEST WATCHDOG: varuna_check timed out")
		get_tree().quit(2))
	_guard.back_up()
	Net.player_name = _pilot
	await get_tree().process_frame
	_run.call_deferred()


func _run() -> void:
	if not VarunaMap.is_available():
		print("varuna_check: the Tribes 2 pack is not installed; checking that the map is hidden")
		_check_hidden_without_pack()
	else:
		_check_offered()
		var m := VarunaMap.make_map()
		_check_terrain(m)
		_check_sites(m)
		_check_hidden_without_pack()
		await _check_raid()
	_guard.restore()
	print("varuna_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


# ------------------------------------------------------------------ 1 availability

func _check_offered() -> void:
	print("1 availability:")
	var rows := MapBuilder.list_maps().filter(func(r: Dictionary) -> bool: return str(r.id) == VarunaMap.MAP_ID)
	_expect(rows.size() == 1, "listed once with the Tribes 2 pack installed")
	var modes := GameModes.make_remake_ids(rows[0]) if not rows.is_empty() else []
	_expect(modes == ["extraction"], "its only game mode is extraction (%s)" % [modes])
	var entries := MapPicker.make_entries().filter(func(e: Dictionary) -> bool: return str((e.config as Dictionary).get("map", "")) == VarunaMap.MAP_ID)
	_expect(entries.size() == 1, "in the map picker (%d)" % entries.size())
	_expect(not MapBuilder.load_map(VarunaMap.MAP_ID).is_empty(), "MapBuilder.load_map builds it")


## No Tribes 2 data folder: not in the map list, no game modes, not loadable.
func _check_hidden_without_pack() -> void:
	print("1b hidden without the Tribes 2 pack:")
	var saved_root: String = Assets.data_root
	var empty := ProjectSettings.globalize_path("user://varuna_no_packs_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(empty)
	Assets.data_root = empty
	var listed := MapBuilder.list_maps().any(func(r: Dictionary) -> bool: return str(r.id) == VarunaMap.MAP_ID)
	_expect(not listed, "not listed")
	_expect(MapBuilder.load_map(VarunaMap.MAP_ID).is_empty(), "not loadable")
	var row := {"id": "varuna", "remake_modes": ["extraction"], "spawns": {}, "size_m": [6144, 6144]}
	var picker := MapPicker.make_entries().any(func(e: Dictionary) -> bool: return str((e.config as Dictionary).get("map", "")) == VarunaMap.MAP_ID)
	_expect(not picker, "not in the map picker")
	_expect(not ExtractionRules.is_available() or GameModes.make_remake_ids(row) == ["extraction"], "extraction mode follows the soldier packs")
	Assets.data_root = saved_root
	DirAccess.remove_absolute(empty)


# ------------------------------------------------------------------ 2 terrain

func _check_terrain(m: Dictionary) -> void:
	print("2 terrain:")
	var t: VarunaTerrain = m._terrain
	var b: Dictionary = m.bounds
	var w := float(b.max[0]) - float(b.min[0])
	var d := float(b.max[1]) - float(b.min[1])
	_expect(w >= 6000.0 and d >= 6000.0, "about 6 x 6 km (%d x %d m)" % [w, d])
	var hs := t.make_heights()
	_expect(hs.size() == t.samples * t.samples, "heightfield %d x %d samples at %.0f m" % [t.samples, t.samples, t.square])
	var stats := {}
	for r in t.regions:
		stats[str(r.id)] = _make_region_stats(t, r)
	print("    region mean height / slope: %s" % [stats])
	_expect(stats.north_mountains.mean > 220.0 and stats.north_mountains.slope > 0.25, "north: high and steep")
	_expect(stats.west_caves.mean > 180.0 and stats.west_caves.slope > 0.25, "west: high and steep cave mountains")
	_expect(stats.central_plains.mean < 70.0 and stats.central_plains.slope < 0.12, "centre: low and flat")
	_expect(stats.east_uplands.mean > 90.0 and stats.east_uplands.mean < 220.0, "east: broken uplands between the two")
	var wet := 0
	for h in hs:
		if h < t.water_level:
			wet += 1
	var wet_fraction := float(wet) / hs.size()
	_expect(wet_fraction > 0.03 and wet_fraction < 0.2, "lakes, river and coast: %.1f%% of the ground is under water" % (wet_fraction * 100.0))
	_expect(t.grid_height(-300.0, 2350.0) < t.water_level - 10.0, "the impact crater holds a lake (%.1f m)" % t.grid_height(-300.0, 2350.0))
	_expect(t.grid_height(-950.0, -1950.0) < 214.0 - 5.0, "the mountain tarn basin is below its water level")
	var water: Array = m.environment.water
	_expect(water.size() >= 2 and water.all(func(box: Dictionary) -> bool: return float(box.level) > float(box.bottom)), "water planes: %d" % water.size())
	_expect((m.terrain.albedo_data as Image).get_width() >= 512, "terrain colour map baked from the Tribes 2 textures")
	_expect(str(m.environment.skybox_faces.front) != "" and str(m._dir).contains("Alcatraz"), "Tribes 2 sky referenced from the pack")
	var world := Node3D.new()
	add_child(world)
	var built := MapBuilder.build(world, VarunaMap.MAP_ID)
	_expect(world.get_tree().get_nodes_in_group("map_water").size() == 1 and (world.get_node("MapWater") as MapWater).boxes.size() == 2, "MapWater built with both boxes")
	_expect(MapBuilder.ground_height(world, Vector3(0, 0, -250)) > 0.0 and built.palette != null, "MapBuilder places the terrain and interiors")
	var holes := 0
	for node in world.get_children():
		holes += 1 if node.is_in_group(MapBuilder.INTERIOR_GROUP) else 0
	_expect(holes >= 20, "Tribes 2 interiors placed (%d)" % holes)
	world.queue_free()


func _make_region_stats(t: VarunaTerrain, r: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var c := Vector2(float(r.center[0]), float(r.center[1]))
	var sum := 0.0
	var slope := 0.0
	for i in REGION_SAMPLES:
		var p := c + Vector2(rng.randf_range(-350, 350), rng.randf_range(-350, 350))
		sum += t.grid_height(p.x, p.y)
		slope += t.grid_slope(p.x, p.y)
	return {"mean": snappedf(sum / REGION_SAMPLES, 0.1), "slope": snappedf(slope / REGION_SAMPLES, 0.01)}


# ------------------------------------------------------------------ 3 sites

func _check_sites(m: Dictionary) -> void:
	print("3 sites and exfil:")
	var t: VarunaTerrain = m._terrain
	var by_faction := {}
	for s in m.sites:
		by_faction[str(s.faction)] = by_faction.get(str(s.faction), 0) + 1
	_expect(by_faction.size() >= 4, "%d factions: %s" % [by_faction.size(), by_faction])
	_expect(by_faction.values().all(func(n: int) -> bool: return n >= 1 and n <= 4), "1-4 sites per faction")
	for f in ["blood_eagle", "diamond_sword", "starwolf", "phoenix", "bioderm"]:
		_expect(by_faction.has(f) and ExtractionFactions.find(f).size() > 0, "%s holds sites and is an extraction faction" % f)
	var flags: Array = m.mode_objects.filter(func(o: Dictionary) -> bool: return str(o.kind) == "flag")
	var large_flag_sites: Array = m.sites.filter(func(s: Dictionary) -> bool: return bool(s.flag))
	_expect(flags.size() == large_flag_sites.size() and large_flag_sites.all(func(s: Dictionary) -> bool: return str(s.size) == "large"),
		"flags only in large bases (%d)" % flags.size())
	_expect(m.sites.any(func(s: Dictionary) -> bool: return str(s.size) == "small") and m.sites.any(func(s: Dictionary) -> bool: return str(s.size) == "medium"),
		"sites range from small watchtowers to large bases")
	var kinds := {}
	for st in m.stations:
		kinds[str(st.kind)] = int(kinds.get(str(st.kind), 0)) + 1
	_expect(kinds.get("generator", 0) >= 6 and kinds.get("inventory", 0) >= 4 and kinds.get("turret", 0) >= 12 and kinds.get("vehicle", 0) >= 4, "generators, inventory stations, turrets, vehicle pads: %s" % [kinds])
	_expect(m.exfil.size() >= 4 and m.exfil.all(func(e: Dictionary) -> bool: return str(e.label).begins_with("EXFIL ")), "%d exfil zones labelled EXFIL A-" % m.exfil.size())
	var min_flag := INF
	var min_site := INF
	var exfil_regions := {}
	for e in m.exfil:
		var p := Vector2(float(e.pos[0]), float(e.pos[1]))
		for f in flags:
			min_flag = minf(min_flag, p.distance_to(Vector2(float(f.pos[0]), float(f.pos[2]))))
		for s in m.sites:
			min_site = minf(min_site, p.distance_to(Vector2(float(s.pos[0]), float(s.pos[2]))))
		_expect(t.grid_height(p.x, p.y) > t.water_level + 1.0 and t.grid_slope(p.x, p.y) < 0.4, "%s on dry, walkable ground" % e.label)
		exfil_regions[t.regions[t.find_region(p.x, p.y)].id] = true
	_expect(min_flag >= float(m.rules.min_flag_exfil_m), "every exfil is >= %d m from any flag (nearest %.0f m)" % [m.rules.min_flag_exfil_m, min_flag])
	_expect(min_site >= float(m.rules.min_site_exfil_m), "every exfil is >= %d m from any site (nearest %.0f m)" % [m.rules.min_site_exfil_m, min_site])
	_expect(exfil_regions.size() >= 4, "exfils spread over %d regions" % exfil_regions.size())
	var bad_areas := 0
	var total_areas := 0
	var sighted := 0
	var flat_bad := 0
	for s in m.sites:
		var areas: Array = s.spawn_areas
		_expect(areas.size() >= 2 and areas.size() <= 4, "%s: %d spawn areas" % [s.id, areas.size()])
		var c := Vector2(float(s.pos[0]), float(s.pos[2]))
		for a in areas:
			total_areas += 1
			var p := Vector2(float(a[0]), float(a[1]))
			if t.grid_height(p.x, p.y) < t.water_level + 1.0 or t.grid_slope(p.x, p.y) > 0.5 or p.distance_to(c) < float(s.pad_radius):
				bad_areas += 1
			for e in m.exfil:
				var ep := Vector2(float(e.pos[0]), float(e.pos[1]))
				if ep.distance_to(p) < float(m.rules.spawn_exfil_sight_m) and t.is_line_clear(p, ep):
					sighted += 1
		for k in 8:
			var p2 := c + Vector2.from_angle(k * TAU / 8.0) * float(s.pad_radius) * 0.5
			if absf(t.grid_height(p2.x, p2.y) - float(s.pos[1])) > 3.0:
				flat_bad += 1
	_expect(bad_areas == 0, "all %d spawn areas on dry walkable ground outside the pads (%d not)" % [total_areas, bad_areas])
	_expect(sighted == 0, "no spawn area in sight of a nearby exfil zone (%d)" % sighted)
	_expect(flat_bad == 0, "site pads are level (%d samples off)" % flat_bad)


# ------------------------------------------------------------------ 4 a raid

func _start_raid() -> Battle:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	var flag_task := {"id": "qa_flag", "kind": RaidTaskBoard.KIND_FLAG, "faction": "diamond_sword", "count": 1}
	flag_task["reward"] = RaidTaskBoard.make_reward(flag_task)
	var gen_task := {"id": "qa_gen", "kind": RaidTaskBoard.KIND_GENERATOR, "faction": "blood_eagle", "count": 1}
	gen_task["reward"] = RaidTaskBoard.make_reward(gen_task)
	p.tasks = [flag_task, gen_task]
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


func _check_raid() -> void:
	print("4 raid on Varuna's Fall:")
	var battle := await _start_raid()
	var x := battle.extraction
	var sp := x.site_spawner
	_expect(sp != null and sp.sites.size() >= 14, "the spawn director runs with %d sites" % (sp.sites.size() if sp else 0))
	_expect(x.zones.size() == 5 and x.map.areas.size() >= 16, "5 exfil zones and %d loot areas from the map" % x.map.areas.size())
	_expect(x.faction_teams.values().has("bioderm") and x.faction_teams.size() >= 5, "all factions in play: %s" % [x.faction_teams.values()])
	var ok_sites := 0
	for s in sp.sites:
		if sp.count_alive(s) >= 1:
			ok_sites += 1
	_expect(ok_sites == sp.sites.size(), "every site starts with a garrison (%d of %d)" % [ok_sites, sp.sites.size()])
	var soldiers := battle.vehicles.values().filter(func(h: Herc) -> bool: return h is Infantry and x.faction_teams.has(h.team))
	_expect(soldiers.size() > 20 and soldiers.size() <= int(SiteSpawner.rules().max_alive), "faction soldiers: %d (cap %d)" % [soldiers.size(), SiteSpawner.rules().max_alive])
	_expect(x.tasks.by_peer.values().all(func(states: Array) -> bool: return states.all(func(t: Dictionary) -> bool: return not t.void)),
		"flag and generator tasks of these factions are bound (%s)" % [x.tasks.by_peer.values()])
	await _check_refill(battle, sp)
	await _check_timers(sp)
	await _check_patrol_and_raid(sp)


## A site refills after kills when a player is near: on its timer, in batches, at its own spawn areas.
func _check_refill(battle: Battle, sp: SiteSpawner) -> void:
	print("4b population refill:")
	var site := sp.find_site("airfield")
	var cap_rules: Dictionary = ExtractionRules.data().site_spawns
	var cap: Variant = cap_rules.max_alive
	_expect(sp.count_total_alive() <= int(cap), "the raid never holds more than %d faction soldiers at the start (%d)" % [cap, sp.count_total_alive()])
	# The other sites' garrisons sleep (BotSleep): they neither fight this site's reinforcements nor count against the cap.
	var asleep := 0
	for other in sp.sites:
		if other != site:
			for b in other.bots:
				BotSleep.apply(b.soldier, b, true)
				asleep += 1
	_expect(asleep > 0 and sp.count_awake_alive() == sp.count_total_alive() - asleep,
		"sleeping soldiers (%d) do not count against the raid's cap of %d" % [asleep, int(cap)])
	cap_rules["max_alive"] = 400   # the cap is not under test below: only the site's timers are looked at
	sp.apply_tick(1.0)
	var target := int(site.target)
	var before := sp.count_alive(site)
	for b in site.bots.duplicate():
		(b.soldier as Infantry).apply_environment_damage(1.0)
	await _frames(2)
	_expect(sp.count_alive(site) == 0 and sp.is_under_attack(site), "the garrison (%d of %d) is wiped out and the site is under attack" % [before, target])
	var player := battle.player as Infantry
	var landed := false
	for i in 3600:
		if not player.stowed:
			landed = true
			break
		await get_tree().physics_frame
	_expect(landed, "the player landed from the transport")
	player.spawn_protection = 100000.0
	player.apply_spawn_protection()
	var far := Vector3(site.pos.x + 5000.0, 0.0, site.pos.z)
	player.global_position = far
	for i in 6:
		sp.apply_tick(60.0)
	_expect(sp.count_alive(site) == 0 and not site.awake, "nobody comes while no player is within %d m" % SiteSpawner.rules().activation_radius_m)
	player.global_position = site.pos + Vector3(300, 3, 0)
	var first_timer := sp.make_timer_left(site)
	sp.apply_tick(0.5)
	_expect(sp.count_alive(site) == 0 and bool(site.awake), "a player in range wakes the site; the timer (%.0f s) has not run out" % first_timer)
	sp.movement_paused = true   # a raid or patrol met on the way would kill the reinforcements and make the time random
	var steps := 0
	while sp.count_alive(site) < target and steps < REFILL_MAX_TICKS:
		sp.apply_tick(30.0)
		await _frames(1)
		steps += 1
	print("    alive %d target %d awake %s player alive %s total %d" % [sp.count_alive(site), target, site.awake, player.alive, sp.count_total_alive()])
	sp.movement_paused = false
	cap_rules["max_alive"] = cap
	_expect(sp.count_alive(site) >= target, "the population is back to %d after the reinforcement timers (%d ticks of 30 s)" % [target, steps])
	var near := true
	for b in site.bots:
		near = near and Vector2(b.soldier.global_position.x - site.pos.x, b.soldier.global_position.z - site.pos.z).length() < float(site.pad_radius) * 4.0
	_expect(near, "reinforcements stand at the site's spawn areas")
	_expect(site.bots.all(func(b: InfantryBot) -> bool: return b.guard_radius > 0.0 and int(b.soldier.team) == int(site.team)), "and guard it for their faction")


func _check_timers(sp: SiteSpawner) -> void:
	print("4c timers:")
	var human := sp.find_site("pass_station_north")
	var horde := sp.find_site("cave_warren")
	var day := rulesday()
	sp.clock_s = float(day.length_s) * 0.5
	human["attacked_until"] = -1.0
	var calm := _mean_timer(sp, human)
	sp.apply_alert(human, 60.0)
	var attacked := _mean_timer(sp, human)
	_expect(attacked < calm * 0.7, "reinforcements come faster under attack (%.0f s vs %.0f s)" % [attacked, calm])
	human["attacked_until"] = -1.0
	var horde_day := _mean_timer(sp, horde)
	var human_day := _mean_timer(sp, human)
	sp.clock_s = float(day.length_s) * 0.85
	_expect(sp.is_night(), "the clock reaches night")
	var horde_night := _mean_timer(sp, horde)
	var human_night := _mean_timer(sp, human)
	_expect(horde_night < horde_day * 0.8, "the horde reinforces faster at night (%.0f s vs %.0f s)" % [horde_night, horde_day])
	_expect(human_night > human_day * 1.2, "factions slower at night (%.0f s vs %.0f s)" % [human_night, human_day])
	sp.clock_s = float(day.length_s) * 0.5


func rulesday() -> Dictionary:
	return SiteSpawner.rules().day


func _mean_timer(sp: SiteSpawner, site: Dictionary) -> float:
	var sum := 0.0
	for i in 200:
		sum += sp.make_timer(site)
	return sum / 200.0


func _check_patrol_and_raid(sp: SiteSpawner) -> void:	# (async: waits for the thinned garrisons)
	print("4d patrols and horde raids:")
	var dest := sp.find_site("salvage_yard")
	for s in sp.sites:
		sp._spawn_at_site(s, 8)
	sp.apply_patrol_in(0.0)
	sp.apply_tick(1.0)
	_expect(sp.patrol_count >= 1 and not sp.patrols.is_empty(), "a patrol sets out between two sites of one faction (%d)" % sp.patrol_count)
	if not sp.patrols.is_empty():
		var p: Dictionary = sp.patrols[0]
		var walker: InfantryBot = p.bots[0]
		var goal: Dictionary = walker.objective
		_expect(not goal.is_empty() and int((p.dest as Dictionary).team) == int(walker.soldier.team) and p.src != p.dest, "walking to another site of its own faction")
		var joined: int = (p.dest as Dictionary).bots.size()
		walker.soldier.global_position = (p.dest as Dictionary).pos + Vector3(5, 1, 0)
		sp.apply_tick(1.0)
		_expect((p.dest as Dictionary).bots.has(walker) and walker.objective.is_empty() and (p.dest as Dictionary).bots.size() == joined + 1, "arriving soldiers join the garrison")
	var weakest := sp.find_weakest_site(sp.find_site("cave_warren"), "bioderm", 2600.0)
	_expect(not weakest.is_empty() and str(weakest.faction) != "bioderm", "the horde finds its weakest neighbour (%s)" % weakest.get("id", "none"))
	sp.raids.clear()
	for s in sp.sites:
		for b in s.bots.duplicate():
			if s.bots.size() > 2:
				(b.soldier as Infantry).apply_environment_damage(1.0)
	await _frames(2)
	_expect(sp.start_raid() and not sp.raids.is_empty(), "the caves send a raiding party")
	if not sp.raids.is_empty():
		var r: Dictionary = sp.raids[0]
		var raider: InfantryBot = r.bots[0]
		_expect(bool(raider.objective.get("urgent", false)) and str(ExtractionFactions.kind_of("bioderm")) == "bioderm" and int(raider.soldier.team) == int(sp.find_site("cave_warren").team),
			"raiders hunt the target site (%s)" % (r.target as Dictionary).id)
	_expect(dest.size() > 0, "sites are queryable")

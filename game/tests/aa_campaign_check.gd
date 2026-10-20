extends Node
## Tribes: Aerial Assault on the game side (tools/aa_import.py output): the campaign is offered in New campaign, its
## missions carry briefing and objective text, the save round-trips, every imported map loads, and a campaign mission
## starts in a Battle with the player on foot, the AAMissionRuntime and its objective lines.
##   godot --headless --audio-driver Dummy --path game res://tests/aa_campaign_check.tscn
## AA_TEST_ROOT=<folder with tribes_aa/ and tribes2/> points the check at a scratch data folder (else the installed one).
## Skips (exit 0) when Aerial Assault is not imported.

const WATCHDOG_SECONDS := 150.0
const SETTLE_FRAMES := 30
const PACK := "tribes_aa"

var _fails := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void:
		print("FAIL  watchdog: the check hung")
		get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var root := OS.get_environment("AA_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	if not Assets.has_pack(PACK):
		print("aa_campaign_check: Aerial Assault is not imported, skipped")
		get_tree().quit(0)
		return
	_check_choices()
	_check_campaign()
	_check_maps()
	await _check_battle(0)                 # training 1
	await _check_battle(_first_with_goal(AAMissionRuntime.GOAL_GENERATORS))
	await _check_battle(_first_with_goal(AAMissionRuntime.GOAL_WAYPOINTS))
	_check_logic()
	await _check_scripted_battle()
	await _check_arena_battle()
	print("aa_campaign_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _check_choices() -> void:
	var found := MatchFlow.make_new_campaign_choices().filter(func(c: Dictionary) -> bool: return str(c.pack) == PACK)
	_expect(found.size() == 1, "New campaign lists Aerial Assault once")
	_expect(not found.is_empty() and bool(found[0].playable) == Assets.has_pack("tribes2"), "playable when Tribes 2 is installed")
	_expect(not found.is_empty() and str(found[0].description) != "", "it has a description")
	_expect(not Saga.available_stages().any(func(s: Dictionary) -> bool: return str(s.name).contains("Aerial")),
		"the saga does not include it")


func _check_campaign() -> void:
	Session.start_stage_campaign(PACK)
	var c: Object = Session.campaign
	_expect(c != null and c.missions.size() == 16, "16 missions (5 training, 11 numbered)")
	var b := Session.briefing()
	_expect(str(b.get("briefing", "")).length() > 100, "the first briefing has text")
	_expect(not MatchFlow.make_issued_soldier().is_empty(), "the mission issues a soldier")
	_expect(Session.make_mission_heading(c).contains("mission 1 of 16"), "heading: " + Session.make_mission_heading(c))
	c.record_result(true)
	var d := Session.make_save_dict()
	Session.apply_save_dict(d)
	_expect(Session.campaign.index == 1 and Session.campaign_pack(Session.campaign) == PACK, "the save restores the campaign and its position")
	_expect(SaveGames.make_campaign_title(PACK, "") == "Tribes: Aerial Assault", "save title")
	Session.start_stage_campaign(PACK)


func _check_maps() -> void:
	var idx = Assets.load_json("maps/_index.json", PACK)
	_expect(idx is Array and (idx as Array).size() >= 30, "arena maps are indexed")
	var bad := 0
	for e in idx:
		var m := MapBuilder.load_map("%s:%s" % [PACK, e.id])
		if m.is_empty() or (m.spawns as Array).is_empty():
			bad += 1
	_expect(bad == 0, "every indexed map loads with spawns (%d bad)" % bad)


func _first_with_goal(goal: String) -> int:
	var c: Object = Session.campaign
	for i in c.missions.size():
		var m := MapBuilder.load_map("%s:%s" % [PACK, c.missions[i].map])
		if AAMissionRuntime.make_goal(m) == goal:
			return i
	return 0


func _check_battle(i: int) -> void:
	if not Assets.has_pack("tribes2"):
		return
	Session.start_stage_campaign(PACK)
	Session.campaign.index = i
	var herc := MatchFlow.make_issued_soldier()
	var cfg := MatchFlow.make_mission_config(str(herc.vehicle), [], {})
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = cfg
	get_tree().root.add_child(b)
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	var name := str(Session.current_mission().get("name", ""))
	_expect(b.mission is AAMissionRuntime, "%s: runs AAMissionRuntime" % name)
	_expect(b.player != null and b.player is Infantry, "%s: the player is a soldier" % name)
	var lines: Array = MissionObjectives.make_lines(b)
	_expect(not lines.is_empty(), "%s: objective lines (%d): %s" % [name, lines.size(), str(lines.back().text) if not lines.is_empty() else ""])
	if b.mission is AAMissionRuntime and b.player != null:
		var spawn: Transform3D = b.mission.player_spawn(0)
		_expect(b.player.global_position.distance_to(spawn.origin) < 30.0, "%s: the player starts at the map's spawn" % name)
	if b.mission is AAMissionRuntime and (b.mission as AAMissionRuntime).goal == AAMissionRuntime.GOAL_GENERATORS:
		await _check_generator_win(b, name)
	b.queue_free()
	for _f in 3:
		await get_tree().process_frame


## Destroying the targeted generators (the base reports them) wins the mission.
func _check_generator_win(b: Battle, name: String) -> void:
	var base := TribesBase.of(b)
	_expect(base != null, "%s: the Tribes 2 base equipment is built for the map" % name)
	if base == null:
		return
	var rt := b.mission as AAMissionRuntime
	var seen := 0
	for o in base.objects:
		if o.kind == TribesBaseObject.KIND_GENERATOR:
			seen += 1
			base.object_destroyed.emit(o, null)
	_expect(seen >= rt.targets.size() and seen > 0, "%s: %d generator objects for %d targets" % [name, seen, rt.targets.size()])
	_expect(rt.is_over(), "%s: destroying them ends the mission" % name)


# ------------------------------------------------------------------ mission logic (campaign/logic.json, AAScript)

func _check_logic() -> void:
	var t := AAScript.parse_spawn_tag("DERM_1L_1M_2W")
	_expect(t.team == 1 and t.light == 1 and t.medium == 1 and t.heavy == 0 and t.wave == 1, "tag DERM_1L_1M_2W parses (wave 1)")
	t = AAScript.parse_spawn_tag("BOT_3H_2L_1M")
	_expect(t.team == 0 and t.heavy == 3 and t.light == 2 and t.medium == 1 and t.wave == 0, "tag BOT_3H_2L_1M parses (wave 0)")
	_expect(AAScript.parse_spawn_tag("GEN1").is_empty() and AAScript.parse_spawn_tag("DERM_XL").is_empty(), "other tags are no spawns")
	var j = Assets.load_json(AAScript.LOGIC_FILE, PACK)
	_expect(j is Dictionary and (j.missions as Dictionary).size() == 16, "logic.json holds the 11 numbered missions and the 5 trainings")
	if not (j is Dictionary):
		return
	var arena := 0
	var scripted := 0
	var trainings := 0
	var last := 0
	for folder in (j.missions as Dictionary):
		var rec: Dictionary = j.missions[folder]
		if rec.type == AAScript.TYPE_TRAINING:
			trainings += 1
			_expect(rec.has("script"), "%s: has its lessons" % folder)
			continue
		arena += 1 if rec.type == AAScript.TYPE_ARENA else 0
		scripted += 1 if rec.type == AAScript.TYPE_SCRIPTED else 0
		_expect(int(rec.objectives_index) > last, "%s: objective list %d follows the previous" % [folder, int(rec.objectives_index)])
		last = int(rec.objectives_index)
		if rec.type == AAScript.TYPE_ARENA:
			_expect(int(rec.score_limit) > 0, "%s: arena score limit %d (%s)" % [folder, int(rec.score_limit), rec.mode])
			continue
		var map := MapBuilder.load_map("%s:%s" % [PACK, folder.substr(0, 1) + folder.substr(1).to_lower()])
		var points := AAScript.make_spawn_points(map)
		_expect(rec.has("script"), "%s: has its state machine" % folder)
		for sp in _spawns_of(rec.get("script", {})):
			_expect(not AAScript.make_wave_soldiers(points, int(sp[0]), int(sp[1])).is_empty(),
				"%s: the %s of wave %d exist on the map" % [folder, "enemies" if int(sp[0]) == 1 else "allies", int(sp[1])])
	_expect(arena == 5 and scripted == 6 and trainings == 5, "five arena, six scripted missions and five trainings (%d, %d, %d)" % [arena, scripted, trainings])


## [[team, wave]] of every spawn action of a script.
func _spawns_of(node: Variant) -> Array:
	var out := []
	if node is Dictionary:
		for k in node:
			out.append_array(_spawns_of(node[k]))
	elif node is Array:
		var a: Array = node
		if a.size() == 3 and str(a[0]) == "spawn":
			out.append([1 if str(a[1]) == "enemies" else 0, int(a[2])])
		else:
			for x in a:
				out.append_array(_spawns_of(x))
	return out


func _mission_index(folder: String) -> int:
	var c: Object = Session.campaign
	for i in c.missions.size():
		if str(c.missions[i].get("folder", "")) == folder:
			return i
	return 0


func _start_battle(folder: String) -> Battle:
	Session.start_stage_campaign(PACK)
	Session.campaign.index = _mission_index(folder)
	var herc := MatchFlow.make_issued_soldier()
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = MatchFlow.make_mission_config(str(herc.vehicle), [], {})
	get_tree().root.add_child(b)
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	return b


## Onslaught: the vehicle pad, then the base, then the BioDerm waves; the player and the allies wear the Aerial Assault bodies.
func _check_scripted_battle() -> void:
	if not Assets.has_pack("tribes2") or AAScript.make_logic("MISSION06").is_empty():
		return
	var b := await _start_battle("MISSION06")
	var rt := b.mission as AAMissionRuntime
	_expect(rt != null and rt.goal == AAMissionRuntime.GOAL_SCRIPT and rt.vm != null and rt.vm.state == 1, "Onslaught runs its state machine (state 1)")
	if rt == null or rt.vm == null:
		b.queue_free()
		return
	_expect(rt.count_alive(rt.enemies) == 0, "no enemies before the player reaches the base")
	_expect((b.player as Infantry).body_shape.begins_with("tribes_aa:") or InfantryCatalog.make_aa_bodies(AAMissionRuntime.ARMOR).is_empty(),
		"the player wears an Aerial Assault body")
	b.player.global_position = AAScript.make_tag_positions(rt.map, "VSTATION1")[0] + Vector3(0, 2, 0)
	for _f in 40:
		await get_tree().process_frame
	_expect(rt.vm.state == 2, "the vehicle pad starts the drive (state %d)" % rt.vm.state)
	b.player.global_position = AAScript.make_tag_positions(rt.map, "WAYPT1")[0] + Vector3(0, 2, 0)
	for _f in 40:
		await get_tree().process_frame
	_expect(rt.vm.state == 3, "reaching WAYPT1 starts the siege (state %d)" % rt.vm.state)
	_expect(rt.count_alive(rt.enemies) == 0, "the first wave waits for the preparation time")
	rt.vm.state_time = 190.0
	for _f in 40:
		await get_tree().process_frame
	var first := AAScript.make_wave_soldiers(rt._spawn_points, 1, 0).size()
	_expect(rt.count_alive(rt.enemies) == first and first > 0, "wave 0 spawned: %d of %d soldiers" % [rt.count_alive(rt.enemies), first])
	_expect(not rt.is_over(), "the mission goes on while enemies live")
	var lines: Array = MissionObjectives.make_lines(b)
	_expect(not lines.is_empty() and str(lines.back().text) == rt.vm.state_text() and rt.vm.state_text() != "", "the objective line is the state's (%d lines)" % lines.size())
	b.queue_free()
	for _f in 3:
		await get_tree().process_frame


## Arena mission 1: enemy bots fill the arena; kills reach the score limit and win.
func _check_arena_battle() -> void:
	if not Assets.has_pack("tribes2") or AAScript.make_logic("MISSION01").is_empty():
		return
	var b := await _start_battle("MISSION01")
	var rt := b.mission as AAMissionRuntime
	_expect(rt != null and rt.goal == AAMissionRuntime.GOAL_ARENA, "mission 1 is an arena mission")
	if rt == null:
		b.queue_free()
		return
	for _f in 30:
		await get_tree().process_frame
	_expect(rt.count_alive(rt.enemies) == int(rt.logic.enemy_bots), "the arena fills with %d bots (%d)" % [int(rt.logic.enemy_bots), rt.count_alive(rt.enemies)])
	var foe: Infantry = (rt.enemies[0] as InfantryBot).soldier
	for _k in int(rt.logic.score_limit) - 1:
		rt.on_unit_destroyed(foe)
	await get_tree().process_frame
	_expect(not rt.is_over(), "one kill short of the limit is not a win")
	rt.on_unit_destroyed(foe)
	for _f in 30:
		await get_tree().process_frame
	_expect(rt.is_over(), "the score limit wins the mission")
	b.queue_free()
	for _f in 3:
		await get_tree().process_frame

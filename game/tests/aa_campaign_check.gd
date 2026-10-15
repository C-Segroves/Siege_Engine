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

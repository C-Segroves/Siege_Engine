extends Node
## Tribes: Vengeance on the game side (tools/tv_import.py output): the campaign is offered in New campaign, its missions
## carry names and objective text, the save round-trips, every imported map loads with a player start, and campaign
## missions start in a Battle with the player on foot, the TVMissionRuntime and its objective lines.
##   godot --headless --audio-driver Dummy --path game res://tests/tv_campaign_check.tscn
## TV_TEST_ROOT=<folder with tribes_v/ and tribes2/> points the check at a scratch data folder (else the installed one).
## Skips (exit 0) when Tribes: Vengeance is not imported.

const WATCHDOG_SECONDS := 150.0
const SETTLE_FRAMES := 30
const PACK := "tribes_v"
const MISSIONS := 33

var _fails := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void:
		print("FAIL  watchdog: the check hung")
		get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var root := OS.get_environment("TV_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	if not Assets.has_pack(PACK):
		print("tv_campaign_check: Tribes: Vengeance is not imported, skipped")
		get_tree().quit(0)
		return
	_check_choices()
	_check_campaign()
	_check_maps()
	_check_geometry()
	_check_characters_audio_scripts()
	await _check_battle(0)
	await _check_battle(_first_with_waypoints())
	print("tv_campaign_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _check_choices() -> void:
	var found := MatchFlow.make_new_campaign_choices().filter(func(c: Dictionary) -> bool: return str(c.pack) == PACK)
	_expect(found.size() == 1, "New campaign lists Tribes: Vengeance once")
	_expect(not found.is_empty() and bool(found[0].playable) == Assets.has_pack("tribes2"), "playable when Tribes 2 is installed")
	_expect(not found.is_empty() and str(found[0].description) != "", "it has a description")


func _check_campaign() -> void:
	Session.start_stage_campaign(PACK)
	var c: Object = Session.campaign
	_expect(c != null and c.missions.size() == MISSIONS, "%d missions in play order" % MISSIONS)
	_expect(c != null and c.pack_id() == PACK, "the campaign belongs to the pack")
	var b := Session.briefing()
	_expect(str(b.get("briefing", "")).length() > 20, "the first briefing has text")
	var with_objectives: Array = c.missions.filter(func(m: Dictionary) -> bool: return str(m.get("objectives_text", "")) != "")
	_expect(with_objectives.size() >= 20, "%d missions carry objective text" % with_objectives.size())
	_expect(Session.make_mission_heading(c).contains("mission 1 of %d" % MISSIONS), "heading: " + Session.make_mission_heading(c))
	c.record_result(true)
	var d := Session.make_save_dict()
	Session.apply_save_dict(d)
	_expect(Session.campaign.index == 1 and Session.campaign_pack(Session.campaign) == PACK, "the save restores the campaign and its position")
	Session.start_stage_campaign(PACK)


func _check_maps() -> void:
	var idx = Assets.load_json("maps/_index.json", PACK)
	_expect(idx is Array and (idx as Array).size() == MISSIONS, "maps are indexed")
	var bad := 0
	for e in idx:
		var m := MapBuilder.load_map("%s:%s" % [PACK, e.id])
		if m.is_empty() or (m.spawns as Array).is_empty():
			bad += 1
	_expect(bad == 0, "every indexed map loads with a player start (%d bad)" % bad)


## Terrain and static meshes: most outdoor maps have a heightmap, and the shapes the maps place load with polygons.
func _check_geometry() -> void:
	var idx = Assets.load_json("maps/_index.json", PACK)
	var terrains := 0
	var placed := 0
	var empty := 0
	var checked := {}
	for e in idx:
		var m := MapBuilder.load_map("%s:%s" % [PACK, e.id])
		if m.get("terrain") is Dictionary:
			terrains += 1
			var t: Dictionary = m.terrain
			var heights := FileAccess.get_file_as_bytes(str(m._dir).path_join(str(t.heights))).to_float32_array()
			if heights.size() != int(t.size[0]) * int(t.size[1]):
				empty += 1
		for o in m.get("statics", []):
			placed += 1
			var sid := str(o.shape)
			if not checked.has(sid):
				checked[sid] = true
				if Assets.shape(sid).get("lods", [{}])[0].get("pieces", []).is_empty():
					empty += 1
	_expect(terrains >= 15, "%d maps have terrain" % terrains)
	_expect(placed > 1000 and checked.size() > 100, "%d statics placed from %d shapes" % [placed, checked.size()])
	_expect(empty == 0, "every terrain grid and shape is complete (%d bad)" % empty)


## Skeletal bodies (gameplay/bodies.json), the placed soldiers' bodies, the sounds and speech, the mission scripts.
func _check_characters_audio_scripts() -> void:
	var bodies = Assets.load_json("gameplay/bodies.json", PACK)
	_expect(bodies is Dictionary and (bodies.bodies as Array).size() >= 30, "%d skeletal bodies imported" % (bodies.bodies.size() if bodies is Dictionary else 0))
	var offered := InfantryCatalog.make_tv_bodies("tribes2:MEDIUM")
	_expect(offered.size() >= 6 or not Assets.has_pack("tribes2"), "medium armour is offered %d Vengeance bodies" % offered.size())
	_expect(offered.all(func(b: Dictionary) -> bool: return InfantryCatalog.is_shape_animated(str(b.id))), "every offered body is animated")
	var idx = Assets.load_json("maps/_index.json", PACK)
	var npcs := 0
	var with_body := 0
	var scripted := 0
	var voices := 0
	for e in idx:
		var m := MapBuilder.load_map("%s:%s" % [PACK, e.id])
		for n in m.get("npc_spawns", []):
			npcs += 1
			if str(n.get("body", "")) != "":
				with_body += 1
				if not InfantryCatalog.is_shape_installed("%s:%s" % [PACK, n.body]):
					with_body -= 1
		if FileAccess.file_exists(str(m._dir).path_join(str(m.get("script", "script.json")))):
			scripted += 1
		voices += (m.get("voice", []) as Array).size()
	_expect(with_body > 500 and with_body * 3 > npcs, "%d of %d placed soldiers have an installed body" % [with_body, npcs])
	_expect(scripted == idx.size(), "%d of %d maps carry a script" % [scripted, idx.size()])
	_expect(voices > 500, "%d speech lines are imported" % voices)
	var sounds = Assets.load_json("audio/sounds.json", PACK)
	_expect(sounds is Dictionary and (sounds.sounds as Dictionary).size() > 1000, "%d sounds imported" % (sounds.sounds.size() if sounds is Dictionary else 0))
	_expect(sounds is Dictionary and (sounds.weapons as Dictionary).has("Spinfusor"), "the weapon sounds are mapped by weapon")
	_expect(Sfx.stream("%s:tv_weapons/Spinfusor_Fired1" % PACK) != null, "a weapon sound loads through Sfx")
	var props = Assets.load_json("gameplay/props.json", PACK)
	_expect(props is Dictionary and (props.props as Dictionary).has("tank") and (props.props as Dictionary).has("pod"), "vehicle shapes are imported")


func _first_with_waypoints() -> int:
	var c: Object = Session.campaign
	for i in range(1, c.missions.size()):
		var m := MapBuilder.load_map("%s:%s" % [PACK, c.missions[i].map])
		if not (m.get("waypoints", []) as Array).is_empty():
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
	_expect(b.mission is TVMissionRuntime, "%s: runs TVMissionRuntime" % name)
	_expect(b.player != null and b.player is Infantry, "%s: the player is a soldier" % name)
	var lines: Array = MissionObjectives.make_lines(b)
	_expect(not lines.is_empty(), "%s: objective lines (%d)" % [name, lines.size()])
	if b.mission is TVMissionRuntime:
		_expect(b.mission.script_run != null, "%s: the mission script runs" % name)
		_expect(b.mission._npcs.size() > 0 or i != 0, "%s: placed soldiers are registered (%d)" % [name, b.mission._npcs.size()])
		_expect(b.player is Infantry and (b.player as Infantry).make_body_shape_id().begins_with(PACK + ":") or not Assets.has_pack("tribes2"),
			"%s: the player wears a Vengeance body" % name)
	if b.mission is TVMissionRuntime and b.player != null:
		var spawn: Transform3D = b.mission.player_spawn(0)
		_expect(b.player.global_position.distance_to(spawn.origin) < 30.0, "%s: the player starts at the map's spawn" % name)
	b.queue_free()
	for _f in 3:
		await get_tree().process_frame

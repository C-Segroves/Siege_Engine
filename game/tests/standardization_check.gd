extends Node
## Headless check of the cross-game shared abstractions (docs/STANDARDIZATION_AUDIT.md, playtest item C1):
##   Godot --headless --audio-driver Dummy --path game res://tests/standardization_check.tscn
## - MissionKinds picks each game's MissionRuntime and gives the same launch config and mission Herc as the
##   per-game branches it replaced (reference copies of those branches live in this file);
## - RadioLine names every game's voice clips the way each producer did;
## - the cockpit's wingman comm window shows the face of the pilot whose voice the radio speaks;
## - every game's runtime builds its own objectives-panel lines (make_objective_lines), the same lines the
##   per-game builders of MissionObjectives made (reference copies below), in a running battle of each game;
## - each campaign provider words its own killed / victory / defeat pages (CampaignPresentation);
## - SceneLighting gives the Earthsiege 1 / 2 worlds the environment and sun their builders made before.
## Missions come from the installed packs; a pack that is not installed is skipped.

const ES1_MISSION := "B0_C0_0A"
const SS_MISSION := "starsiege:HA0"
const TRIBES_PACKS := ["tribes", "tribes2"]
const SETTLE_FRAMES := 30
## Battles of each game for the objective lines: [mission name, player vehicle, pack].
const OBJECTIVE_BATTLES := [["B0_C0_0A", "es1:RAPTOR", "es1"], ["es2:C1_01", "es2:MONGOOSE", "es2"],
	["starsiege:HA0", "starsiege:pi_eman", "starsiege"], ["tribes:1_Welcome", "", "tribes"]]

var _errors := 0
var _temp_nodes: Array[Node] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_mission_kinds()
	_check_radio_lines()
	_check_wingman_faces()
	_check_palette_lighting()
	_check_presentations()
	_check_es2_status()
	_check_mission_end()
	_check_rules_clock()
	_check_bd_turret_sides()
	_check_bd_turret_wreck()
	_check_bd_pad_sides()
	_check_world_gravity()
	_check_ai_detour()
	_check_dynamic_lights()
	_check_palette_lights()
	_check_mission_outcome()
	await _check_objective_lines()
	await _check_area_rules()
	await _check_damage_models()
	await _check_briefing_presentation()
	print("standardization_check: %s" % ("OK" if _errors == 0 else "FAILED (%d)" % _errors))
	get_tree().quit(1 if _errors else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_errors += 1


# ------------------------------------------------------------------ MissionKinds

func _check_mission_kinds() -> void:
	print("MissionKinds:")
	for m in _make_missions():
		var label := str(m.get("mission_name", m.get("pack", "es1")))
		_expect(MissionKinds.runtime_script(m) == _reference_runtime_script(m), "%s: runtime %s" % [label,
			MissionKinds.runtime_script(m).get_global_name()])
		for keep_choice in [false, true]:
			var got := _make_config(keep_choice)
			MissionKinds.apply_to_config(got, m)
			var want := _make_config(keep_choice)
			_reference_apply(want, m)
			_expect(_same_config(got, want), "%s: launch config (keep player's choice %s)" % [label, keep_choice])
	_check_synthetic_kinds()


## Hand-made missions of every kind, so the dispatch is checked without the packs too.
func _check_synthetic_kinds() -> void:
	_expect(MissionKinds.runtime_script({}) == MissionRuntime, "no pack: Earthsiege runtime")
	_expect(MissionKinds.runtime_script({"pack": "es2"}) == MissionRuntimeES2, "pack es2: Earthsiege 2 runtime")
	_expect(MissionKinds.runtime_script({"pack": "starsiege"}) == StarsiegeMissionRuntime, "pack starsiege")
	_expect(MissionKinds.runtime_script({"pack": "tribes", "runtime": "tribes"}) == Tribes1MissionRuntime, "Tribes")
	_expect(MissionKinds.runtime_script({"pack": "tribes2", "runtime": "tribes"}) == Tribes2MissionRuntime, "Tribes 2")
	_expect(MissionKinds.make_mission_herc({"pack": "es1"}).is_empty(), "Earthsiege leaves the Herc to the player")
	_expect(MissionKinds.runtime_script({"runtime": "tribes_aa"}) == AAMissionRuntime, "Aerial Assault is claimed by its registration")
	_expect(MissionKinds.runtime_script({"runtime": "tribes_v"}) == TVMissionRuntime, "Vengeance is claimed by its registration")
	var kinds_source := FileAccess.get_file_as_string("res://engine/mission_kinds.gd")
	_expect(not kinds_source.contains("MissionRuntime."), "engine/mission_kinds.gd names no game runtime class")
	var ss: Object = StarsiegeMissionRuntime.new()
	var tr: Object = Tribes1MissionRuntime.new()
	var es2: Object = MissionRuntimeES2.new()
	_expect(ss is MissionRuntimeBase and tr is MissionRuntimeBase and not (ss is MissionRuntime) and not (tr is MissionRuntime)
		and es2 is MissionRuntime, "Starsiege and Tribes share only the base contract; Earthsiege 2 extends Earthsiege 1")
	_expect("win_rules" not in ss and "regions" not in tr, "no Earthsiege mission state in the Starsiege / Tribes runtimes")
	for n in [ss, tr, es2]:
		n.free()
	var cfg := _make_config(true)
	MissionKinds.apply_to_config(cfg, {"pack": "tribes", "runtime": "tribes", "map": "m", "armor": "tribes:larmor"})
	_expect(cfg.roster[1].vehicle == "tribes:larmor", "Tribes training forces its armour")


func _make_missions() -> Array:
	var out := []
	if Assets.has_pack("es1"):
		out.append(MissionRuntime.load_resolved(ES1_MISSION, PackedInt32Array(), 1))
	if Assets.has_pack("es2"):
		out.append(CampaignES2.start(1).load_current())
	if Assets.has_pack("starsiege"):
		out.append(StarsiegeMissionRuntime.load_mission(SS_MISSION))
	for p in TRIBES_PACKS:
		var listed := TribesMissionRuntime.list_missions(p)
		if not listed.is_empty():
			out.append(TribesMissionRuntime.load_mission("%s:%s" % [p, listed[0].id]))
	return out.filter(func(m: Dictionary) -> bool: return not m.is_empty())


func _make_config(keep_choice: bool) -> Dictionary:
	return {"use_mission_herc": not keep_choice, "roster": {1: {"vehicle": "es1:RAPTOR", "loadout": ["x"]}}}


func _same_config(a: Dictionary, b: Dictionary) -> bool:
	return var_to_str(a) == var_to_str(b)


## The dispatch BattleSetup.make_mission_runtime made before MissionKinds.
func _reference_runtime_script(mdef: Dictionary) -> GDScript:
	if TribesMissionRuntime.is_tribes(mdef):
		return Tribes2MissionRuntime if String(mdef.get("pack", "")) == "tribes2" else Tribes1MissionRuntime
	if mdef.get("pack") == "es2":
		return MissionRuntimeES2
	if StarsiegeMissionRuntime.is_starsiege(mdef):
		return StarsiegeMissionRuntime
	return MissionRuntime


## BattleSetup.apply_mission_to_config before MissionKinds (an empty loadout means the vehicle's own, so the
## Starsiege start vehicle is compared with its standard loadout).
func _reference_apply(config: Dictionary, mdef: Dictionary) -> void:
	if TribesMissionRuntime.is_tribes(mdef):
		config.map = String(mdef.get("map", ""))
		_reference_roster(config, String(mdef.get("armor", "")), [])
		return
	if StarsiegeMissionRuntime.is_starsiege(mdef):
		config.map = String(mdef.get("map", ""))
		var spv := StarsiegeMissionRuntime.player_vehicle(mdef)
		if spv != "" and config.get("use_mission_herc", true):
			_reference_roster(config, spv, Packs.vehicle(spv).get("loadout", []))
	config.world = MissionRuntime.world_index(mdef)
	config.zone = int(mdef.get("header", {}).get("zone", 0))
	if mdef.get("map") is String and String(mdef.map) != "":
		config.map = mdef.map
	if mdef.get("pack") == "es2":
		config.world_pack = "es2"
		config.world = WorldBuilder.es2_world_index(mdef.get("header", {}).get("raw", []))
		if config.get("use_mission_herc", true):
			var pv := MissionRuntimeES2.player_vehicle(mdef)
			_reference_roster(config, pv[0], pv[1])


func _reference_roster(config: Dictionary, vehicle: String, loadout: Array) -> void:
	for peer in config.roster:
		config.roster[peer].vehicle = vehicle
		config.roster[peer].loadout = loadout.duplicate()


# ------------------------------------------------------------------ radio lines

func _check_radio_lines() -> void:
	print("RadioLine:")
	_expect(RadioLine.make_voice_name("es2", "sim/p1_01000") == "es2:sim/p1_01000", "table voice stem kept")
	_expect(RadioLine.make_voice_name("es1", "sim/P1_01000.SFX") == "es1:sim/p1_01000", "table file name lower-cased")
	_expect(SSRadio.make_voice_name("Path/HA1_X01.wav") == "starsiege:ha1_x01", "Starsiege wav argument")
	_expect(SSRadio.make_voice_name("nothing") == "", "Starsiege non-wav argument has no clip")
	_expect(Tribes2Functions.make_voice_name("voice/Training/Mission1/T1_01.wav") == "tribes2:training/mission1/t1_01",
		"Tribes 2 training clip")
	_expect(RadioLine.make_voice_name("es1", "") == "", "no clip, no name")
	for pack in ["es1", "es2"]:
		var t := RadioTable.load_table(pack, "pilot1")
		if t.is_empty():
			continue
		var line := t.make_random_line(WingmanRadio.MSG_KILL)
		_expect(str(line.get("voice", "")).begins_with("%s:sim/p1_" % pack), "%s pilot table clip %s" % [pack, line.get("voice")])


# ------------------------------------------------------------------ wingman faces

func _check_wingman_faces() -> void:
	print("Wingman faces:")
	for slot in 6:
		var want: int = WingmanRadio.PILOT_TABLES[slot % WingmanRadio.PILOT_TABLES.size()]
		_expect(WingmanRadio.pilot_number(slot) == want, "slot %d: face and voice PILOT%d" % [slot, want])
	var units := []
	for slot in [-1, 2, -1, 0, 1]:
		var n := Node.new()
		if slot >= 0:
			n.set_meta(WingmanRadio.SLOT_META, slot)
		units.append(n)
	var ordered := WingmanRadio.make_squad_first(units)
	_expect(ordered.map(func(n): return WingmanRadio.slot_of(n)) == [0, 1, 2, -1, -1] and ordered[3] == units[0],
		"comm windows: the radio squad in slot order, then the other allies")
	for n in units:
		n.free()


# ------------------------------------------------------------------ objective lines

func _check_objective_lines() -> void:
	print("Objective lines:")
	for b in OBJECTIVE_BATTLES:
		if not Assets.has_pack(str(b[2])):
			continue
		var cfg := {"mode": "mission", "respawn": false, "mission_name": b[0],
			"roster": {1: {"name": "Tester", "vehicle": b[1], "team": 0, "loadout": []}}}
		var battle: Node = load("res://games/es1/battle.tscn").instantiate()
		battle.config = cfg
		get_tree().root.add_child(battle)
		for i in SETTLE_FRAMES:
			await get_tree().physics_frame
		var got := MissionObjectives.make_lines(battle)
		var want := _reference_lines(battle.mission)
		_expect(var_to_str(got) == var_to_str(want), "%s: %d lines as before %s" % [b[0], got.size(), got])
		_expect(str(b[2]).begins_with("tribes") or not got.is_empty(), "%s: the mission has objective lines" % b[0])
		_check_ruin_collision(battle, str(b[2]))
		battle.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame


## The per-game builders MissionObjectives had before each runtime answered for itself.
func _reference_lines(rt: Node) -> Array:
	if rt is MissionRuntimeES2:
		return _reference_es2(rt)
	if rt is StarsiegeMissionRuntime:
		return _reference_starsiege(rt)
	if rt is TribesMissionRuntime:
		var out := []
		for line in rt.output.objectives:
			if str(line).strip_edges() != "":
				out.append({"text": str(line), "done": false})
		return out
	return _reference_es1(rt)


func _reference_es1(rt: MissionRuntime) -> Array:
	var met := rt.win_rules != null and rt.win_rules.objective_met()
	var kind := int(rt.m.get("header", {}).get("mission_type", 1))
	var target := "the target"
	var t = rt.win_rules.squad_target()
	if t is Dictionary:
		for n in rt.target_nodes(t):
			if is_instance_valid(n) and "display_name" in n and str(n.display_name) != "":
				target = str(n.display_name)
				break
	var out := []
	if kind in [4, 5]:
		out.append({"text": "Protect %s" % target, "done": met})
	elif kind in [6, 8, 9]:
		out.append({"text": "Destroy %s" % target, "done": met})
	elif kind == 0:
		out.append({"text": "Identify %s (target it)" % target, "done": met})
	elif kind == 3:
		out.append({"text": "Establish the data link at %s" % target, "done": met})
	elif kind == 7:   # escort: its own line since the type-7 fix (mission.md 5)
		out.append({"text": "Escort %s to the end of its route" % target, "done": met})
	elif not kind in [1, 2]:
		out.append({"text": "Destroy all hostiles", "done": met})
	if not rt.nav_points.is_empty():
		var reached := mini(rt.nav_index, rt.nav_points.size())
		out.append({"text": "Reach the nav points (%d of %d)" % [reached, rt.nav_points.size()],
			"done": reached >= rt.nav_points.size()})
	return out


func _reference_es2(rt: MissionRuntimeES2) -> Array:
	var texts: Dictionary = rt.m.get("texts", {}) if rt.m.get("texts") is Dictionary else {}
	var complete := rt.rules != null and rt.rules.status in [9, 10]
	var out := []
	for line in MissionRuntime._arr(texts.get("objectives")):
		var text := str(line).replace("
", " ").strip_edges()
		if text != "":
			out.append({"text": text, "done": complete})
	if out.is_empty():
		out.append({"text": "Complete the mission objectives", "done": complete})
	return out


func _reference_starsiege(rt: StarsiegeMissionRuntime) -> Array:
	var out := []
	var done_word := str(rt.vm.strings.get("IDSTR_OBJ_COMPLETED", "Completed")).to_lower()
	for k in rt.vm.objects:
		var ob: Dictionary = rt.vm.objects[k]
		if str(ob.get("__type", "")).to_lower() != "missionbriefobjective":
			continue
		var status := SSScript.to_str(rt.vm.get_field(k, "status")).to_lower()
		out.append({"text": SSScript.to_str(ob.get("shorttxt", k)), "done": status == done_word})
	return out


# ------------------------------------------------------------------ lighting

func _check_palette_lighting() -> void:
	print("SceneLighting:")
	for pack in ["es1", "es2"]:
		if not Assets.has_pack(pack):
			continue
		var root := Node3D.new()
		add_child(root)
		WorldBuilder.build(root, 0, -1, pack)
		var w := WorldBuilder.load_world(0, pack)
		var env: Environment = (root.get_children().filter(func(n): return n is WorldEnvironment)[0] as WorldEnvironment).environment
		var hz: Dictionary = w.get("haze", {})
		var sun_v: Array = w.get("light", {}).get("vector_assumed_RzRyRx", [0, -1, 0])
		var want_sun := Vector3(float(sun_v[0]), float(sun_v[2]), -float(sun_v[1])).normalized()
		var got_sun := SceneLighting.make_3space_sun(sun_v)
		_expect(got_sun.is_equal_approx(want_sun), "%s world 0: sun %s" % [pack, got_sun])
		_expect(env.tonemap_mode == Environment.TONE_MAPPER_LINEAR and env.fog_mode == Environment.FOG_MODE_DEPTH
			and env.background_mode == Environment.BG_SKY and env.fog_sky_affect == 0.0, "%s: palette environment" % pack)
		if pack == "es1":
			var objs: Array = hz.get("object_thresholds", [])
			_expect(is_equal_approx(env.fog_depth_begin, float(objs[0]) * Assets.UNIT)
				and is_equal_approx(env.fog_depth_end, float(objs[-1]) * Assets.UNIT * WorldBuilder.FOG_END_FACTOR),
				"es1: haze from the object thresholds")
		else:
			_expect(is_equal_approx(env.fog_density, 1.0) and is_equal_approx(env.fog_depth_end,
				float(hz.get("fog_end_units", ES2WorldBuilder.DEFAULT_FOG_END_UNITS)) * Assets.UNIT), "es2: terrain haze")
		root.queue_free()
	_expect(Palette.make_texture_shader("es1:WORLD0") == Palette.UNHAZED_TEXTURE_SHADER,
		"es1 textured polys take no distance haze (world.md 4)")
	_expect(Palette.make_texture_shader("es2:WORLD0") == Palette.HAZED_TEXTURE_SHADER,
		"es2 textured polys are hazed (RMP haze rows, es2.md 3.3)")


# ------------------------------------------------------------------ campaign presentation

func _check_presentations() -> void:
	print("CampaignPresentation:")
	_expect(CampaignPresentation.of(null) == CampaignPresentation.DEFAULTS, "no campaign: the defaults")
	var ss: Script = load(Saga.PROVIDERS.starsiege)
	var seen := {}
	for c in [Campaign.start(0), CampaignES2.start(1), ss.start("human"), ss.start("cybrid")]:
		var p := CampaignPresentation.of(c)
		var label := "%s %s" % [Session.campaign_pack(c), str(c.get("variant")) if c.get("variant") != null else ""]
		_expect(p.keys().all(func(k): return str(p[k]) != ""), "%s: every page has its text" % label)
		_expect(not seen.has(p.victory_text), "%s: its own victory text" % label)
		seen[p.victory_text] = true
	_expect(CampaignPresentation.of(Campaign.start(0)).killed_prompt != CampaignPresentation.of(CampaignES2.start(1)).killed_prompt,
		"Earthsiege and Earthsiege 2 ask their own killed-in-action question")
	if Assets.has_pack("es1"):
		var lines: Array = Assets.load_json(Campaign.KILLED_DIALOG, "es1").strings
		_expect(str(CampaignPresentation.of(Campaign.start(0)).killed_prompt) == " ".join(PackedStringArray(lines.slice(1, lines.size() - 1))),
			"Earthsiege's killed page is the imported MENU1250 dialog (no button label)")
	if Assets.has_pack("starsiege"):
		var p := CampaignPresentation.of(ss.start("human"))
		_expect(str(p.killed_prompt) == CampaignPresentation.make_table_text("starsiege", "scripts/strings.json", "IDSTR_PLAYER_KILLED")
			and str(p.killed_prompt) != "", "Starsiege's killed page is its IDSTR_PLAYER_KILLED string")


# ------------------------------------------------------------------ Earthsiege 2 objective status

## es2.md 10.3: failed -> 6 safe / 10 enemies near; all required -> 9 / 10; otherwise 5 / 4.
func _check_es2_status() -> void:
	print("ES2 objective status:")
	var cases := [[true, false, true, 6], [true, false, false, 10], [true, true, true, 6], [false, true, true, 9],
		[false, true, false, 10], [false, false, true, 5], [false, false, false, 4]]
	for c in cases:
		var got := ES2Objectives._status_for(c[0], c[1], c[2])
		_expect(got == c[3], "failed %s complete %s safe %s -> %d (%d)" % [c[0], c[1], c[2], c[3], got])


# ------------------------------------------------------------------ mission end

## Every runtime ends through MissionRuntime.end_mission: once, with its own var 0 and debriefing text.
func _check_mission_end() -> void:
	print("Mission end:")
	var es1 := MissionRuntime.new()
	es1.m = {"texts": {"debriefings": ["first", "second"]}}
	es1.mission_vars.resize(MissionRuntimeBase.MISSION_VAR_COUNT)
	var ends := []
	es1.mission_over.connect(func(ok, code, text): ends.append([ok, code, text]))
	es1.end_mission(true, 2, "done")
	es1.end_mission(false, 6, "again")
	_expect(ends.size() == 1 and ends[0][2] == "done\nsecond" and es1.mission_vars[0] == 2,
		"Earthsiege: ends once, var 0 = debriefing code, its MSN debriefing follows (%s)" % [ends])
	_expect(MissionRuntimeES2.new().make_end_var(true, 9) == 1 and MissionRuntimeES2.new().make_end_var(false, 6) == 0,
		"Earthsiege 2: var 0 is the success flag")
	var ss := StarsiegeMissionRuntime.new()
	_expect(ss.make_debriefing_text(1, "why") == "why" and ss.make_end_var(true, 1) == 1, "Starsiege: script debriefing as given")
	var tr := Tribes1MissionRuntime.new()
	_expect(tr.make_debriefing_text(6, "Training failed.") == "Training failed.", "Tribes: the training summary")
	for n in [es1, ss, tr]:
		n.free()


# ------------------------------------------------------------------ rules clock

## The rules tick hands its timers the simulation time that passed, whatever the physics rate: over 20 s of
## physics steps the ticks add up to 20 s (a fixed 0.25 per tick lost time when a tick spans an extra step).
func _check_rules_clock() -> void:
	print("Rules clock:")
	for hz in [60.0, 50.0, 37.0, 13.0]:
		var rt := MissionRuntime.new()
		var total := 0.0
		var ticks := 0
		var steps := int(20.0 * hz)
		for i in steps:
			var dt := rt.make_rules_step(1.0 / hz, MissionRuntime.RULES_INTERVAL)
			if dt > 0.0:
				total += dt
				ticks += 1
		_expect(absf(total - float(steps) / hz) <= MissionRuntime.RULES_INTERVAL + 1.0 / hz,
			"%d Hz: %d ticks carry %.2f s of 20 s" % [int(hz), ticks, total])
		rt.free()



# ------------------------------------------------------------------ ruined structure collision

## A destroyed structure's collision follows its flattened ruin (it used to stay full height).
func _check_ruin_collision(battle: Node, pack: String) -> void:
	var st: Structure = null
	for n in get_tree().get_nodes_in_group("structures"):
		if n is Structure and n.alive and n.get("_collides") and _collision_top(n) > 1.0:
			st = n
			break
	if st == null:
		return
	var before := _collision_top(st)
	st.destroy()
	var after := _collision_top(st)
	_expect(after < before * 0.5, "%s: ruined %s collides %.1f m high (intact %.1f m)" % [pack, st.shape_id, after, before])


## Highest point of the structure's shape collision above its origin (metres).
func _collision_top(st: Node3D) -> float:
	var top := 0.0
	for col in st.find_children("*", "CollisionShape3D", false, false):
		if col.has_meta(Structure.SHAPE_COLLISION_META) and col.shape is ConcavePolygonShape3D:
			for v in (col.shape as ConcavePolygonShape3D).get_faces():
				top = maxf(top, v.y)
	return top


# ------------------------------------------------------------------ Battledrome turret sides

## A turret holds fire at its own side's Hercs (DOA side = owner, battledrome.md section 6).
func _check_bd_turret_sides() -> void:
	print("BD turret sides:")
	var turret := ArenaTurret.new()
	turret.side = 1
	_expect(not turret.is_hostile(_team_node(1)) and turret.is_hostile(_team_node(0)) and turret.is_hostile(_team_node(10)),
		"side 1 spares team 1, fires at team 0 and free-for-all pilots")
	_expect(turret.team == 1, "the turret reports its side as its team")
	turret.free()
	for n in _temp_nodes:
		n.free()
	_temp_nodes.clear()


func _team_node(team: int) -> Node:
	var n := Herc.new()
	n.team = team
	_temp_nodes.append(n)
	return n


# ------------------------------------------------------------------ leaving the battle area

## Earthsiege 1 / 2 missions end when the player stays outside the map (ES1 code 8, ES2 status 7 / 8); matches
## keep Tribes' damage rule; Tribes missions leave the area to their scripts.
func _check_area_rules() -> void:
	print("Area rules:")
	_expect(MissionKinds.make_area_rule({}) == BattleBounds.AREA_DAMAGE, "a match: warnings and damage")
	_expect(MissionKinds.make_area_rule({"pack": "es2"}) == BattleBounds.AREA_MISSION, "Earthsiege 2: the mission decides")
	_expect(MissionKinds.make_area_rule({"pack": "tribes", "runtime": "tribes"}) == BattleBounds.AREA_NONE, "Tribes: its scripts")
	_expect(MissionKinds.make_area_rule({"pack": "starsiege"}) == BattleBounds.AREA_DAMAGE, "Starsiege: damage rule")
	_expect(ES2Objectives.make_area_status(0.0) == 0 and ES2Objectives.make_area_status(10.0) == 7
		and ES2Objectives.make_area_status(110000.0 * Assets.UNIT + 1.0) == 8, "ES2 statuses 7 / 8 by distance outside")
	for b in [["B0_C0_0A", "es1:RAPTOR", "es1", MissionRuntime.CODE_LEFT_MAP], ["es2:C1_01", "es2:MONGOOSE", "es2", ES2Objectives.STATUS_OUTSIDE]]:
		if Assets.has_pack(str(b[2])):
			await _check_left_area(b)


func _check_left_area(b: Array) -> void:
	var battle: Node = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "respawn": false, "mission_name": b[0],
		"roster": {1: {"name": "Tester", "vehicle": b[1], "team": 0, "loadout": []}}}
	var result := {}
	battle.match_finished.connect(func(r): result.merge(r))
	get_tree().root.add_child(battle)
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	var area: Rect2 = battle.bounds.bounds.area
	var outside := Vector3(area.end.x + 20.0, 0.0, area.get_center().y)
	for i in int(12.0 * Engine.physics_ticks_per_second):
		var p: Herc = battle.player
		if p == null or not result.is_empty():
			break
		p.shield_front = p.shield_max
		p.shield_rear = p.shield_max
		for c in p.components:
			c.hp = c.max
		p.global_position = Vector3(outside.x, p.global_position.y, outside.z)
		p.velocity = Vector3.ZERO
		await get_tree().physics_frame
	_expect(not result.is_empty() and not bool(result.get("success", true)) and int(result.get("code", 0)) == int(b[3]),
		"%s: staying outside the map ends the mission (code %s)" % [b[0], result.get("code", "-")])
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


# ------------------------------------------------------------------ AI unsticking

## A Herc that drives but does not move (a building in its way) turns aside after BLOCKED_SECONDS, alternating
## sides, then heads for its goal again; one that moves is never turned.
func _check_ai_detour() -> void:
	print("AI detour:")
	var pilot := AIPilot.new()
	var h := Herc.new()
	pilot.herc = h
	h.throttle = 0.9
	var to := Vector3(0, 0, -100)
	var dt := 0.1
	var first := Vector3.ZERO
	for i in int(AIPilot.BLOCKED_SECONDS / dt) + 2:
		first = pilot.make_detour_heading(to, dt)
	_expect(not first.is_equal_approx(to.normalized()), "blocked for %.1f s: turns aside" % AIPilot.BLOCKED_SECONDS)
	for i in int(AIPilot.DETOUR_SECONDS / dt) + 1:
		pilot.make_detour_heading(to, dt)
	h.velocity = Vector3(0, 0, -5)
	_expect(pilot.make_detour_heading(to, dt).is_equal_approx(to.normalized()), "moving again: heads for the goal")
	h.velocity = Vector3.ZERO
	var second := Vector3.ZERO
	for i in int(AIPilot.BLOCKED_SECONDS / dt) + 2:
		second = pilot.make_detour_heading(to, dt)
	_expect(signf(second.x) == -signf(first.x), "the next detour takes the other side")
	pilot.free()
	h.free()


# ------------------------------------------------------------------ dynamic lights, mission outcome

## Transient lights share one budget and give it back when they leave the tree.
func _check_dynamic_lights() -> void:
	print("DynamicLights:")
	var made: Array[OmniLight3D] = []
	var before := DynamicLights.transient_count()
	for i in DynamicLights.MAX_TRANSIENT + 4:
		var l := DynamicLights.make_transient({"color": Color.RED, "range": 5.0, "energy": 2.0})
		if l != null:
			add_child(l)
			made.append(l)
	_expect(DynamicLights.transient_count() == DynamicLights.MAX_TRANSIENT, "the budget caps transient lights (%d)" % DynamicLights.transient_count())
	_expect(made[0].light_color == Color.RED and made[0].omni_range == 5.0 and not made[0].shadow_enabled, "built from the spec")
	for l in made:
		remove_child(l)
		l.free()
	_expect(DynamicLights.transient_count() == before, "freed lights return to the budget")


## One result shape and one headline rule for every game and for an abort.
func _check_mission_outcome() -> void:
	print("MissionOutcome:")
	var won := MissionOutcome.make_ended(true, 2, PackedInt32Array(), "done", false)
	var aborted := MissionOutcome.make_aborted(PackedInt32Array(), "Mission aborted.")
	_expect(MissionOutcome.make_headline(won) == "MISSION SUCCESSFUL" and MissionOutcome.make_headline(aborted) == "MISSION ABORTED"
		and MissionOutcome.make_headline(MissionOutcome.make_ended(false, 6, PackedInt32Array(), "", true)) == "MISSION FAILED",
		"headlines: successful / aborted / failed")
	_expect(won.keys() == aborted.keys().filter(func(k): return k != "salvage"), "one shape for ended and aborted missions")
	_expect(int(aborted.code) == BattleExit.ABORT_CODE, "BattleExit aborts with the shared code")


# ------------------------------------------------------------------ damage models

## Each game's vehicles take hits through their own model (EsDamageModel, BdDamageModel, the generic rest).
func _check_damage_models() -> void:
	print("Damage models:")
	if not (Assets.has_pack("es1") and Assets.has_pack("es2")):
		return
	var battle: Node = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "respawn": false, "mission_name": "B0_C0_0A",
		"roster": {1: {"name": "Tester", "vehicle": "es1:RAPTOR", "team": 0, "loadout": []}}}
	get_tree().root.add_child(battle)
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	var at := Transform3D(Basis(), battle.player.global_position + Vector3(60, 0, 0))
	var es1: Herc = battle.spawn_ai("es1:RAPTOR", 5, at, [], "es1 target", {})
	var es2: Herc = battle.spawn_ai("es2:OUTLAW", 5, at.translated(Vector3(30, 0, 0)), [], "es2 target", {})
	await get_tree().physics_frame
	_expect(es1.damage_model is EsDamageModel and es2.damage_model is EsDamageModel, "Earthsiege 1 / 2 Hercs: EsDamageModel")
	_check_es_pick(es1)
	_check_es_splash(es1)
	_check_blast(battle, es1)
	_check_turret_targeting(battle, es1)
	_check_ram_falloff(es1)
	_check_es_emp(es1, "es1:EMP", 2.344)
	_check_es_emp(es2, "es2:EMP", 2.93)
	if Assets.has_pack("bd"):
		var bd: Herc = battle.spawn_ai("bd:THOR", 5, at.translated(Vector3(-30, 0, 0)), [], "bd target", {})
		await get_tree().physics_frame
		_check_bd_shields(bd)
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


## The struck component is the one whose COL sphere is nearest the hit (0x9064).
func _check_es_pick(h: Herc) -> void:
	var points: Array = h.def.get("component_points", [])
	var ok := 0
	var tried := 0
	for i in h.components.size():
		if i < points.size() and not (points[i] as Array).is_empty() and bool(h.components[i].get("hittable", true)):
			tried += 1
			if h.damage_model.pick_component(h, h.make_component_position(i)) == i:
				ok += 1
	_expect(tried > 0 and ok == tried, "Earthsiege: a hit on a component's sphere strikes it (%d of %d)" % [ok, tried])


## Splash stays inside the unit: the struck component takes A - S (0x13a7c), nothing beyond the unit.
func _check_es_splash(h: Herc) -> void:
	var missile := Packs.weapon("es1:MLRS6")
	var i := _first_hittable(h)
	_reset_herc(h)
	h.shield_front = 0.0
	h.shield_rear = 0.0
	var before: float = h.components[i].hp
	var armor := 100.0
	DamageModel.apply_weapon_hit(h, DamageModel.make_hit(0.0, armor, null, h.make_component_position(i), missile))
	var took: float = before - float(h.components[i].hp)
	_expect(is_equal_approx(took, armor * (1.0 - float(missile.splash))), "Earthsiege missile: struck component takes A - S (%.1f)" % took)
	_expect(not DamageModel.splashes_nearby_units(missile) and DamageModel.splashes_nearby_units(Packs.weapon("starsiege:BLAS")),
		"Earthsiege splash stays in the struck unit; other games' splash reaches nearby units")


## An EMP switches both banks off for the game's shield-down time; no recharge meanwhile, no frozen controls.
func _check_es_emp(h: Herc, emp_id: String, seconds: float) -> void:
	_reset_herc(h)
	var emp := Packs.weapon(emp_id)
	Weapon.apply_effects(h, emp.get("effects", {}), null)
	_expect(h.shield_front == 0.0 and h.shield_rear == 0.0 and absf(h.shields_down_s - seconds) < 0.01
		and not h.has_meta("disabled_until"), "%s: shields off for %.2f s (%.3f), controls not frozen" % [emp_id, seconds, h.shields_down_s])
	var through := h.damage_model.make_shield_through(h, DamageModel.make_hit(500.0, 100.0, null, h.global_position))
	_expect(through == 1.0, "%s: while down a hit goes straight to the armour" % emp_id)
	h.shields_down_s = 0.0


## Battledrome classes: blaster leaks a quarter, canon an eighth, mines bypass, missiles burst on a strong shield.
func _check_bd_shields(h: Herc) -> void:
	_expect(h.damage_model is BdDamageModel, "Battledrome Hercs: BdDamageModel")
	var cases := [["BLASTER_1", 0.25], ["CANON_1", 0.125], ["LASER_1", 0.0]]
	for c in cases:
		_reset_herc(h)
		var w := {"name": str(c[0]).replace("_", " "), "kind": "beam"}
		var t: float = h.damage_model.make_shield_through(h, DamageModel.make_hit(10.0, 10.0, null, h.global_position, w))
		_expect(is_equal_approx(t, float(c[1])), "%s against a full shield lets %.3f through (%.3f)" % [c[0], c[1], t])
	_reset_herc(h)
	_expect(h.damage_model.make_shield_through(h, DamageModel.make_hit(0.0, 600.0, null, h.global_position, {"kind": "mine"})) == 1.0,
		"mines bypass the shield")
	_expect(h.damage_model.make_shield_through(h, DamageModel.make_hit(100.0, 200.0, null, h.global_position, {"kind": "missile"})) == 0.5,
		"a missile bursts on a shield above 200 at half damage")


func _reset_herc(h: Herc) -> void:
	h.shield_front = h.shield_max * 0.5
	h.shield_rear = h.shield_max * 0.5
	h.shields_down_s = 0.0
	for c in h.components:
		c.hp = c.max


func _first_hittable(h: Herc) -> int:
	var points: Array = h.def.get("component_points", [])
	for i in h.components.size():
		if i < points.size() and not (points[i] as Array).is_empty() and bool(h.components[i].get("hittable", true)):
			return i
	return 0


## One radius rule for every game: linear falloff, units by centre distance, components by their spheres (0x13a7c).
func _check_blast(battle: Node, h: Herc) -> void:
	_expect(Blast.make_falloff(10.0, 0.0) == 1.0 and Blast.make_falloff(10.0, 5.0) == 0.5 and Blast.make_falloff(10.0, 10.0) == 0.0,
		"Blast: linear falloff from the centre to the edge")
	var hits := Blast.make_unit_hits(get_tree(), h.global_position, 5.0)
	_expect(hits.any(func(x): return x[0] == h and is_equal_approx(x[1], 1.0)) and not hits.any(func(x): return x[0] == battle.player),
		"Blast: units within the radius by their centre, full share at the centre")
	_reset_herc(h)
	var struck := _first_hittable(h)
	var comps := Blast.make_component_hits(h, h.make_component_position(struck), {"amount": 100.0, "radius": 50.0, "chance": 1.0,
		"skip_index": struck})
	_expect(not comps.is_empty() and not comps.any(func(c): return c[0] == struck) and comps.all(func(c): return c[1] <= 100.0),
		"Blast: component hits skip the struck one and fall off with distance (%d components)" % comps.size())
	_expect(Blast.make_component_hits(h, h.global_position, {"amount": 100.0, "radius": 50.0, "chance": 0.0}).is_empty(),
		"Blast: a component is reached only with the blast's chance")


# ------------------------------------------------------------------ turret targeting

## Every game's turret takes the nearest targetable hostile in range its own rules accept (TargetSelector).
func _check_turret_targeting(_battle: Node, near: Herc) -> void:
	var ctx := {"from": near.global_position + Vector3(5, 0, 0), "team": -1}
	var all := TargetProfile.make_turret().with_range(20.0)
	all.hostile_rule = func(_a: int, _b: int) -> bool: return true
	_expect(TargetSelector.pick(get_tree(), all, ctx) == near, "TargetSelector: the nearest unit in range")
	var not_near := TargetProfile.make_turret().with_range(20.0)
	not_near.hostile_rule = func(_a: int, b: int) -> bool: return b != int(near.team)
	_expect(TargetSelector.pick(get_tree(), not_near, ctx) != near, "TargetSelector: the game's hostility rule decides")
	ctx.accepts = func(_v: Node3D, _p: Vector3) -> bool: return false
	_expect(TargetSelector.pick(get_tree(), all, ctx) == null, "TargetSelector: arc / sight tests veto")
	near.set_meta("dormant", true)
	_expect(not TargetSelector.is_live(near), "TargetSelector: dormant units are never targets")
	near.remove_meta("dormant")


# ------------------------------------------------------------------ briefing presentation

## Each campaign presents its own briefing: Earthsiege 2's clips (VSHELL clip table, imported .ogv), Earthsiege's
## talking heads (the shell's commanders and debriefing officers, ShellTalkPanel).
func _check_briefing_presentation() -> void:
	print("Briefing presentation:")
	if Assets.has_pack("es2"):
		var clips = Assets.load_json(CampaignPresentation.CLIPS_FILE, "es2")
		_expect(clips is Dictionary and (clips.clips as Array).size() == 86, "es2: the shell's 86-clip table imported")
		var c2 := CampaignES2.start(1)
		var m := c2.load_current()
		var brief := CampaignPresentation.make_movies(c2, CampaignPresentation.MOMENT_BRIEFING, {"mission": m})
		_expect(brief.size() >= 3 and str(brief[0]).ends_with("c1.ogv") and str(brief[1]).ends_with("alph_th.ogv"),
			"es2 C1_01: campaign intro, theater clip, then the mission's own briefing clip (%s)" % [brief.map(func(f): return str(f).get_file())])
		_expect(CampaignPresentation.make_movies(c2, CampaignPresentation.MOMENT_KILLED).map(func(f): return str(f).get_file()) == ["death.ogv"],
			"es2: a killed pilot sees the death clip")
		_expect(CampaignPresentation.make_movies(c2, CampaignPresentation.MOMENT_VICTORY).size() == 2, "es2: victory and credits")
		var deb := CampaignPresentation.make_movies(c2, CampaignPresentation.MOMENT_DEBRIEF,
			{"result": {"debrief_clip": int(m.texts.get("debrief_clip", -1))}})
		_expect(deb.size() == 1, "es2: the debriefing clip its record names (%s)" % [deb.map(func(f): return str(f).get_file())])
	if Assets.has_pack("es1"):
		var c1 := Campaign.start(0)
		var talks := CampaignPresentation.make_talks(c1, CampaignPresentation.MOMENT_BRIEFING)
		_expect(talks.size() == 1 and talks[0].speaker == "C0" and TalkingHead.make_subtitle("C0", int(talks[0].line)) != "",
			"es1: the campaign's commander briefs the mission (%s)" % [talks])
		var won := CampaignPresentation.make_talks(c1, CampaignPresentation.MOMENT_DEBRIEF, {"result": {"success": true}})
		_expect(won.size() == 1 and won[0].speaker == "D0" and int(won[0].line) == ShellMissions.DEBRIEF_SUCCESS_LINE,
			"es1: the debriefing officer gives the verdict")
		var holder := Control.new()
		add_child(holder)
		var player := AudioStreamPlayer.new()
		holder.add_child(player)
		var files: Dictionary = ShellData.meta().get("snc_files", {}).get("C0", {})
		var speech := TalkingHead._speech_file(files, int(talks[0].line))
		var head := TalkingHead.new(TTMScene.new(), player, holder, func() -> bool: return true)
		var length := head._start_voice(speech, -1.0)
		_expect(speech != "" and player.stream != null and length > 0.0,
			"es1: the commander's speech clip loads through the shared voice naming (%s, %.1f s)" % [speech, length])
		player.stop()
		var panel := ShellTalkPanel.add_to(holder, talks)
		await get_tree().process_frame
		await get_tree().process_frame
		_expect(panel != null and panel._scene != null and not panel._scene.threads.is_empty() and panel.subtitle.text != "",
			"es1: the launcher panel shows the lip-synced head with its subtitle")
		panel._skip = true
		for i in 10:
			await get_tree().process_frame
		holder.queue_free()


# ------------------------------------------------------------------ palette point lights

## A 3Space explosion light (fx light block with full_range) joins the palette shaders' point lights; its I and
## cutoff follow its energy curve (weapon_fx.md 2.1).
func _check_palette_lights() -> void:
	print("Palette point lights:")
	var l := DynamicLights.make_transient({"color": Color.WHITE, "range": 31.0, "energy": PaletteLights.ENERGY_AT_PEAK * 0.5})
	PaletteLights.adopt(l, {"full_range": 7.78, "cutoff": 197.6})
	add_child(l)
	var row := PaletteLights.make_light_row(l)
	_expect(l.is_in_group(PaletteLights.GROUP) and is_equal_approx(float(row[2]), 0.5) and is_equal_approx(float(row[1]), 98.8)
		and is_equal_approx(float(row[3]), 7.78), "an explosion light at half I: cutoff halved, full range kept (%s)" % [row])
	var plain := DynamicLights.make_transient({"color": Color.RED, "range": 5.0, "energy": 1.0})
	PaletteLights.adopt(plain, {"color": [1, 0, 0]})
	_expect(not plain.is_in_group(PaletteLights.GROUP), "a lit-material light (no 3Space block) stays out of the palette shaders")
	l.queue_free()
	plain.free()


## A destroyed Battledrome turret leaves its wreck (arena turret_shapes "destroyed", TURHLK), not nothing.
func _check_bd_turret_wreck() -> void:
	if not Assets.has_pack("bd") or Assets.shape("bd:TURHLK").is_empty():
		return
	var holder := Node3D.new()
	add_child(holder)
	var t := ArenaTurret.create(holder, "bd:TURRET", Transform3D(), Packs.default_palette("bd"), 1.0)
	t.wreck_shape_id = "bd:TURHLK"
	t.apply_destroyed()
	_expect(not t.alive and t.shape.visible and t.shape.shape == Assets.shape("bd:TURHLK"), "BD: a destroyed turret shows its TURHLK wreck")
	holder.queue_free()


## Battledrome start pads alternate sides, so the first two pilots start on opposite sides.
func _check_bd_pad_sides() -> void:
	var a := Transform3D(Basis(), Vector3(1, 0, 0))
	var b := Transform3D(Basis(), Vector3(2, 0, 0))
	var c := Transform3D(Basis(), Vector3(3, 0, 0))
	var out := ArenaBuilder.interleave_sides({1: [b], 0: [a, c]})
	_expect(Array(out) == [a, b, c], "BD: start pads alternate side 0, side 1, side 0")


## Each game's bodies fall with the gravity its units.json names (Tribes 20 m/s^2), else the Earth value.
func _check_world_gravity() -> void:
	if Assets.has_pack("tribes"):
		_expect(WorldPhysics.gravity_of_pack("tribes") == 20.0, "Tribes vehicles fall at 20 m/s^2 (contGravity)")
	if Assets.has_pack("es1"):
		_expect(WorldPhysics.gravity_of_pack("es1") == WorldPhysics.DEFAULT_GRAVITY, "Earthsiege falls at the Earth value")


## A ram (0x13a7c over 1200 units) hurts the components near the contact point, none beyond the reach.
func _check_ram_falloff(h: Herc) -> void:
	_reset_herc(h)
	var reach := CollisionDamage.RAM_REACH_UNITS * Assets.UNIT
	var contact := h.make_component_position(_first_hittable(h))
	h.apply_collision_damage(500.0, null, contact)
	var far_hurt := 0
	var near_hurt := 0
	for i in h.components.size():
		var c: Dictionary = h.components[i]
		if float(c.hp) < float(c.max):
			if contact.distance_to(h.make_component_position(i)) >= reach:
				far_hurt += 1
			else:
				near_hurt += 1
	_expect(far_hurt == 0 and near_hurt > 0, "Ramming: components near the contact take it, none beyond %.1f m (%d near)" % [reach, near_hurt])
	_reset_herc(h)

extends Node
## Game modes (docs/formats/game_modes.md):
##   1 every map lists its modes from its own data (maps/_index.json "modes" + remake modes), Battledrome arenas
##     and Earthsiege worlds included; the lobby entries are well formed
##   2 Earthsiege 1 / 2 arena maps: >= 24 free-for-all starts and >= 2 team areas, inside the bounds with a margin,
##     on the ground, spaced apart
##   3 each mode's rules: CTF capture (own flag home), return, drop timer; C&H hold scoring; D&D destroy + win; F&R
##     retrieve; Hunters bank (triangular) + drops; Rabbit hold; Bounty target / bystander; Siege halftime swap and
##     faster capture wins; Football touchdown; deathmatch kill limit; duel victory terms; time limit; state sync
##   4 a CTF battle (Tribes 2 Katabatic): the player's soldier takes the enemy flag and captures it; the objectives
##     panel shows the mode; Herc starts do not face a wall
##   5 the originals' finer rules: defence bonuses, CTF stalemate, C&H hold bonus, Hunters hoard / camping,
##     Football fumble / penalty box
##   6 the AI plays the objectives: GameModeAI's plans per mode; bots in a Katabatic CTF battle go for the flag;
##     the WAR defenders are dropped and come back
##   godot --headless --audio-driver Dummy --path game res://tests/game_modes_check.tscn [-- --shots=<dir>]
## --shots (needs a window): modes_*.png of CTF, Capture and Hold, Hunters and an Earthsiege team map.

const ES_PACKS := ["es1", "es2"]
const MIN_FFA := 24
const FFA_SPACING_M := 55.0
const EDGE_MARGIN_M := 300.0
const GROUND_TOLERANCE_M := 3.0
const SETTLE_FRAMES := 30
const BATTLE_SCENE := "res://games/es1/battle.tscn"

var _failures := 0
var _shots := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	await get_tree().process_frame
	_check_map_modes()
	_check_es_spawns()
	_check_ctf()
	_check_capture_hold()
	_check_defend_destroy()
	_check_find_retrieve()
	_check_hunters()
	_check_rabbit()
	_check_bounty()
	_check_siege()
	_check_football()
	_check_deathmatch_and_duel()
	_check_state_sync()
	_check_rule_details()
	_check_ai_plans()
	await _check_ctf_battle()
	await _check_spawn_facing()
	await _check_bots_play_ctf()
	await _check_war_defenders()
	await _check_switch_resources()
	if _shots != "":
		await _take_shots()
	print("game_modes_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


static func _player(id: int, key: String, team: int, pos := Vector3.ZERO) -> Dictionary:
	return {"id": id, "key": key, "team": team, "alive": true, "pos": pos, "can_touch": true, "vehicle": false,
		"integrity": 1.0}


static func _object(id: int, kind: String, team: int, pos: Vector3, extra := {}) -> Dictionary:
	var d := {"id": id, "kind": kind, "team": team, "pos": [pos.x, pos.y, pos.z]}
	d.merge(extra)
	return d


func _make(mode: String, objects: Array, teams: Dictionary, settings := {}) -> GameModeRules:
	var s := GameModes.make_rules_settings(mode, {})
	s.merge(settings, true)
	var r := GameModes.make_rules(mode, s)
	r.setup(objects, teams)
	return r


# ------------------------------------------------------------------ 1 maps

func _check_map_modes() -> void:
	print("map modes")
	var maps := MapBuilder.list_maps()
	_expect(not maps.is_empty(), "pack maps listed (%d)" % maps.size())
	var bad := []
	for m in maps:
		var ids := GameModes.make_mode_ids_for_map(m)
		if m.has("remake_modes"):   # a map made for certain modes only (Varuna's Fall: extraction)
			if ids != (m.remake_modes as Array):
				bad.append(m.id)
			continue
		if ids.is_empty() or ids[0] != GameModes.DEFAULT or not m.get("modes", []).all(func(x) -> bool: return ids.has(x)):
			bad.append(m.id)
	_expect(bad.is_empty(), "every map offers deathmatch first plus its own modes %s" % [bad.slice(0, 5)])
	var expect := {"tribes2:Katabatic": ["ctf"], "tribes:Raindance": ["ctf"], "tribes:CrissCross": ["capture_hold"],
		"tribes:Siege": ["defend_destroy"], "tribes:FogOfWar": ["find_retrieve"], "tribes:FourWayDance": ["ctf"],
		"tribes2:Abominable": ["capture_hold"], "tribes2:Rasp": ["hunters", "bounty"], "tribes2:Escalade": ["rabbit", "team_hunters"],
		"tribes2:Alcatraz": ["siege"], "starsiege:Starsiege_Football": ["football"], "starsiege:WAR_Martian_Standoff": ["war"],
		"starsiege:DM_Impact": ["team_deathmatch"], "starsiege:CTF_Titanic_Assault": ["ctf"],
		"es1:desert_day": ["team_deathmatch", "extraction"], "es2:zone_123": ["team_deathmatch"]}
	for id in expect:
		var row := maps.filter(func(m: Dictionary) -> bool: return m.id == id)
		if row.is_empty():
			print("  skip %s (pack not installed)" % id)
			continue
		var ids := GameModes.make_mode_ids_for_map(row[0])
		_expect(expect[id].all(func(x) -> bool: return ids.has(x)), "%s offers %s (%s)" % [id, expect[id], ids])
	var small := maps.filter(func(m: Dictionary) -> bool: return m.id == "tribes2:AgentsOfFortune")
	if not small.is_empty():
		_expect(not GameModes.make_mode_ids_for_map(small[0]).has("extraction"), "extraction only on large maps")
	_check_lobby_entries()


func _check_lobby_entries() -> void:
	var arena := GameModes.make_mode_ids_for_map({"name": "Battledrome arena - MED", "config": {"arena": {"size": 3}}})
	_expect(arena.has("duel") and arena.has("deathmatch"), "Battledrome arenas offer the duel (%s)" % [arena])
	var world := GameModes.make_mode_ids_for_map({"name": "Desert - day", "config": {"world": 0, "zone": 0}})
	_expect(world.has("extraction") and world.has("team_deathmatch"), "Earthsiege worlds offer the remake modes")
	var picker_ok := true
	for e in MapPicker.make_entries():
		var entries := GameModes.make_modes_for_map(e)
		for m in entries:
			picker_ok = picker_ok and m.has_all(["id", "label", "team_based", "min_teams", "max_teams", "description"])
		picker_ok = picker_ok and not entries.is_empty()
	_expect(picker_ok, "every MapPicker entry gets lobby mode entries {id, label, team_based, min/max teams, description}")
	var ctf := GameModes.make_entry("ctf", 4)
	_expect(ctf.team_based and ctf.min_teams == 2 and ctf.max_teams == 4, "CTF entry: team based, 2..4 teams")
	var keys := GameModes.make_config_keys("capture_hold")
	_expect(keys.get("game_mode") == "capture_hold" and keys.mode == "vs" and keys.teams and keys.respawn,
		"config keys of a team mode: game_mode, versus, teams, respawn")
	var config := {"game_mode": "dm", "mode": "skirmish"}
	GameModes.apply_to_config(config)
	_expect(config.game_mode == "deathmatch" and config.frag_limit == GameModes.NO_FRAG_LIMIT and GameModes.is_free_for_all(config),
		"aliases resolve; the director's modes switch off BattleRules' kill limit")


# ------------------------------------------------------------------ 2 Earthsiege spawns

func _check_es_spawns() -> void:
	print("Earthsiege arena spawns")
	for pack in ES_PACKS:
		if not Assets.has_pack(pack):
			print("  skip %s (not installed)" % pack)
			continue
		var idx = Assets.load_json("maps/_index.json", pack)
		_expect(idx is Array and not idx.is_empty(), "%s arena maps exported" % pack)
		if not idx is Array:
			continue
		var bad := []
		for row in idx:
			var problem := _make_spawn_problem(MapBuilder.load_map("%s:%s" % [pack, row.id]))
			if problem != "":
				bad.append("%s: %s" % [row.id, problem])
		_expect(bad.is_empty(), "%s: %d maps, each >= %d free-for-all starts and >= 2 team areas, inside, on the ground, spaced %s" % [
			pack, idx.size(), MIN_FFA, bad.slice(0, 3)])
		_expect(MapTeams.make_team_count({"map": "%s:%s" % [pack, idx[0].id]}) >= 2, "%s maps count their team areas" % pack)


func _make_spawn_problem(m: Dictionary) -> String:
	var spawns: Array = m.get("spawns", []).filter(func(s) -> bool: return s.kind == "herc")
	var ffa := spawns.filter(func(s) -> bool: return int(s.team) < 0)
	var teams := {}
	for s in spawns:
		if int(s.team) >= 0:
			teams[int(s.team)] = true
	if ffa.size() < MIN_FFA or teams.size() < 2:
		return "ffa %d teams %d" % [ffa.size(), teams.size()]
	var b: Dictionary = m.bounds
	var heights := _load_es2_heights(m)
	for s in spawns:
		var p: Array = s.pos
		if p[0] < b.min[0] + EDGE_MARGIN_M or p[0] > b.max[0] - EDGE_MARGIN_M or p[2] < b.min[1] + EDGE_MARGIN_M or p[2] > b.max[1] - EDGE_MARGIN_M:
			return "start %s near the edge" % [p]
		if not heights.is_empty() and absf(float(p[1]) - _sample(heights, p[0], p[2])) > GROUND_TOLERANCE_M:
			return "start %s off the ground" % [p]
	for i in ffa.size():
		for j in range(i + 1, ffa.size()):
			var a: Array = ffa[i].pos
			var c: Array = ffa[j].pos
			if Vector2(a[0], a[2]).distance_to(Vector2(c[0], c[2])) < FFA_SPACING_M:
				return "free-for-all starts closer than %d m" % FFA_SPACING_M
	return ""


func _load_es2_heights(m: Dictionary) -> Dictionary:
	var world: Dictionary = m.get("world", {})
	if str(world.get("pack", "")) != "es2":
		return {}
	var t = Assets.load_json("terrain/%d/terrain.json" % int(world.zone), "es2")
	var bytes := FileAccess.get_file_as_bytes(Assets.path("terrain/%d/heights.r32" % int(world.zone), "es2"))
	return {"t": t, "h": bytes.to_float32_array()}


## Bilinear height of the zone grid at engine x / z (rows = +z).
static func _sample(d: Dictionary, x: float, z: float) -> float:
	var t: Dictionary = d.t
	var cols := int(t.size[0])
	var fx := (x - float(t.origin[0])) / float(t.square)
	var fz := (z - float(t.origin[1])) / float(t.square)
	var cx := clampi(int(fx), 0, cols - 2)
	var cz := clampi(int(fz), 0, int(t.size[1]) - 2)
	var ax := clampf(fx - cx, 0.0, 1.0)
	var az := clampf(fz - cz, 0.0, 1.0)
	var top := lerpf(d.h[cz * cols + cx], d.h[cz * cols + cx + 1], ax)
	var bottom := lerpf(d.h[(cz + 1) * cols + cx], d.h[(cz + 1) * cols + cx + 1], ax)
	return lerpf(top, bottom, az)


# ------------------------------------------------------------------ 3 rules

func _check_ctf() -> void:
	print("CTF")
	var red_home := Vector3(0, 0, 0)
	var blue_home := Vector3(100, 0, 0)
	var r := _make("ctf", [_object(1, "flag", 0, red_home), _object(2, "flag", 1, blue_home)], {0: "Red", 1: "Blue"},
		{"score_per_team_flag_cap": 1, "score_per_player_flag_cap": 3, "flag_return_s": 45, "score_limit": 2})
	var red := _player(10, "Ann", 0, blue_home)
	var blue := _player(20, "Bob", 1, red_home)
	r.apply_touch(red, 2)
	_expect(r.objects[2].state == ModeObject.CARRIED and r.objects[2].carrier == 10, "touching the enemy flag takes it")
	r.apply_touch(blue, 1)
	_expect(r.objects[1].state == ModeObject.CARRIED, "both flags taken")
	red.pos = red_home
	r.apply_touch(red, 1)
	_expect(r.score.team_score(0) == 0.0, "no capture while the own flag is away")
	r.apply_kill(blue, red)
	_expect(r.objects[1].state == ModeObject.DROPPED and r.objects[1].timer == 45.0, "a killed carrier drops the flag (45 s timer)")
	r.apply_touch(red, 1)
	_expect(r.objects[1].state == ModeObject.HOME and r.score.player_score("Ann") >= 1.0, "touching the own dropped flag returns it")
	r.apply_touch(red, 1)
	_expect(r.score.team_score(0) == 1.0 and r.score.player_score("Ann") >= 4.0 and r.objects[2].state == ModeObject.HOME,
		"capture: team +1, carrier +3, the enemy flag goes home")
	r.apply_touch(_player(10, "Ann", 0, blue_home), 2)
	r.apply_kill(_player(10, "Ann", 0, Vector3(50, 0, 0)), {})
	r.apply_tick(46.0, [])
	_expect(r.objects[2].state == ModeObject.HOME, "a dropped flag returns home after flag_return_s")
	r.apply_touch(_player(10, "Ann", 0, blue_home), 2)
	r.apply_touch(_player(10, "Ann", 0, red_home), 1)
	_expect(r.over and r.winner == "Red", "first to the score limit wins (%s)" % r.result_text)


func _check_capture_hold() -> void:
	print("Capture and Hold")
	var r := _make("capture_hold", [_object(1, "switch", -1, Vector3.ZERO), _object(2, "switch", -1, Vector3(50, 0, 0))],
		{0: "Red", 1: "Blue"}, {"capture_delay_s": 12, "hold_interval_s": 0.5, "hold_points": 1, "team_capture_points": 1,
			"score_per_capture": 1, "score_limit_per_switch": 1200})
	r.apply_touch(_player(1, "Ann", 0), 1)
	_expect(r.objects[1].owner_team == 0 and r.score.team_score(0) == 0.0, "touching a switch claims it, not counted yet")
	r.apply_tick(12.0, [])
	_expect(r.score.team_score(0) == 1.0 and r.score.player_score("Ann") == 1.0, "after the capture delay: team +1, claimer +1")
	r.apply_tick(5.0, [])
	_expect(r.score.team_score(0) == 11.0, "holding scores every hold interval (%d)" % r.score.team_score(0))
	r.apply_touch(_player(2, "Bob", 1), 1)
	r.apply_tick(1.0, [])
	_expect(r.score.team_score(0) == 11.0 and r.objects[1].owner_team == 1, "a claim stops the old holder's points")
	var t1 := _make("capture_hold", [_object(1, "switch", -1, Vector3.ZERO, {"points_per_minute": 12})], {0: "A", 1: "B"},
		{"capture_delay_s": 0, "hold_interval_s": 5, "score_limit": 3})
	t1.apply_touch(_player(1, "Ann", 0), 1)
	t1.apply_tick(15.0, [])
	_expect(t1.over and t1.winner == "A", "Tribes 1: deltaTeamScore per minute, score limit wins (%d)" % t1.score.team_score(0))


func _check_defend_destroy() -> void:
	print("Defend and Destroy / WAR")
	var r := _make("defend_destroy", [_object(1, "objective", 0, Vector3.ZERO, {"value": 3}),
		_object(2, "objective", 1, Vector3(9, 0, 0), {"value": 5}), _object(3, "objective", 1, Vector3(19, 0, 0), {"value": 1})],
		{0: "Red", 1: "Blue"})
	r.apply_destroyed(2, _player(1, "Ann", 0))
	_expect(r.score.team_score(0) == 5.0 and r.score.player_score("Ann") == 5.0, "destroying an enemy objective scores its value")
	r.apply_destroyed(1, _player(2, "Bob", 0))
	_expect(r.score.team_score(1) == 3.0, "destroying your own objective gives the points to the enemy")
	_expect(r.over, "all objectives of a team gone ends the match (%s)" % r.result_text)
	var war := _make("war", [_object(1, "structure", 0, Vector3.ZERO), _object(2, "structure", 1, Vector3(1, 0, 0)),
		_object(3, "structure", 1, Vector3(2, 0, 0)), _object(4, "structure", 1, Vector3(3, 0, 0))], {0: "Red", 1: "Yellow"},
		{"structures_to_win": 2})
	war.apply_destroyed(2, _player(1, "Ann", 0))
	_expect(not war.over, "WAR: one structure is not enough")
	war.apply_destroyed(3, _player(1, "Ann", 0))
	_expect(war.over and war.winner == "Red", "WAR: structures_to_win destroyed wins")


func _check_find_retrieve() -> void:
	print("Find and Retrieve")
	var r := _make("find_retrieve", [_object(1, "flag", -1, Vector3.ZERO, {"value": 3}), _object(2, "flag_stand", 0, Vector3(50, 0, 0)),
		_object(3, "flag_stand", 1, Vector3(-50, 0, 0))], {0: "Red", 1: "Blue"}, {"score_limit": 6})
	var ann := _player(1, "Ann", 0)
	r.apply_touch(ann, 1)
	ann.pos = Vector3(50, 0, 0)
	r.apply_touch(ann, 2)
	_expect(r.objects[1].state == ModeObject.PLACED and r.score.team_score(0) == 3.0, "a flag placed on the own stand scores its value")
	r.apply_touch(_player(2, "Bob", 1), 1)
	_expect(r.score.team_score(0) == 0.0 and r.objects[1].state == ModeObject.CARRIED, "taking it off the stand removes the points")
	r.apply_kill(_player(2, "Bob", 1, Vector3(5, 0, 0)), ann)
	r.apply_tick(46.0, [])
	_expect(r.objects[1].state == ModeObject.HOME, "a dropped flag returns to where it started")


func _check_hunters() -> void:
	print("Hunters")
	_expect(HuntersRules.make_bank_points(5) == 15.0 and HuntersRules.make_bank_points(1) == 1.0, "banking n flags = n(n+1)/2")
	var values := HuntersRules.make_drop_values(40)
	_expect(values.reduce(func(a, b): return a + b, 0) == 40 and values.slice(0, 10) == [1, 1, 1, 1, 1, 2, 2, 2, 2, 2],
		"drops: 5 of 1, 5 of 2, then larger (%s)" % [values])
	var r: HuntersRules = _make("hunters", [_object(1, "nexus", -1, Vector3.ZERO)], {}, {"flag_life_s": 120})
	var ann := _player(1, "Ann", 0, Vector3(10, 0, 0))
	var bob := _player(2, "Bob", 1, Vector3(20, 0, 0))
	r.apply_kill(bob, ann)
	var dropped := r.objects_of(ModeObject.KIND_HUNTER_FLAG)
	_expect(dropped.size() == 1 and dropped[0].value == 1.0, "a kill drops the victim's own flag")
	r.apply_touch(ann, dropped[0].id)
	r.carried["Ann"] = int(r.carried.get("Ann", 0)) + 3
	r.apply_touch(ann, 1)
	_expect(r.score.player_score("Ann") == 1.0 + 10.0 and int(r.carried.Ann) == 0, "banking 4 flags at the Nexus scores 10 (+1 kill)")
	r.carried["Bob"] = 6
	r.apply_kill(_player(2, "Bob", 1, Vector3(20, 0, 0)), ann)
	var total: int = r.objects_of(ModeObject.KIND_HUNTER_FLAG).reduce(func(a, o): return a + int(o.value), 0)
	_expect(total == 7, "a carrier drops everything he carried plus his own (%d)" % total)
	r.apply_tick(121.0, [])
	_expect(r.objects_of(ModeObject.KIND_HUNTER_FLAG).is_empty(), "dropped flags fade after flag_life_s")
	var team: HuntersRules = _make("team_hunters", [_object(1, "nexus", -1, Vector3.ZERO)], {0: "Storm", 1: "Inferno"})
	team.carried["Ann"] = 2
	team.apply_touch(_player(1, "Ann", 0), 1)
	_expect(team.score.team_score(0) == 3.0, "Team Hunters banks for the team")


func _check_rabbit() -> void:
	print("Rabbit")
	var r: RabbitRules = _make("rabbit", [_object(1, "flag", -1, Vector3.ZERO)], {}, {"hold_interval_s": 15, "hold_points": 1, "flag_return_s": 45})
	var ann := _player(1, "Ann", 0)
	var bob := _player(2, "Bob", 1, Vector3(5, 0, 0))
	r.apply_touch(ann, 1)
	r.apply_tick(31.0, [ann, bob])
	_expect(r.make_rabbit_key() == "Ann" and r.score.player_score("Ann") == 3.0, "the rabbit scores a grab and 1 per 15 s held")
	r.apply_kill(ann, bob)
	_expect(r.objects[1].state == ModeObject.DROPPED and r.score.player_score("Bob") == 1.0, "killing the rabbit drops the flag")
	r.apply_touch(bob, 1)
	_expect(r.make_rabbit_key() == "Bob", "the hunter becomes the rabbit")


func _check_bounty() -> void:
	print("Bounty")
	var r: BountyRules = _make("bounty", [], {}, {"seed": 7})
	var ps := [_player(1, "Ann", 0), _player(2, "Bob", 1), _player(3, "Cat", 2)]
	r.apply_tick(0.1, ps)
	var target: String = str(r.targets.get("Ann", ""))
	_expect(target != "" and target != "Ann", "everybody gets a target (%s)" % target)
	var victim: Dictionary = ps.filter(func(p) -> bool: return p.key == target)[0]
	r.apply_kill(victim, ps[0])
	_expect(r.score.player_score("Ann") == 1.0 and r.eliminated.Ann.has(target), "killing the target scores and eliminates him")
	r.apply_tick(0.1, ps)
	var other: Dictionary = ps.filter(func(p) -> bool: return p.key != "Ann" and p.key != r.targets.get("Ann", ""))[0]
	if other.key != r.targets.get(other.key, "") and r.targets.get(other.key, "") != "Ann":
		r.apply_kill(other, ps[0])
		_expect(r.score.player_score("Ann") == 0.0, "killing a bystander costs a point")
	var done: BountyRules = _make("bounty", [], {}, {"seed": 1})
	done.apply_tick(0.1, [_player(1, "Ann", 0), _player(2, "Bob", 1)])
	done.apply_kill(_player(2, "Bob", 1), _player(1, "Ann", 0))
	done.apply_tick(0.1, [_player(1, "Ann", 0), _player(2, "Bob", 1)])
	_expect(done.over and done.winner == "Ann" and done.score.player_score("Ann") >= 6.0, "eliminating every target wins with the bonus")


func _check_siege() -> void:
	print("Siege")
	var r: SiegeRules = _make("siege", [_object(1, "switch", 1, Vector3.ZERO)], {0: "Storm", 1: "Inferno"}, {"first_offense": 0, "round_time_s": 600})
	r.apply_touch(_player(2, "Bob", 1), 1)
	_expect(r.half == SiegeRules.FIRST_HALF, "defenders cannot capture")
	r.apply_tick(100.0, [])
	r.apply_touch(_player(1, "Ann", 0), 1)
	_expect(r.half == SiegeRules.SECOND_HALF and r.offense == 1 and r.objects[1].owner_team == 0, "a capture ends the half; the sides swap")
	_expect(r.take_requests().any(func(q) -> bool: return q.kind == "respawn_all"), "halftime respawns everybody")
	_expect(is_equal_approx(r.make_half_limit(), 100.0), "the second half lasts as long as the first capture")
	r.apply_tick(101.0, [])
	_expect(r.over and r.winner == "Storm", "the faster capture wins (%s)" % r.result_text)


func _check_football() -> void:
	print("Football")
	var goals := [_object(1, "goal", 0, Vector3(0, 0, -500), {"half_extents": [100, 10, 15]}),
		_object(2, "goal", 1, Vector3(0, 0, 500), {"half_extents": [100, 10, 15]})]
	var r: FootballRules = _make("football", goals, {0: "Red", 1: "Blue"}, {"score_per_goal": 7, "score_per_player_goal": 7, "goals_to_win": 6})
	var red := _player(1, "Ann", 0, Vector3.ZERO)
	var blue := _player(2, "Bob", 1, Vector3(0, 0, 10))
	r.apply_tick(0.1, [red, blue])
	var ball := r.make_ball()
	_expect(ball.state == ModeObject.CARRIED, "the ball is handed to a Herc at the start")
	if ball.carrier != 1:
		r.apply_kill(blue, red)
	_expect(r.make_ball().carrier == 1, "killing the carrier hands the killer the ball")
	red.pos = Vector3(0, 0, 505)
	r.apply_tick(0.1, [red, blue])
	_expect(r.score.team_score(0) == 7.0 and r.score.player_score("Ann") >= 7.0, "touchdown in the enemy goal: +7")
	_expect(r.take_requests().any(func(q) -> bool: return q.kind == "respawn_all"), "a touchdown respawns everybody")
	blue.pos = Vector3(0, 0, 500)
	r.apply_tick(0.1, [_player(1, "Ann", 0), blue])
	_expect(int(r.fouls.get("Bob", 0)) == 1 or r.make_ball().carrier == 2, "entering a goal without the ball is a foul")


func _check_deathmatch_and_duel() -> void:
	print("Deathmatch, team deathmatch, duel, time limit")
	var dm := _make("deathmatch", [], {}, {"score_limit": 2})
	var ann := _player(1, "Ann", 0)
	var bob := _player(2, "Bob", 1)
	dm.apply_kill(bob, ann)
	dm.apply_kill(ann, ann)
	_expect(dm.score.player_score("Ann") == 0.0, "kill +1, suicide -1")
	dm.apply_kill(bob, ann)
	dm.apply_kill(bob, ann)
	_expect(dm.over and dm.winner == "Ann", "first to the kill limit wins")
	var tdm := _make("team_deathmatch", [], {0: "Red", 1: "Blue"}, {"score_limit": 1})
	tdm.apply_kill(_player(3, "Cat", 0), _player(4, "Dan", 0))
	_expect(not tdm.over and tdm.score.player_score("Dan") == -1.0, "a team kill costs the killer, scores nothing for the team")
	tdm.apply_kill(_player(2, "Bob", 1), _player(1, "Ann", 0))
	_expect(tdm.over and tdm.winner == "Red", "team deathmatch: the team score wins")
	var duel := _make("duel", [], {}, {"victory_damage": 0.5})
	var hurt := _player(2, "Bob", 1)
	hurt.integrity = 0.4
	duel.apply_tick(0.1, [_player(1, "Ann", 0), hurt])
	_expect(duel.over and duel.winner == "Ann", "duel: the victory terms (50 % damage) end the fight")
	var timed := _make("deathmatch", [], {}, {"time_limit_s": 10})
	timed.apply_kill(bob, ann)
	timed.apply_tick(11.0, [ann, bob])
	_expect(timed.over and timed.winner == "Ann", "the time limit ends the match: the best score wins")


func _check_state_sync() -> void:
	print("state sync")
	var host := _make("ctf", [_object(1, "flag", 0, Vector3.ZERO), _object(2, "flag", 1, Vector3(9, 0, 0))], {0: "Red", 1: "Blue"})
	host.apply_tick(0.1, [_player(10, "Ann", 0, Vector3(9, 0, 0))])
	host.apply_touch(_player(10, "Ann", 0, Vector3(9, 0, 0)), 2)
	var client := GameModes.make_rules("ctf", host.settings)
	client.apply_state(JSON.parse_string(JSON.stringify(host.make_state())))
	_expect(client.objects[2].state == ModeObject.CARRIED and client.make_player_name(client.objects[2].carrier) == "Ann",
		"a client's copy (through JSON) has the carried flag and the carrier's name")
	_expect(Array(client.make_hud_lines({})).any(func(l: String) -> bool: return l.contains("taken by Ann")), "the HUD says who has the flag")


# ------------------------------------------------------------------ 5 finer rules

func _check_rule_details() -> void:
	print("finer rules")
	var ctf := _make("ctf", [_object(1, "flag", 0, Vector3.ZERO), _object(2, "flag", 1, Vector3(500, 0, 0)),
		_object(3, "generator", 0, Vector3(0, 0, 100))], {0: "Red", 1: "Blue"},
		{"defend_radius_m": 20, "score_per_flag_defend": 1, "gen_defend_radius_m": 20, "score_per_gen_defend": 1,
			"stalemate_s": 60, "stalemate_every_s": 15, "stalemate_reveal_s": 6, "score_per_kill": 0})
	ctf.apply_kill(_player(2, "Bob", 1, Vector3(5, 0, 0)), _player(1, "Ann", 0, Vector3(30, 0, 0)))
	_expect(ctf.score.player_score("Ann") == 1.0, "a kill near the own flag is a flag defence")
	ctf.apply_kill(_player(2, "Bob", 1, Vector3(0, 0, 95)), _player(1, "Ann", 0, Vector3(200, 0, 0)))
	_expect(ctf.score.player_score("Ann") == 2.0, "a kill near the own generator is a generator defence")
	var ann := _player(1, "Ann", 0, Vector3(500, 0, 0))
	var bob := _player(2, "Bob", 1, Vector3.ZERO)
	ctf.apply_touch(ann, 2)
	ctf.apply_touch(bob, 1)
	ctf.apply_tick(59.0, [ann, bob])
	_expect(not ctf.revealed, "no stalemate before stalemate_s")
	ctf.apply_tick(2.0, [ann, bob])
	_expect(ctf.stalemate and ctf.revealed, "both flags away for 60 s: the carriers are revealed")
	ctf.apply_tick(7.0, [ann, bob])
	_expect(not ctf.revealed, "the reveal lasts stalemate_reveal_s")
	ctf.apply_tick(16.0, [ann, bob])
	_expect(ctf.revealed, "and comes back every stalemate_every_s")
	var t1 := _make("capture_hold", [_object(1, "switch", -1, Vector3.ZERO)], {0: "A", 1: "B"},
		{"capture_delay_s": 0, "hold_interval_s": 5, "hold_bonus_s": 60, "score_per_capture": 0, "team_capture_points": 0, "score_per_hold_bonus": 5, "switch_defend_radius_m": 80,
			"score_per_switch_defend": 1, "score_per_kill": 0, "time_limit_s": 0})
	t1.apply_touch(_player(1, "Ann", 0), 1)
	t1.apply_tick(61.0, [])
	_expect(t1.score.player_score("Ann") == 5.0, "Tribes 1: holding a captured tower 60 s gives the capturer 5")
	t1.apply_kill(_player(2, "Bob", 1, Vector3(300, 0, 0)), _player(1, "Ann", 0, Vector3(40, 0, 0)))
	_expect(t1.score.player_score("Ann") == 6.0, "a kill near a held tower is a tower defence")
	var hunt: HuntersRules = _make("hunters", [_object(1, "nexus", -1, Vector3.ZERO),
		_object(2, "nexus_zone", -1, Vector3.ZERO, {"half_extents": [10, 10, 10]})], {},
		{"hoard_mode": true, "hoard_start_min": 5, "hoard_duration_min": 3, "time_limit_s": 1200, "camping_s": 10, "camping_damage": 0.1})
	hunt.elapsed = 1200.0 - 4.0 * 60.0
	hunt.carried["Ann"] = 3
	hunt.apply_touch(_player(1, "Ann", 0), 1)
	_expect(hunt.is_hoard_time() and int(hunt.carried.Ann) == 3, "hoard mode: the Nexus takes no flags 5..2 minutes before the end")
	var camper := _player(1, "Ann", 0, Vector3(2, 0, 0))
	hunt.apply_tick(10.5, [camper])
	hunt.take_requests()
	hunt.apply_tick(10.0, [camper])
	var damage := hunt.take_requests().filter(func(q) -> bool: return q.kind == "damage")
	_expect(not damage.is_empty() and is_equal_approx(float(damage[0].share), 0.1), "camping in the Nexus trigger: warned, then damaged")
	var goals := [_object(1, "goal", 0, Vector3(0, 0, -500), {"half_extents": [100, 10, 15]}),
		_object(2, "goal", 1, Vector3(0, 0, 500), {"half_extents": [100, 10, 15]})]
	var foot: FootballRules = _make("football", goals, {0: "Red", 1: "Blue"},
		{"fumble_chance": 1.0, "score_per_fumble_takeup": 5, "max_fouls": 1, "penalty_s": 60,
			"penalty_boxes": {"1": [10, 10, 20, 20]}})
	var red := _player(1, "Ann", 0, Vector3.ZERO)
	var blue := _player(2, "Bob", 1, Vector3(0, 0, 10))
	foot.apply_tick(0.1, [red, blue])
	var carrier := red if foot.make_ball().carrier == 1 else blue
	var other := blue if carrier == red else red
	foot.apply_hit(carrier, other)
	_expect(foot.make_ball().carrier == int(other.id) and foot.score.player_score(str(other.key)) == 5.0, "a fumble hands the attacker the ball (+5)")
	foot.take_requests()
	var fouler := _player(2, "Bob", 1, Vector3(0, 0, -500))
	if foot.make_ball().carrier == 2:
		foot.apply_hit(fouler, red)
	foot.apply_tick(0.1, [_player(1, "Ann", 0), fouler])
	var penalty := foot.take_requests().filter(func(q) -> bool: return q.kind == "penalty")
	_expect(not penalty.is_empty() and penalty[0].box == [10, 10, 20, 20] and foot.is_penalized("Bob"), "the max_fouls-th foul: the penalty box")
	foot.apply_tick(61.0, [_player(1, "Ann", 0)])
	_expect(foot.take_requests().any(func(q) -> bool: return q.kind == "penalty_end") and not foot.is_penalized("Bob"),
		"after penalty_s he is back on his team")


# ------------------------------------------------------------------ 6 AI plans

func _check_ai_plans() -> void:
	print("AI plans")
	var r := _make("ctf", [_object(1, "flag", 0, Vector3.ZERO), _object(2, "flag", 1, Vector3(500, 0, 0))], {0: "Red", 1: "Blue"})
	var ps := [_player(1, "A1", 0, Vector3(10, 0, 0)), _player(2, "A2", 0, Vector3(20, 0, 0)), _player(3, "A3", 0, Vector3(5, 0, 0)),
		_player(4, "B1", 1, Vector3(490, 0, 0))]
	r.apply_tick(0.1, ps)
	var goals := GameModeAI.make_goals(r, ps, [1, 2, 3, 4], [])
	var grabbers := [1, 2, 3].filter(func(id) -> bool: return goals.has(id) and (goals[id].point as Vector3).distance_to(Vector3(500, 0, 0)) < 1.0)
	var defenders := [1, 2, 3].filter(func(id) -> bool: return goals.has(id) and bool(goals[id].hold))
	_expect(grabbers.size() >= 1 and defenders.size() >= 1, "CTF: bots grab the enemy flag and defend their own (%s)" % [goals.keys()])
	r.apply_touch(_player(4, "B1", 1, Vector3(0, 0, 0)), 1)
	r.apply_tick(0.1, ps)
	goals = GameModeAI.make_goals(r, ps, [1, 2, 3, 4], [])
	_expect([1, 2, 3].any(func(id) -> bool: return goals.has(id) and int(goals[id].hunt) == 4), "own flag taken: a bot hunts the carrier")
	_expect(bool(goals[4].urgent) and (goals[4].point as Vector3).distance_to(Vector3(500, 0, 0)) < 1.0, "a carrier runs home")
	var markers := [{"type": "AIOTouchObject", "mode": "FlagGrab", "team": 0, "pos": [0, 0, 0], "weights": [100, 0, 0, 0], "modes": []},
		{"type": "AIODefendLocation", "mode": "", "team": 0, "pos": [3, 0, 3], "weights": [50, 50, 0, 0], "modes": []}]
	var fresh := _make("ctf", [_object(1, "flag", 0, Vector3.ZERO), _object(2, "flag", 1, Vector3(500, 0, 0))], {0: "Red", 1: "Blue"})
	var mine := ps.slice(0, 3)
	fresh.apply_tick(0.1, mine)
	goals = GameModeAI.make_goals(fresh, mine, [1, 2, 3], markers)
	var at_marker := [1, 2, 3].filter(func(id) -> bool: return goals.has(id) and (goals[id].point as Vector3).distance_to(Vector3(3, 0, 3)) < 0.1)
	_expect(at_marker.size() == 2, "Tribes 2 maps: the mission's AI objectives and their weights decide (%d defenders)" % at_marker.size())
	var ch := _make("capture_hold", [_object(1, "switch", -1, Vector3(100, 0, 0))], {0: "A", 1: "B"})
	goals = GameModeAI.make_goals(ch, ps, [1], [])
	_expect(goals.has(1) and bool(goals[1].urgent) and (goals[1].point as Vector3).x == 100.0, "C&H: a bot goes to claim a switch")
	var dd := _make("defend_destroy", [_object(1, "objective", 1, Vector3(300, 0, 0)), _object(2, "objective", 0, Vector3(0, 0, 0))], {0: "A", 1: "B"})
	goals = GameModeAI.make_goals(dd, ps, [1, 2], [])
	_expect([1, 2].any(func(id) -> bool: return goals.has(id) and int(goals[id].attack_object) == 1), "D&D: a bot attacks the enemy objective")
	var hunters: HuntersRules = _make("hunters", [_object(1, "nexus", -1, Vector3(50, 0, 0))], {})
	hunters.carried["A1"] = 5
	goals = GameModeAI.make_goals(hunters, ps, [1], [])
	_expect(goals.has(1) and (goals[1].point as Vector3).x == 50.0, "Hunters: a bot with flags banks at the Nexus")
	var siege: SiegeRules = _make("siege", [_object(1, "switch", 1, Vector3(70, 0, 0))], {0: "A", 1: "B"}, {"first_offense": 0})
	goals = GameModeAI.make_goals(siege, ps, [1, 2, 3, 4], [])
	_expect([1, 2, 3].all(func(id) -> bool: return bool(goals[id].urgent)) and bool(goals[4].hold), "Siege: offence storms the switch, defence holds it")


# ------------------------------------------------------------------ 4 a CTF battle

func _start_battle(map_id: String, mode: String, start: String) -> Battle:
	var battle: Battle = load(BATTLE_SCENE).instantiate()
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"map": map_id, "game_mode": mode, "team_count": 2, "start": start, "ai": []}, true)
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	return battle


func _check_ctf_battle() -> void:
	print("CTF battle (tribes2:Katabatic)")
	if not Assets.has_pack("tribes2"):
		print("  skip (Tribes 2 not installed)")
		return
	var battle := await _start_battle("tribes2:Katabatic", "ctf", "on_foot")
	var director: GameModeDirector = battle.game_mode
	_expect(director != null and director.rules is CtfRules, "the battle runs the CTF director")
	if director == null or not is_instance_valid(battle.player):
		battle.queue_free()
		return
	var flags := director.rules.objects_of(ModeObject.KIND_FLAG)
	_expect(flags.size() == 2, "Katabatic's two team flags are in play")
	var player := battle.player
	var enemy: ModeObject = flags.filter(func(f: ModeObject) -> bool: return f.team != player.team)[0]
	var own: ModeObject = flags.filter(func(f: ModeObject) -> bool: return f.team == player.team)[0]
	player.global_position = enemy.pos
	for i in 10:
		await get_tree().physics_frame
	_expect(enemy.state == ModeObject.CARRIED, "walking onto the enemy flag takes it")
	player.global_position = own.pos
	for i in 10:
		await get_tree().physics_frame
	_expect(director.rules.score.team_score(player.team) == 1.0, "bringing it to the own flag captures (team score %d)" % director.rules.score.team_score(player.team))
	var panel := battle.overlay.objectives
	await get_tree().create_timer(ObjectivesPanel.REFRESH_SECONDS * 2.0).timeout
	_expect(panel != null and panel.shown_lines().any(func(l) -> bool: return str(l.text).contains("Capture the Flag")) \
		and panel.shown_lines().any(func(l) -> bool: return str(l.text).begins_with("Red ")),
		"the objectives panel shows the mode and the score")
	battle.queue_free()
	await get_tree().process_frame


func _check_spawn_facing() -> void:
	print("spawn facing")
	if not Assets.has_pack("tribes2"):
		return
	var holder := Node3D.new()
	get_tree().root.add_child(holder)
	var built := MapBuilder.build(holder, "tribes2:Katabatic")
	var clearance := SpawnClearance.make(holder)
	var walled := 0
	for xf in built.herc_spawns:
		if clearance.make_clear_distance(xf.origin, -xf.basis.z) < 15.0:
			walled += 1
	_expect(walled == 0, "no Herc start on Katabatic faces a wall within 15 m (%d do)" % walled)
	holder.queue_free()
	await get_tree().process_frame


func _check_bots_play_ctf() -> void:
	print("bots play CTF (tribes2:Katabatic)")
	if not Assets.has_pack("tribes2"):
		return
	var battle: Battle = load(BATTLE_SCENE).instantiate()
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"map": "tribes2:Katabatic", "game_mode": "ctf", "team_count": 2, "start": "on_foot", "ai": [],
		InfantryBots.CONFIG_KEY: 4}, true)
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	var director: GameModeDirector = battle.game_mode
	director.brains.apply_goals()
	var bots := battle.infantry.bots.make_bot_soldiers()
	var with_goal := bots.filter(func(s: Infantry) -> bool:
		var brain := s.get_node_or_null("Bot")
		return brain != null and not (brain.objective as Dictionary).is_empty())
	_expect(bots.size() == 4 and with_goal.size() >= 2, "the bots get objectives (%d of %d)" % [with_goal.size(), bots.size()])
	var grabber: Infantry = null
	for s in with_goal:
		if bool(s.get_node("Bot").objective.urgent):
			grabber = s
	_expect(grabber != null, "a bot is sent for the enemy flag")
	if grabber:
		var goal: Vector3 = grabber.get_node("Bot").objective.point
		var before := grabber.global_position.distance_to(goal)
		Engine.time_scale = 4.0
		var after := before   # the closest he came: base turrets may kill him on the way, and he respawns at home
		for k in 80:
			for f in 30:   # half a second of game time in physics frames (a timer follows frame time, which lags under time_scale)
				await get_tree().physics_frame
			after = minf(after, grabber.global_position.distance_to(goal) if grabber.alive else after)
		Engine.time_scale = 1.0
		var bot_ids := bots.map(func(s: Infantry) -> int: return s.net_id)
		var taken := director.rules.objects_of(ModeObject.KIND_FLAG).any(func(f: ModeObject) -> bool:
			return f.state == ModeObject.DROPPED or (f.state == ModeObject.CARRIED and bot_ids.has(f.carrier)))
		_expect(taken or after < before * 0.6, "a bot takes a flag or the grabber closes on it (%d m -> closest %d m, taken by a bot: %s)" % [before, after, taken])
	battle.queue_free()
	await get_tree().process_frame


func _check_switch_resources() -> void:
	print("C&H: a switch's turrets and stations change team (tribes2:Abominable)")
	if not Assets.has_pack("tribes2"):
		return
	var battle := await _start_battle("tribes2:Abominable", "capture_hold", "on_foot")
	var director: GameModeDirector = battle.game_mode
	var switches := director.rules.objects_of(ModeObject.KIND_SWITCH).filter(func(o: ModeObject) -> bool: return o.group.size() >= 3)
	if switches.is_empty() or not is_instance_valid(battle.player):
		_expect(false, "a switch with a group and a player")
		battle.queue_free()
		return
	var sw: ModeObject = switches[0]
	var group := GameModeResources.make_group_nodes_of(battle, sw.group)
	battle.player.global_position = sw.pos
	for i in 10:
		await get_tree().physics_frame
	_expect(sw.owner_team == battle.player.team, "the player claims the switch")
	_expect(not group.is_empty() and group.all(func(n) -> bool: return int(n.team) == battle.player.team),
		"its %d base objects join the player's team" % group.size())
	battle.queue_free()
	await get_tree().process_frame


func _check_war_defenders() -> void:
	print("WAR defenders (starsiege:WAR_Martian_Standoff)")
	if not Assets.has_pack("starsiege"):
		return
	var battle := await _start_battle("starsiege:WAR_Martian_Standoff", "war", "vehicle")
	await get_tree().physics_frame
	var defenders := battle.vehicles.values().filter(func(h: Herc) -> bool: return h.has_meta(GameModeBrains.DEFENDER_META))
	_expect(defenders.size() == 6, "both bases' AI Hercs are dropped (%d)" % defenders.size())
	if not defenders.is_empty():
		var d: Herc = defenders[0]
		battle.game_mode.rules.settings["ai_respawn_s"] = 1.0
		d.apply_destruction(null)
		await get_tree().create_timer(BattleRules.RESPAWN_TIME + 2.0).timeout
		_expect(d.alive, "a destroyed defender comes back at its re-drop point")
	battle.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------------ screenshots

func _take_shots() -> void:
	var shots := [["tribes2:Katabatic", "ctf", "modes_ctf.png"], ["tribes2:Abominable", "capture_hold", "modes_capture_hold.png"],
		["tribes2:Rasp", "hunters", "modes_hunters.png"], ["es1:desert_day", "team_deathmatch", "modes_es1_team.png"],
		["starsiege:CTF_Balance_of_Power", "ctf", "modes_starsiege_ctf.png"]]
	for s in shots:
		var pack := str(s[0]).split(":")[0]
		if not Assets.has_pack(pack):
			continue
		var battle := await _start_battle(s[0], s[1], "vehicle")
		for i in 40:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		img.save_png(_shots.path_join(s[2]))
		print("  shot %s" % s[2])
		battle.queue_free()
		await get_tree().process_frame

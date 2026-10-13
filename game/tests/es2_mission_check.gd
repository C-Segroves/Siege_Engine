extends Node
## Headless check of Earthsiege 2 missions in the Battle runtime:
##   Godot --headless --path game res://tests/es2_mission_check.tscn -- --missions=C1_01,C1_02 [--cheat]
## For each mission: builds the battle, reports units spawned / dormant, how far units sit from the
## terrain surface, then (with --cheat) drives the player through the nav points and destroys the
## hostile units/structures to check that the objectives can complete. Prints one RESULT line per mission.

var _names: Array = []
var _cheat := false
var _idle := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--missions="):
			_names = a.substr(11).split(",")
		elif a.begins_with("--idle="):
			_idle = float(a.substr(7))
		elif a == "--cheat":
			_cheat = true
	if OS.get_cmdline_user_args().has("--campaign"):
		get_tree().quit(_campaign_test())
		return
	if _names.is_empty():
		_names = ["C1_01"]
	_run.call_deferred()


func _run() -> void:
	var bad := 0
	for n in _names:
		var ok: bool = await _check(String(n))
		if not ok:
			bad += 1
	print("es2 mission check: %d missions, %d problems" % [_names.size(), bad])
	get_tree().quit(1 if bad else 0)


func _check(name: String) -> bool:
	var mdef := MissionCompiler.load_mission("es2:" + name, PackedInt32Array(), 1, -1, {"resolve_texts": true})
	if mdef.is_empty():
		print("RESULT %s: cannot compile" % name)
		return false
	var battle: Node = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "respawn": false, "mission": mdef,
		"roster": {1: {"name": "Tester", "vehicle": "es2:OUTLAW", "team": 0, "loadout": []}}}
	var result := {}
	battle.match_finished.connect(func(r): result.merge(r))
	get_tree().root.add_child(battle)
	for i in 30:
		await get_tree().physics_frame
		if i % 5 == 0 and battle.player and OS.get_cmdline_user_args().has("--trace"):
			print("   f", i, " ", battle.player.global_position, " floor=", battle.player.is_on_floor(), " xf0=", battle.mission.player_spawn(0).origin)
	var vs := get_tree().get_nodes_in_group("vehicles")
	var worst := 0.0
	var worst_name := ""
	for v in vs:
		if v is Flyer:
			continue
		var g := MapBuilder.ground_height(battle, v.global_position)
		var dy: float = v.global_position.y - g
		if absf(dy) > absf(worst):
			worst = dy
			worst_name = v.display_name
	var st_off := 0.0
	for s in get_tree().get_nodes_in_group("structures"):
		st_off = maxf(st_off, absf(s.global_position.y - MapBuilder.ground_height(battle, s.global_position)))
	var rt: MissionRuntime = battle.mission
	if battle.player:
		var pp: Vector3 = battle.player.global_position
		print("  player at ", pp, " ground ", MapBuilder.ground_height(battle, pp), " nav0 ", rt.nav_points[0] if not rt.nav_points.is_empty() else null, " vel ", battle.player.velocity)
	var line := "RESULT %s: world=%d zone=%d vehicles=%d structures=%d dormant_groups=%d nav=%d objectives=%d worst_unit_dy=%.1fm(%s) worst_structure_dy=%.1fm" % [
		name, int(battle.config.world), int(battle.config.zone), vs.size(), rt.structures.size(), rt.dormant_groups.size(),
		rt.nav_points.size(), _arr(mdef.get("objectives")).size(), worst, worst_name, st_off]
	if _idle > 0.0:
		var t1 := Time.get_ticks_msec()
		while result.is_empty() and Time.get_ticks_msec() - t1 < int(_idle * 1000.0):
			await get_tree().physics_frame
		line += " | idle %.0fs: %s status=%d" % [_idle, ("ENDED success=%s" % result.get("success")) if not result.is_empty() else "running", (rt as MissionRuntimeES2).status()]
	if _cheat:
		var t0 := Time.get_ticks_msec()
		var player: Node3D = battle.player
		var rt2 := rt as MissionRuntimeES2
		var protect := []
		for ob in rt2.objectives:
			if not ob.def.get("required", true):
				protect += rt2.target_nodes(ob.def.get("target"))
			elif int(ob.def.get("type", 0)) in [3, 4]:
				protect += rt2.target_nodes(ob.def.get("target"))
		var o00 = rt2.orders.current_order(0)
		if o00 is Dictionary and int(rt2.m.header.raw[3]) in [3, 7]:
			protect += rt2.target_nodes(o00.get("target"))
		var step := 0
		while result.is_empty() and Time.get_ticks_msec() - t0 < 90000:
			if player and is_instance_valid(player) and player.alive:
				player.shield_front = player.shield_max
				player.shield_rear = player.shield_max
				for c in player.components:
					c.hp = c.max
				step += 1
				for ri in rt.regions.size():
					rt.fire_region(ri)
				for v in get_tree().get_nodes_in_group("vehicles"):
					if v.team != 0 and v.alive and not protect.has(v):
						v.apply_hit(1e6, 1e6, player, v.global_position)
				for st in rt.structures:
					if st.team != 0 and st.alive and not protect.has(st):
						st.destroy(player)
				# escort-style goals: move the target group to the end of its route
				for ob in rt2.objectives:
					var o: Dictionary = ob.def
					if int(o.get("type", 0)) == 0 and o.get("path_points") is Array and not o.path_points.is_empty():
						var gi: int = rt2.group_of(o.get("target"))
						if gi > 0:
							for u in rt2.group_units.get(gi, []):
								if is_instance_valid(u) and u.alive:
									u.global_position = rt2.on_ground(MissionRuntime.to_godot(o.path_points[-1])) + Vector3.UP
				var scan_t: Array = []
				var o0 = rt2.orders.current_order(0)
				if o0 is Dictionary and o0.get("target") is Dictionary:
					scan_t = rt2.target_nodes(o0.target)
				for ob in rt2.objectives:
					if int(ob.def.get("type", 0)) in [3, 4] and scan_t.is_empty():
						scan_t = rt2.target_nodes(ob.def.get("target"))
				if rt.nav_index < rt.nav_points.size():
					player.global_position = rt.nav_points[rt.nav_index] + Vector3.UP * 2.0
				elif not rt2.scan_flag and not scan_t.is_empty() and is_instance_valid(scan_t[0]):
					var tp: Vector3 = scan_t[0].global_position
					player.global_position = rt2.on_ground(tp + Vector3(0, 0, 30)) + Vector3.UP
					player.look_at(Vector3(tp.x, player.global_position.y, tp.z))
			for i in 10:
				await get_tree().physics_frame
		line += " status=%d" % rt2.status()
		line += " | cheat run: %s" % (("success=%s code=%s" % [result.get("success"), result.get("code")]) if not result.is_empty() else "NO END after 60 s")
		if not result.is_empty():
			line += " text=%s" % String(result.get("text", "")).replace("\n", " / ").left(160)
	print(line)
	battle.queue_free()
	await get_tree().process_frame
	Sfx.stop_music(0.0)
	return absf(worst) < 3.0 and (not _cheat or not result.is_empty())


static func _arr(v) -> Array:
	return v if v is Array else []


## CampaignES2 progression: always win -> 50 missions then victory; fail C1_10 -> war lost; fail C1_02 -> continue.
func _campaign_test() -> int:
	var errs := 0
	var c := CampaignES2.start(1, 7)
	var n := 0
	while not c.is_over() and n < 100:
		var m := c.load_current()
		if m.is_empty() or m.get("header", {}).get("mode") != "campaign":
			printerr("campaign: bad mission ", c.current_mission())
			errs += 1
			break
		c.record_result(true, c.prepared_vars())
		n += 1
	if not c.is_victory() or n != 50:
		printerr("campaign: expected victory after 50, got ", c.state, " after ", n)
		errs += 1
	c = CampaignES2.start(1, 7)
	c.record_result(true)
	c.record_result(false)
	if c.current_mission() != "C1_03":
		printerr("campaign: failed ordinary mission should move on, at ", c.current_mission())
		errs += 1
	var d := CampaignES2.from_dict(JSON.parse_string(JSON.stringify(c.to_dict())))
	if d.current_mission() != "C1_03":
		errs += 1
	while c.current_mission() != "C1_10":
		c.record_result(true)
	c.record_result(false)
	if not c.is_game_over():
		printerr("campaign: failing C1_10 should lose the war")
		errs += 1
	c.replay()
	if c.current_mission() != "C1_10":
		printerr("campaign: replay should return to C1_10")
		errs += 1
	var prov = load("res://games/es2/campaign_provider.gd")
	if prov.start("").current_mission() != "C1_01":
		errs += 1
	print("campaign es2: %s" % ("ok" if errs == 0 else "%d errors" % errs))
	return errs

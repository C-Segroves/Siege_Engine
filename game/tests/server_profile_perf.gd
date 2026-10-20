extends Node
## Load time and RAM of a Varuna battle with the full world or the server profile (collision only).
##   godot --headless --audio-driver Dummy --path game res://tests/server_profile_perf.tscn -- --test-store --profile=server|full
## Prints "PROFILE <name> load_ms=.. static_mb=.. peak_mb=.. rss_mb=.. frame_ms=..".
const ID_LIMIT_S := 300.0
var _pilot := "QA Profile %d" % OS.get_process_id()


func _ready() -> void:
	get_tree().create_timer(ID_LIMIT_S, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	Net.player_name = _pilot
	_run.call_deferred()


func _arg(key: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % key):
			return a.get_slice("=", 1)
	return ""


func _rss_mb() -> float:
	var out := []
	OS.execute("powershell", ["-NoProfile", "-Command", "(Get-Process -Id %d).WorkingSet64" % OS.get_process_id()], out)
	return float(str(out[0]).strip_edges()) / 1048576.0 if not out.is_empty() else -1.0


func _run() -> void:
	var profile := _arg("profile")
	ServerProfile.set_collision_only(profile == "server")
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": VarunaMap.MAP_ID, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = 4242
	if _arg("stage") != "":
		var ts := Time.get_ticks_msec()
		var m := VarunaMap.make_map()
		print("STAGE make_map ms=", Time.get_ticks_msec() - ts, " statics=", m.statics.size(), " interiors=", m.interiors.size(), " stations=", m.stations.size())
		var root := Node3D.new()
		add_child(root)
		ts = Time.get_ticks_msec()
		var mem := OS.get_static_memory_usage()
		MapTerrain.build(root, m.terrain, m._dir)
		print("STAGE terrain ms=", Time.get_ticks_msec() - ts, " mb=", (OS.get_static_memory_usage() - mem) / 1048576)
	var t0 := Time.get_ticks_msec()
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	var load_ms := Time.get_ticks_msec() - t0   # Battle._ready: map, terrain, shapes, spawns
	for i in 120:
		await get_tree().physics_frame
	var t1 := Time.get_ticks_usec()
	for i in 60:
		await get_tree().process_frame
	var frame_ms := (Time.get_ticks_usec() - t1) / 1000.0 / 60.0
	print("PROFILE %s load_ms=%d static_mb=%.0f peak_mb=%.0f rss_mb=%.0f frame_ms=%.1f meshes=%d" % [profile, load_ms,
		OS.get_static_memory_usage() / 1048576.0, OS.get_static_memory_peak_usage() / 1048576.0, _rss_mb(), frame_ms,
		battle.find_children("*", "MeshInstance3D", true, false).size()])
	if _arg("detail") != "":
		_print_mesh_detail(battle)
		var lod0 := 0
		var other := 0
		var rest := 0
		for id in Assets._shapes:
			var sh: Dictionary = Assets._shapes[id]
			for i in sh.lods.size():
				var b := var_to_bytes(sh.lods[i]).size()
				if i == 0:
					lod0 += b
				else:
					other += b
			rest += var_to_bytes(sh.get("sequences", [])).size() + var_to_bytes(sh.get("transforms", [])).size()
		var verts := 0
		var heights := 0
		for c in battle.find_children("*", "CollisionShape3D", true, false):
			if c.shape is ConcavePolygonShape3D:
				verts += (c.shape as ConcavePolygonShape3D).get_faces().size()
			elif c.shape is HeightMapShape3D:
				heights += (c.shape as HeightMapShape3D).map_data.size()
		print("COLLISION concave_verts=%d heightmap_samples=%d" % [verts, heights])
		print("SHAPES cached=%d lod0_mb=%.1f otherlods_mb=%.1f seq_tf_mb=%.1f" % [Assets._shapes.size(), lod0 / 1048576.0, other / 1048576.0, rest / 1048576.0])
	get_tree().quit()


func _print_mesh_detail(battle: Node) -> void:
	var by := {}
	for mi in battle.find_children("*", "MeshInstance3D", true, false):
		var n: Node = mi
		var key := ""
		while n != battle and n != null:
			key = n.get_class() + ":" + String(n.name).rstrip("0123456789@") if n.get_parent() == battle else key
			n = n.get_parent()
		by[key] = int(by.get(key, 0)) + 1
	var keys := by.keys()
	keys.sort_custom(func(a, b): return by[a] > by[b])
	for k in keys.slice(0, 15):
		print("MESHES %5d %s" % [by[k], k])
	var kinds := {}
	for n in battle.find_children("*", "Node", true, false):
		kinds[n.get_class()] = int(kinds.get(n.get_class(), 0)) + 1
	print("NODES ", kinds)

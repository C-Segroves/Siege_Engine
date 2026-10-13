extends Node
## Runs MissionCompiler on the cases written by tools/tests/test_mission_port.py and writes the
## results as JSON for comparison with tools/mission.py mission_json(). Also smoke-tests Campaign.
##
##   Godot --headless --path game res://tests/test_mission_compiler.tscn -- --cases=<in.json> --out=<out.json>
##
## Without arguments: loads every mission once (seed 1) plus a campaign run and reports errors.

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.find("=") > 0:
			args[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	var code := 0
	if args.has("cases"):
		code = _run_cases(args["cases"], args.get("out", "user://mission_gd.json"))
	else:
		code = _smoke()
	code = maxi(code, _test_campaign())
	get_tree().quit(code)


func _run_cases(cases_path: String, out_path: String) -> int:
	var f := FileAccess.open(cases_path, FileAccess.READ)
	if f == null:
		printerr("cannot read ", cases_path)
		return 1
	var cases: Array = JSON.parse_string(f.get_as_text())
	var results := []
	var t0 := Time.get_ticks_msec()
	for c in cases:
		var mv := PackedInt32Array()
		if c["mvars"] != null:
			for x in c["mvars"]:
				mv.append(int(x))
		var seed_v := -1 if c["seed"] == null else int(c["seed"])
		var camp := int(c["campaign"])
		var opts := {}
		if c.get("options") != null:
			for k in c["options"]:
				opts[k] = int(c["options"][k])
		results.append(MissionCompiler.load_mission(c["name"], mv, seed_v, camp, opts))
	var dt := Time.get_ticks_msec() - t0
	var o := FileAccess.open(out_path, FileAccess.WRITE)
	o.store_string(JSON.stringify(results))
	o.close()
	print("mission compiler: %d cases in %d ms (%.1f ms/case)" % [cases.size(), dt, float(dt) / maxi(cases.size(), 1)])
	return 0


func _smoke() -> int:
	var bad := 0
	for n in MissionCompiler.mission_names():
		var m := MissionCompiler.load_mission(n, PackedInt32Array(), 1)
		if m.is_empty() or not m.has("groups"):
			printerr("failed: ", n)
			bad += 1
	print("smoke: %d missions, %d failed" % [MissionCompiler.mission_names().size(), bad])
	return 1 if bad else 0


func _test_campaign() -> int:
	var errs := 0
	# always win: btlset_0 path C0 -> C1 -> C3 -> C5 -> C7 -> victory
	var c := Campaign.start(0, 42)
	var played := 0
	while not c.is_over() and played < 200:
		var m := c.load_current()
		if m.is_empty():
			printerr("campaign: cannot load ", c.current_mission())
			errs += 1
			break
		if m["header"]["mode"] != "campaign":
			printerr("campaign: mission not in campaign mode")
			errs += 1
		# save/load round trip mid-campaign
		var d := c.to_dict()
		var c2 := Campaign.from_dict(JSON.parse_string(JSON.stringify(d)))
		if JSON.stringify(c2.to_dict()) != JSON.stringify(d):
			printerr("campaign: to_dict/from_dict mismatch")
			errs += 1
		c.record_result(true, PackedInt32Array())
		played += 1
	var camps := []
	for h in c.history:
		if camps.is_empty() or camps[-1] != h["campaign"]:
			camps.append(h["campaign"])
	if not c.is_victory() or camps != [0, 1, 3, 5, 7]:
		printerr("campaign win path wrong: ", camps, " ", c.state)
		errs += 1
	# fail the last mission of C0 -> C2, fail the end of C2 -> game over
	c = Campaign.start(0, 7)
	while not c.is_over():
		var last := c.slot == c.slot_count() - 1
		c.record_result(not last)
	if not c.is_game_over() or c.history[-1]["campaign"] != 2:
		printerr("campaign fail path wrong: ", c.state, " ", c.history[-1])
		errs += 1
	# variant selection: C0 slot 3 = 3A after success, 3B after failure
	c = Campaign.start(0, 1)
	for i in 3:
		c.record_result(i != 2)
	if c.current_mission() != "B0_C0_3B":
		printerr("campaign variant wrong: ", c.current_mission())
		errs += 1
	print("campaign: %s (%d missions on the win path)" % ["ok" if errs == 0 else "FAILED", played])
	return 1 if errs else 0

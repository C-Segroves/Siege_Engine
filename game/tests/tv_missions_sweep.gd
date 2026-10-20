extends Node
## Starts every Tribes: Vengeance campaign mission in a Battle and runs it for a few simulated seconds: the TVMissionRuntime loads
## its script, registers the placed soldiers, starts the level-start scripts and streams soldiers in around the player; then the
## script's own end (next mission / fail) is forced through the runtime to check the result path.
##   TV_TEST_ROOT=<scratch data folder> godot --audio-driver Dummy --path game res://tests/tv_missions_sweep.tscn
## Look for SCRIPT ERROR lines in the output as well as FAIL lines.
const PACK := "tribes_v"
const SETTLE_FRAMES := 45
const WATCHDOG_SECONDS := 900.0

var _fails := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void:
		print("FAIL  watchdog")
		get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var root := OS.get_environment("TV_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	if not Assets.has_pack(PACK) or not Assets.has_pack("tribes2"):
		print("tv_missions_sweep: Tribes: Vengeance or Tribes 2 is not installed, skipped")
		get_tree().quit(0)
		return
	Session.start_stage_campaign(PACK)
	var total: int = Session.campaign.missions.size()
	var first := int(OS.get_environment("TV_FIRST")) if OS.get_environment("TV_FIRST") != "" else 0
	var last := int(OS.get_environment("TV_LAST")) if OS.get_environment("TV_LAST") != "" else total - 1
	for i in range(first, mini(last, total - 1) + 1):
		Session.start_stage_campaign(PACK)
		Session.campaign.index = i
		var herc := MatchFlow.make_issued_soldier()
		var b: Battle = load("res://games/es1/battle.tscn").instantiate()
		b.config = MatchFlow.make_mission_config(str(herc.vehicle), [], {})
		get_tree().root.add_child(b)
		for _f in SETTLE_FRAMES:
			await get_tree().process_frame
		var name := str(Session.current_mission().get("name", ""))
		var rt := b.mission as TVMissionRuntime
		var ok := rt != null and rt.script_run != null and b.player is Infantry
		var spawned := 0
		if rt != null:
			spawned = rt._npcs.filter(func(e: Dictionary) -> bool: return bool(e.spawned)).size()
		print("%s  %2d %-26s npcs %3d spawned %2d objectives %d running %d player %s" % ["ok  " if ok else "FAIL", i, name,
			rt._npcs.size() if rt != null else -1, spawned, rt.objectives.size() if rt != null else -1,
			rt.script_run.running_labels().size() if rt != null and rt.script_run != null else -1,
			(b.player as Infantry).make_body_shape_id() if b.player is Infantry else "?"])
		if not ok:
			_fails += 1
		elif rt != null:
			rt.apply_end(true)
			await get_tree().process_frame
			if not rt.is_over():
				print("FAIL  %s: next-mission did not end the mission" % name)
				_fails += 1
		b.queue_free()
		for _f in 5:
			await get_tree().process_frame
	print("tv_missions_sweep: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)

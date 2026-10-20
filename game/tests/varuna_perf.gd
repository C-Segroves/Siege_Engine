extends Node
## Windowed frame-time profile of a Varuna raid; toggles suspects one at a time.
##   godot --audio-driver Dummy --path game res://tests/varuna_perf.tscn -- --test-store
const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
var _pilot := "QA Perf %d" % OS.get_process_id()
var _battle: Battle


func _ready() -> void:
	get_tree().create_timer(400.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	Net.player_name = _pilot
	_run.call_deferred()


func _sample(label: String, frames := 90) -> void:
	for i in 20:
		await get_tree().process_frame
	var t0 := Time.get_ticks_usec()
	var phys := 0.0
	var proc := 0.0
	for i in frames:
		await get_tree().process_frame
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		proc += Performance.get_monitor(Performance.TIME_PROCESS)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / frames
	print("PERF %-28s frame %6.2f ms  proc %5.2f phys %5.2f | draws %5d objs %5d prims %8d" % [label, ms, proc / frames * 1000.0, phys / frames * 1000.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)])


func _toggle(label: String, nodes: Array) -> void:
	var prev: Array = []
	for n in nodes:
		prev.append(n.visible)
		n.visible = false
	await _sample("without " + label)
	for i in nodes.size():
		nodes[i].visible = prev[i]


func _run() -> void:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": VarunaMap.MAP_ID, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = 4242
	_battle = load("res://games/es1/battle.tscn").instantiate()
	_battle.config = config
	get_tree().root.add_child(_battle)
	get_tree().current_scene = _battle
	for i in 600:
		await get_tree().physics_frame
	var vp := get_viewport()
	print("PERF window ", DisplayServer.window_get_size(), " bodies ", Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	await _sample("baseline")
	var chunks: Array = []
	for t in get_tree().get_nodes_in_group("terrain"):
		for c in t.get_children():
			if c is MeshInstance3D:
				chunks.append(c)
	print("PERF terrain chunks ", chunks.size())
	var bots := _battle.vehicles.values().filter(func(h) -> bool: return h is Infantry and h != _battle.player)
	print("PERF asleep ", _battle.bot_sleep.sleeping_count, " tiers NEAR/MID/FAR/ASLEEP ", _battle.bot_sleep.tier_counts)
	_print_radar_diag()
	print("PERF far ", bots.filter(func(b): return b.far_lod).size(), " of ", bots.size(), " stowed ", bots.filter(func(b): return b.stowed).size())
	for b in bots: b.set_meta("perf_idle", true)
	await _sample("far bots idle")
	for b in bots: b.set_physics_process(false)
	await _sample("infantry physics off")
	for b in bots: b.set_physics_process(true)
	for b in bots: b.set_process(false)
	await _sample("infantry process off")
	get_tree().quit()


## Radar suspicion: of the soldiers beyond the sleep range of the player, how many are on his radar scope.
func _print_radar_diag() -> void:
	var me: Node3D = _battle.player
	var sleeper: BotSleep = _battle.bot_sleep
	var beyond := 0
	var on_scope := 0
	for v in _battle.vehicles.values():
		if v is Infantry and v != me:
			var d := Vector2(v.global_position.x - me.global_position.x, v.global_position.z - me.global_position.z).length()
			if d > sleeper.make_sight_range() + 60.0:
				beyond += 1
				on_scope += 1 if RadarContacts.is_on_scope(me, v) else 0
	print("PERF radar: ", beyond, " soldiers beyond sleep range, ", on_scope, " on the player's scope (range ", RadarContacts.make_range(me), ")")

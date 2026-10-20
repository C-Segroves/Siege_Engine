extends Node
## Per-game netcode profiles (docs/DEDICATED_SERVER_SCALING.md chunk M): the table loads, games inherit and override,
## the profile reaches the interest grid, the prediction and the lag-compensation rules, and the dedicated tick follows
## the game when the server config leaves it open.
##   godot --headless --audio-driver Dummy --path game res://tests/net_profile_check.tscn
## Prints "net_profile_check: OK|FAILED (<n> failures)"; exit code 0 / 1.

var _failures := 0


func _ready() -> void:
	_check_table()
	_check_overrides()
	_check_consumers()
	_check_weapon_rules()
	_check_tick_follows_profile()
	print("net_profile_check: %s" % ("OK" if _failures == 0 else "FAILED (%d failures)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		printerr("net_profile_check FAIL: ", what)


func _check_table() -> void:
	var base := NetProfile.make_default()
	_expect(base.tick_hz == 30 and base.snapshot_hz == 15.0 and base.tier_intervals == [1, 3, 5], "default entry: 30 Hz tick, 15 Hz snapshots")
	_expect(base.max_rewind_ms == LagCompensation.MAX_REWIND_MS and base.snap_herc_m == Prediction.SNAP_HERC_M
		and base.snap_infantry_m == Prediction.SNAP_INFANTRY_M and base.prediction_blend_s == Prediction.BLEND_S,
		"the default entry equals the built-in constants")
	for id in ["es1", "es2", "bd", "starsiege", "tribes", "tribes2", "tribes_aa", "tribes_v", "unknown_game"]:
		var profile := NetProfile.load_for(id)
		_expect(profile.tick_hz >= 1 and profile.mid_m >= profile.near_m, "%s loads" % id)


func _check_overrides() -> void:
	var tribes := NetProfile.load_for("tribes")
	_expect(tribes.tick_hz == 32 and tribes.snapshot_hz == 32.0, "Tribes: 32 ms tick, a snapshot per tick")
	_expect(NetProfile.load_for("tribes2").tick_hz == 32 and NetProfile.load_for("tribes_v").tick_hz == 32, "Tribes 2 and V inherit it")
	var herc := NetProfile.load_for("es1")
	_expect(herc.tick_hz == 30 and herc.snapshot_hz == 15.0 and herc.snap_herc_m == 3.0, "Earthsiege: 30 Hz, 15 Hz, loose 3 m reconcile")
	_expect(NetProfile.load_for("starsiege").prediction_blend_s == herc.prediction_blend_s, "Starsiege keeps the Herc feel")
	_expect(NetProfile.load_for("unknown_game").tick_hz == NetProfile.make_default().tick_hz, "an unknown game gets the default")


func _check_consumers() -> void:
	var profile := NetProfile.load_for("tribes")
	profile.mid_m = 500.0
	profile.tier_intervals = [1, 2, 4]
	var grid := InterestGrid.new()
	profile.apply_to_grid(grid)
	_expect(grid.mid_m == 500.0 and grid.tier_interval == [1, 2, 4], "the grid takes the distances and intervals")
	var prediction := Prediction.new(Callable(), 1.0 / 60.0, 2, 3.0)
	profile.prediction_blend_s = 0.25
	profile.prediction_epsilon_m = 0.2
	var herc := Herc.new()
	profile.apply_to_prediction(prediction, herc)
	herc.free()
	_expect(prediction.blend_s == 0.25 and prediction.epsilon_m == 0.2 and prediction.snap_m == profile.snap_herc_m, "prediction thresholds")


func _check_weapon_rules() -> void:
	var profile := NetProfile.make_default()
	_expect(profile.compensates_beam("laser") and not profile.compensates_projectile("shell", 100.0), "beams yes, slow shells no")
	_expect(profile.compensates_projectile("slug", 400.0), "a fast slug is compensated")
	profile.never_compensated = ["laser"]
	profile.always_compensated = ["shell"]
	_expect(not profile.compensates_beam("laser") and profile.compensates_projectile("shell", 100.0), "exclude and include lists")
	profile.lag_comp_enabled = false
	_expect(not profile.compensates_beam("x") and not profile.compensates_projectile("shell", 900.0), "lag compensation off")
	profile.lag_comp_enabled = true
	profile.projectile_min_mps = 0.0
	profile.always_compensated = []
	_expect(not profile.compensates_projectile("slug", 900.0), "projectile_min_mps 0 turns fast projectiles off")


func _check_tick_follows_profile() -> void:
	var was_dedicated := Net.dedicated
	var was_hz := ServerClock.dedicated_hz
	var was_physics := Engine.physics_ticks_per_second
	Net.dedicated = true
	ServerClock.follows_profile = false
	_expect(ServerClock.make_for_session(32).tick_hz == was_hz, "a pinned server tick ignores the profile")
	ServerClock.follows_profile = true
	_expect(ServerClock.make_for_session(32).tick_hz == 32 and Engine.physics_ticks_per_second == 32, "an open server tick follows the game")
	Net.dedicated = was_dedicated
	ServerClock.follows_profile = false
	ServerClock.configure_dedicated(was_hz, ServerClock.DEFAULT_MAX_CATCHUP_STEPS)
	Engine.physics_ticks_per_second = was_physics
	Engine.max_fps = 0

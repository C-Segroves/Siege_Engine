extends Node
## The fixed server tick (ServerClock) and the server metrics helpers.
##   godot --headless --audio-driver Dummy --path game res://tests/server_clock_check.tscn
## Prints "server_clock_check: PASS" or "FAIL (n)"; exit code 0 / 1.

const SECOND_IN_STEPS_60 := 60
const STALL_SECONDS := 0.1

var _failures := 0


func _ready() -> void:
	_check_tick_rate_follows_simulated_time()
	_check_stall_is_capped_and_counted()
	_check_steady_state_after_stall()
	_check_intervals_and_time()
	_check_percentiles()
	_check_report_line()
	print("server_clock_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _run_seconds(clock: ServerClock, seconds: float, frame_dt: float) -> void:
	for i in roundi(seconds / frame_dt):
		clock.advance(frame_dt)


func _check_tick_rate_follows_simulated_time() -> void:
	print("tick rate:")
	var lan := ServerClock.new(ServerClock.LAN_HZ)
	_run_seconds(lan, 1.0, 1.0 / 60.0)
	_expect(lan.tick == SECOND_IN_STEPS_60, "60 Hz clock, 60 physics steps: %d ticks" % lan.tick)
	var server := ServerClock.new(30)
	_run_seconds(server, 1.0, 1.0 / 60.0)
	_expect(server.tick == 30, "30 Hz clock over 60 physics steps of 1/60 s: %d ticks" % server.tick)
	var fast_frames := ServerClock.new(30)
	_run_seconds(fast_frames, 1.0, 1.0 / 240.0)
	_expect(fast_frames.tick == 30, "30 Hz clock fed at 240 fps: %d ticks (independent of frame rate)" % fast_frames.tick)
	_expect(server.dropped_ticks == 0 and server.catchup_steps_max == 1, "steady state drops nothing, one tick per advance")


func _check_stall_is_capped_and_counted() -> void:
	print("stall:")
	var clock := ServerClock.new(30, 2)
	var ran := clock.advance(STALL_SECONDS)
	_expect(ran == 2, "a 100 ms stall at 30 Hz runs at most 2 catch-up ticks (ran %d)" % ran)
	_expect(clock.tick == 2 and clock.dropped_ticks == 1, "tick %d, dropped %d (3 were due)" % [clock.tick, clock.dropped_ticks])
	_expect(clock.catchup_steps_max == 2, "catch-up maximum recorded: %d" % clock.catchup_steps_max)
	var big := ServerClock.new(30, 2)
	big.advance(5.0)
	_expect(big.tick == 2 and big.dropped_ticks == 148, "a 5 s stall does not spiral: tick %d, dropped %d" % [big.tick, big.dropped_ticks])


func _check_steady_state_after_stall() -> void:
	print("after a stall:")
	var clock := ServerClock.new(30, 2)
	clock.advance(STALL_SECONDS)
	var before := clock.tick
	_run_seconds(clock, 1.0, 1.0 / 60.0)
	_expect(clock.tick - before == 30, "the clock returns to 30 ticks per second (%d)" % (clock.tick - before))
	var seen: Array[int] = []
	clock.ticked.connect(func(t: int) -> void: seen.append(t))
	_run_seconds(clock, 0.2, 1.0 / 60.0)
	var contiguous := seen.size() == 6
	for i in range(1, seen.size()):
		contiguous = contiguous and seen[i] == seen[i - 1] + 1
	_expect(contiguous, "ticked is emitted once per tick with consecutive numbers %s" % [seen])


func _check_intervals_and_time() -> void:
	print("snapshot timing from the tick number:")
	_expect(ServerClock.make_interval(60, 20.0) == 3, "LAN: 20 Hz snapshots every 3rd of 60 ticks")
	_expect(ServerClock.make_interval(30, 20.0) == 2, "dedicated 30 Hz: every 2nd tick (15 Hz)")
	_expect(ServerClock.make_interval(30, 100.0) == 1, "never less than every tick")
	var clock := ServerClock.new(30)
	_expect(clock.make_time_ms(30) == 1000 and clock.make_time_ms(1) == 33, "tick -> simulated milliseconds")
	ServerClock.configure_dedicated(30, 2)
	_expect(Engine.physics_ticks_per_second == 30 and Engine.max_physics_steps_per_frame == 2,
		"configure_dedicated sets the engine's physics rate and catch-up cap")
	Engine.physics_ticks_per_second = 60
	Engine.max_physics_steps_per_frame = 8
	Engine.max_fps = 0
	ServerClock.dedicated_hz = ServerClock.DEFAULT_HZ


func _check_percentiles() -> void:
	print("metrics helpers:")
	var values := PackedFloat32Array()
	for i in 100:
		values.append(float(i + 1))
	_expect(is_equal_approx(ServerMetrics.make_percentile(values, 0.5), 50.0), "p50 of 1..100 is 50")
	_expect(is_equal_approx(ServerMetrics.make_percentile(values, 0.99), 99.0), "p99 of 1..100 is 99")
	_expect(is_equal_approx(ServerMetrics.make_percentile(values, 1.0), 100.0), "max of 1..100 is 100")
	_expect(ServerMetrics.make_percentile(PackedFloat32Array(), 0.5) == 0.0, "empty series gives 0")
	_expect(is_equal_approx(ServerMetrics.make_per_client_kBps(20000.0, 4, 5.0), 1.0), "20 kB over 5 s to 4 clients is 1 kB/s each")


func _check_report_line() -> void:
	var line := ServerMetrics.make_report_line({"tick_ms_p50": 1.0, "tick_ms_p95": 2.0, "tick_ms_p99": 3.0, "tick_ms_max": 4.0,
		"over_budget": 0, "catchup_steps_max": 1, "ticks_per_s": 30.0, "entities": 5, "humans": 1, "bots": 4, "far_lod": 0, "asleep": 0,
		"clients": 1, "out_kBps_per_client": 2.5, "in_kBps_per_client": 0.1, "static_mb": 100.0}, "BENCH")
	_expect(line.begins_with("BENCH tick_ms p50=1.00") and "bots=4" in line, "the report line is key=value text: %s" % line)

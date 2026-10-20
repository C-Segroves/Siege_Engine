extends Node
## Server load benchmark (docs/DEDICATED_SERVER_SCALING.md section 8): a real Battle hosted over loopback ENet with
## synthetic humans connected and bots running, timed by ServerMetrics. Varuna's Fall when the Tribes 2 pack is
## installed, else a fallback versus map. Stages (humans + bots): s8 = 8+24, s24 = 24+80, s64 = 64+200.
##   godot --headless --audio-driver Dummy --path game res://tests/server_load_bench.tscn -- [options]
##   --stages=s8,s24,s64   which stages to run (default: all); each stage runs in a fresh child process
##   --baseline            report the numbers and the misses but exit 0 (record today's state)
##   --map=auto|fallback   auto = Varuna when installed; fallback forces the fallback map
##   --seconds=20          measured seconds per stage      --warmup=8   settle seconds before measuring
##   --no-cheap-step       the far soldiers use move_and_slide (InfantryCheapStep off: the before of section 8.5.3)
##   --tick-hz=30          server tick rate                 --port=47790
## Prints "BENCH <stage> ..." lines (parsable key=value text) and "server_load_bench: PASS|MISS (n)"; exit code 1
## when a stage missed a target (never in --baseline), 2 when a stage did not run to the end.
## The synthetic humans are raw loopback ENet connections (server_bench_clients.gd): the bench measures the
## server's tick and the bytes it sends them; their input is written to their soldiers on the server side, so the
## inbound rate it reports is only ENet's own traffic.

const WorldBuilder := preload("res://tests/server_bench_world.gd")
const Clients := preload("res://tests/server_bench_clients.gd")
const Pilots := preload("res://tests/server_bench_pilots.gd")
const Probe := preload("res://tests/server_tick_probe.gd")

const STAGES := {"s8": {"humans": 8, "bots": 24}, "s24": {"humans": 24, "bots": 80}, "s64": {"humans": 64, "bots": 200}}
## Targets at every stage (docs section 8): the same budget, a smaller stage should have more room.
const TARGET_P50_MS := 12.0
const TARGET_P99_MS := 25.0
const TARGET_CATCHUP_STEPS := 2
const TARGET_OUT_KBPS := 60.0
const TARGET_IN_KBPS := 4.0
const TARGET_STATIC_MB := 2048.0
const MIN_BOT_FRACTION := 0.9
const CONNECT_SECONDS := 30.0
const SETTLE_SECONDS := 4.0
const STAGE_TIMEOUT_SECONDS := 420.0
const EXIT_MISS := 1
const EXIT_CRASH := 2
const LINE_PREFIX := "BENCH"

var _stage := ""
var _baseline := false
var _metrics: ServerMetrics
var _map := "auto"
var _seconds := 20.0
var _warmup := 8.0
var _tick_hz := ServerClock.DEFAULT_HZ
var _port := 47790
var _stages: Array = STAGES.keys()
var _probe := false
var _clients := Clients.new()
var _world := WorldBuilder.new()
var _battle: Battle


func _ready() -> void:
	_read_args(OS.get_cmdline_user_args())
	if _stage == "":
		_run_stages.call_deferred()
	else:
		get_tree().create_timer(STAGE_TIMEOUT_SECONDS, true, true).timeout.connect(func() -> void:
			print("%s %s TIMEOUT" % [LINE_PREFIX, _stage])
			get_tree().quit(EXIT_CRASH))
		_run_stage.call_deferred()


func _read_args(args: PackedStringArray) -> void:
	for a in args:
		var kv := a.trim_prefix("--").split("=", true, 1)
		var value := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"stage": _stage = value
			"stages": _stages = Array(value.split(",", false))
			"baseline": _baseline = true
			"probe": _probe = true
			"no-cheap-step": InfantryCheapStep.enabled = false
			"map": _map = value
			"seconds": _seconds = float(value)
			"warmup": _warmup = float(value)
			"tick-hz": _tick_hz = int(value)
			"port": _port = int(value)


# ------------------------------------------------------------------ all stages (parent process)

func _run_stages() -> void:
	var worst := 0
	var missed := 0
	for stage in _stages:
		if not STAGES.has(stage):
			print("%s unknown stage '%s' (known: %s)" % [LINE_PREFIX, stage, ", ".join(STAGES.keys())])
			worst = maxi(worst, EXIT_CRASH)
			continue
		var code := _run_child_stage(str(stage))
		missed += 1 if code != 0 else 0
		worst = maxi(worst, code)
	var verdict := "PASS" if worst == 0 else "MISS (%d of %d stages)" % [missed, _stages.size()]
	print("server_load_bench: %s" % ("BASELINE recorded, %s" % verdict if _baseline else verdict))
	get_tree().quit(0 if _baseline else worst)


## Runs one stage in its own Godot process (a clean server each time) and echoes its BENCH lines.
func _run_child_stage(stage: String) -> int:
	var args := ["--headless", "--audio-driver", "Dummy", "--path", ProjectSettings.globalize_path("res://"),
		"res://tests/server_load_bench.tscn", "--", "--stage=" + stage, "--map=" + _map, "--seconds=%s" % _seconds,
		"--warmup=%s" % _warmup, "--tick-hz=%d" % _tick_hz, "--port=%d" % _port]
	if _baseline:
		args.append("--baseline")
	if _probe:
		args.append("--probe")
	if not InfantryCheapStep.enabled:
		args.append("--no-cheap-step")
	var output := []
	var code := OS.execute(OS.get_executable_path(), args, output, true)
	for line in "\n".join(output).split("\n"):
		if line.begins_with(LINE_PREFIX) or line.begins_with("PROBE") or line.contains("SCRIPT ERROR"):
			print(line.strip_edges())
		if line.begins_with(LINE_PREFIX) and line.contains(" MISS:"):
			code = maxi(code, EXIT_MISS)   # a baseline stage exits 0 but still reports its misses
	if code != 0 and code != EXIT_MISS:
		print("%s %s did not run to the end (exit %d)" % [LINE_PREFIX, stage, code])
	return code


# ------------------------------------------------------------------ one stage (child process)

func _run_stage() -> void:
	ServerProfile.set_collision_only(true)   # the real server does this first (DedicatedServer.start)
	var humans_wanted := int(STAGES[_stage].humans)
	var bots_wanted := int(STAGES[_stage].bots)
	var kind: String = WorldBuilder.make_kind(_map)
	ServerClock.configure_dedicated(_tick_hz, ServerClock.DEFAULT_MAX_CATCHUP_STEPS)
	Net.player_name = "Bench server"
	Net.max_players = clampi(humans_wanted, 1, Net.MAX_PLAYERS)
	if Net.host(_port, Net.TRANSPORT_ENET, true, "127.0.0.1") != OK:
		_finish_crashed("cannot host on port %d" % _port)
		return
	var peers := await _connect_humans(mini(humans_wanted, Net.max_players))
	await _start_battle(kind, peers, bots_wanted)
	await _warm_up(peers, bots_wanted)
	if _probe:
		await Probe.new(get_tree(), _battle).run()
	var report := await _measure()
	report["clients_alive"] = _clients.make_connected_ids().size()
	_finish(report, humans_wanted, peers.size(), bots_wanted, kind)


func _connect_humans(count: int) -> Array:
	_clients.open(_port, count)
	var t0 := Time.get_ticks_msec()
	while not _is_every_client_known(count) and Time.get_ticks_msec() - t0 < CONNECT_SECONDS * 1000.0:
		await get_tree().process_frame
	return _clients.make_connected_ids().filter(func(id: int) -> bool: return multiplayer.get_peers().has(id))


## Whether `count` clients are connected at the ENet level and the server's multiplayer layer has registered them
## (it takes a few polls to accept a burst of connections).
func _is_every_client_known(count: int) -> bool:
	return _clients.make_connected_ids().size() >= count and multiplayer.get_peers().size() >= count


func _start_battle(kind: String, peers: Array, bots: int) -> void:
	Net.game_starting.connect(_on_game_starting)
	Net.start_game(_world.make_config(kind, peers, bots))
	for i in 3:
		await get_tree().process_frame


func _on_game_starting(config: Dictionary) -> void:
	_battle = load("res://games/es1/battle.tscn").instantiate()
	_battle.set("config", config)
	get_tree().root.add_child(_battle)


func _warm_up(peers: Array, bots: int) -> void:
	_metrics = ServerMetrics.new(_battle)   # from the start, as on the real server: the snapshot governor reads it
	_metrics.budget_ms = ServerClock.MILLISECONDS / float(_tick_hz)
	_battle.add_child(_metrics)
	var pilots := Pilots.new(_battle, peers)
	_battle.add_child(pilots)
	await _wait_polling(_warmup)
	_world.build_anchors(_battle)
	_world.apply_human_positions(_battle, pilots.make_humans())
	await _world.apply_bots(_battle, bots, get_tree())
	await _wait_polling(SETTLE_SECONDS)


func _measure() -> Dictionary:
	var metrics := _metrics
	await get_tree().process_frame
	metrics.reset_window()
	var sync: BattleNetSync = _battle.get_node_or_null("NetSync")
	if sync != null and sync.stream != null:
		sync.stream.keep_costs = true
	_clients.reset_received()
	await _wait_polling(_seconds)
	var report := metrics.make_report()
	report["client_recv_kBps"] = ServerMetrics.make_per_client_kBps(_clients.make_received_bytes(), int(report.clients), float(report.seconds))
	return report


func _wait_polling(seconds: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		await get_tree().process_frame


# ------------------------------------------------------------------ verdict

## The targets the stage missed, as short sentences (empty = all met).
static func make_misses(report: Dictionary, humans_wanted: int, humans_connected: int, bots_wanted: int, battle_over: bool) -> Array:
	var misses := []
	if humans_connected < humans_wanted:
		misses.append("only %d of %d humans connected" % [humans_connected, humans_wanted])
	if int(report.clients_alive) < humans_connected:
		misses.append("%d of %d clients were dropped" % [humans_connected - int(report.clients_alive), humans_connected])
	if int(report.bots) < int(float(bots_wanted) * MIN_BOT_FRACTION):
		misses.append("only %d of %d bots" % [int(report.bots), bots_wanted])
	if battle_over:
		misses.append("the match ended during the run")
	_append_limit(misses, "tick p50 ms", float(report.tick_ms_p50), TARGET_P50_MS)
	_append_limit(misses, "tick p99 ms", float(report.tick_ms_p99), TARGET_P99_MS)
	_append_limit(misses, "catch-up steps", float(report.catchup_steps_max), float(TARGET_CATCHUP_STEPS))
	_append_limit(misses, "out kB/s per client", float(report.out_kBps_per_client), TARGET_OUT_KBPS)
	_append_limit(misses, "in kB/s per client", float(report.in_kBps_per_client), TARGET_IN_KBPS)
	_append_limit(misses, "static MB", float(report.static_mb), TARGET_STATIC_MB)
	if int(report.over_budget) > 0:
		misses.append("%d ticks over the tick budget" % int(report.over_budget))
	return misses


static func _append_limit(misses: Array, label: String, value: float, limit: float) -> void:
	if value > limit:
		misses.append("%s %.2f > %.2f" % [label, value, limit])


func _finish(report: Dictionary, humans_wanted: int, humans_connected: int, bots_wanted: int, kind: String) -> void:
	var tag := "%s %s %dh+%db" % [LINE_PREFIX, _stage, humans_wanted, bots_wanted]
	print(ServerMetrics.make_report_line(report, "%s map=%s" % [tag, kind]))
	print("%s %s measured %.0f s, %d ticks, tick_hz=%d, client_side_recv_kBps=%.1f" % [LINE_PREFIX, _stage, report.seconds,
		report.ticks, _tick_hz, report.client_recv_kBps])
	print(_make_stream_line())
	var misses := make_misses(report, humans_wanted, humans_connected, bots_wanted, _battle.is_over())
	if misses.is_empty():
		print("%s %s PASS" % [LINE_PREFIX, _stage])
	else:
		print("%s %s MISS: %s" % [LINE_PREFIX, _stage, "; ".join(misses)])
	_clients.close()
	get_tree().quit(EXIT_MISS if not misses.is_empty() and not _baseline else 0)


## What the snapshot stream did in this stage: the shared-record hit rate and the governor's state at the end.
func _make_stream_line() -> String:
	var sync: BattleNetSync = _battle.get_node_or_null("NetSync")
	if sync == null or sync.stream == null:
		return "%s %s stream: none" % [LINE_PREFIX, _stage]
	var stream: BattleSnapshotStream = sync.stream
	var costs := stream.costs_ms
	var n := maxi(costs.size(), 1)
	var phases := ""
	for k in stream.phase_ms:
		phases += " %s=%.1f" % [k, stream.phase_ms[k] / n]
	print("%s %s stream cost ms/snapshot: p50=%.1f p99=%.1f max=%.1f mean phases:%s" % [LINE_PREFIX, _stage,
		ServerMetrics.make_percentile(costs, 0.5), ServerMetrics.make_percentile(costs, 0.99), ServerMetrics.make_percentile(costs, 1.0), phases])
	var total := maxi(stream.shared_built + stream.shared_reused, 1)
	return "%s %s stream: records shared %.0f%% (built %d, reused %d), governor level %d (load %.2f, served %d of %d clients)" % [LINE_PREFIX,
		_stage, 100.0 * stream.shared_reused / total, stream.shared_built, stream.shared_reused, stream.governor.level,
		stream.governor.load_share, stream.clients_served, multiplayer.get_peers().size()]


func _finish_crashed(why: String) -> void:
	print("%s %s FAILED: %s" % [LINE_PREFIX, _stage, why])
	get_tree().quit(EXIT_CRASH)

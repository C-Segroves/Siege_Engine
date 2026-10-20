class_name ServerMetrics
extends Node
## What a dedicated server costs (docs/DEDICATED_SERVER_SCALING.md section 8): how long one simulation tick takes
## (p50 / p95 / p99 / max), the bytes sent and received per client per second, the entity counts and the memory.
## It is a child of the Battle. A head and a tail node (process priorities at both ends of the frame) time
## everything the frame does between them: every _physics_process, the physics step itself and every _process.
## The time of a frame without a physics step is carried into the next ticking frame, and a frame that ran several
## catch-up ticks is split between them, so a sample is "milliseconds of work per tick".
## Windows: make_report() describes the samples since the last reset_window(); with `report_seconds` > 0 the node
## prints "SERVER STATS ..." (make_report_line) every that many seconds and starts a new window.

const HEAD_PRIORITY := -10000
const TAIL_PRIORITY := 10000
const MICROSECONDS_PER_MS := 1000.0
const BYTES_PER_KB := 1000.0
const BYTES_PER_MB := 1048576.0
const P50 := 0.5
const P95 := 0.95
const P99 := 0.99
const RECENT_SMOOTHING := 0.15

var battle: Battle
var report_seconds := 0.0
## Tick budget in ms (1000 / the clock's rate); ticks above it are counted as over budget.
var budget_ms := 33.3

## The smoothed work of a tick in ms, readable at any moment (the snapshot governor's input).
var recent_tick_ms := 0.0

var _tick_ms := PackedFloat32Array()
var _over_budget := 0
var _steps_max := 0
var _carry_ms := 0.0
var _frame_start_usec := 0
var _frame_steps := 0
var _last_physics_frame := 0
var _bytes_out := 0.0
var _bytes_in := 0.0
var _window_start_msec := 0
var _report_left := 0.0
var _tail: Node


func _init(p_battle: Battle, p_report_seconds := 0.0) -> void:
	battle = p_battle
	report_seconds = p_report_seconds
	name = "ServerMetrics"
	process_priority = HEAD_PRIORITY
	process_physics_priority = HEAD_PRIORITY


func _ready() -> void:
	_tail = FrameTail.new(self)
	add_child(_tail)
	_last_physics_frame = Engine.get_physics_frames()
	reset_window()


# ------------------------------------------------------------------ sampling

func _physics_process(_delta: float) -> void:
	_mark_frame_start()


func _process(delta: float) -> void:
	_mark_frame_start()
	_report_left -= delta


func _mark_frame_start() -> void:
	if _frame_start_usec == 0:
		_frame_start_usec = Time.get_ticks_usec()


## Called by the tail node after the last _process of a frame.
func apply_frame_end() -> void:
	var work_ms := float(Time.get_ticks_usec() - _frame_start_usec) / MICROSECONDS_PER_MS
	_frame_start_usec = 0
	var frames := Engine.get_physics_frames()
	_frame_steps = frames - _last_physics_frame
	_last_physics_frame = frames
	_apply_sample(work_ms)
	_apply_network_counters()
	if report_seconds > 0.0 and _report_left <= 0.0:
		print(make_report_line(make_report()))
		reset_window()


func _apply_sample(work_ms: float) -> void:
	_carry_ms += work_ms
	if _frame_steps <= 0:
		return
	var per_tick := _carry_ms / float(_frame_steps)
	recent_tick_ms = lerpf(recent_tick_ms, per_tick, RECENT_SMOOTHING)
	for i in _frame_steps:
		_tick_ms.append(per_tick)
	_over_budget += _frame_steps if per_tick > budget_ms else 0
	_steps_max = maxi(_steps_max, _frame_steps)
	_carry_ms = 0.0


func _apply_network_counters() -> void:
	var host := _find_enet_host()
	if host == null:
		return
	_bytes_out += host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
	_bytes_in += host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)


func _find_enet_host() -> ENetConnection:
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	return peer.host if peer != null else null


func reset_window() -> void:
	_tick_ms = PackedFloat32Array()
	_over_budget = 0
	_steps_max = 0
	_carry_ms = 0.0
	_bytes_out = 0.0
	_bytes_in = 0.0
	_report_left = report_seconds
	_window_start_msec = Time.get_ticks_msec()


# ------------------------------------------------------------------ reports

## The window so far: {ticks, ticks_per_s (30 when the server keeps its rate), tick_ms_p50/p95/p99/max, over_budget, catchup_steps_max, clients, out_kBps_per_client,
## in_kBps_per_client, entities, humans, bots, far_lod, asleep, static_mb, seconds}.
func make_report() -> Dictionary:
	var seconds := maxf(float(Time.get_ticks_msec() - _window_start_msec) / 1000.0, 0.001)
	var clients := multiplayer.get_peers().size() if multiplayer.multiplayer_peer != null else 0
	var r := {"ticks": _tick_ms.size(), "ticks_per_s": float(_tick_ms.size()) / seconds, "seconds": seconds, "over_budget": _over_budget,
		"catchup_steps_max": _steps_max, "clients": clients,
		"out_kBps_per_client": make_per_client_kBps(_bytes_out, clients, seconds),
		"in_kBps_per_client": make_per_client_kBps(_bytes_in, clients, seconds),
		"static_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / BYTES_PER_MB}
	r.merge(make_tick_stats(_tick_ms))
	r.merge(make_entity_counts(battle))
	return r


static func make_tick_stats(samples_ms: PackedFloat32Array) -> Dictionary:
	return {"tick_ms_p50": make_percentile(samples_ms, P50), "tick_ms_p95": make_percentile(samples_ms, P95),
		"tick_ms_p99": make_percentile(samples_ms, P99), "tick_ms_max": make_percentile(samples_ms, 1.0)}


## The value at quantile `q` (0..1) of `values` (nearest rank); 0 when empty.
static func make_percentile(values: PackedFloat32Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(ceili(q * sorted.size()) - 1, 0, sorted.size() - 1)]


static func make_per_client_kBps(bytes: float, clients: int, seconds: float) -> float:
	return bytes / BYTES_PER_KB / seconds / float(maxi(clients, 1))


## {entities, humans, bots, far_lod, asleep} of the battle's vehicles and soldiers.
static func make_entity_counts(p_battle: Battle) -> Dictionary:
	var humans := 0
	var bots := 0
	var far := 0
	for h in p_battle.vehicles.values():
		var herc := h as Herc
		if herc == null:
			continue
		if herc.has_meta(InfantryBots.META_AI) or InfantryBots.is_bot(herc.owner_peer):
			bots += 1
		elif herc.owner_peer > 1 or herc == p_battle.player:
			humans += 1
		far += 1 if herc is Infantry and (herc as Infantry).far_lod else 0
	var asleep := p_battle.bot_sleep.sleeping_count if p_battle.bot_sleep != null else 0
	return {"entities": p_battle.vehicles.size(), "humans": humans, "bots": bots, "far_lod": far, "asleep": asleep}


## One line, "SERVER STATS" or "BENCH"-style: key=value pairs a script can parse.
static func make_report_line(r: Dictionary, prefix := "SERVER STATS") -> String:
	return ("%s tick_ms p50=%.2f p95=%.2f p99=%.2f max=%.2f over_budget=%d catchup_max=%d ticks_per_s=%.1f | entities=%d humans=%d bots=%d "
		+ "far_lod=%d asleep=%d | clients=%d out_kBps_per_client=%.1f in_kBps_per_client=%.2f | static_mb=%.0f") % [
		prefix, r.tick_ms_p50, r.tick_ms_p95, r.tick_ms_p99, r.tick_ms_max, r.over_budget, r.catchup_steps_max,
		r.ticks_per_s, r.entities, r.humans, r.bots, r.far_lod, r.asleep, r.clients, r.out_kBps_per_client, r.in_kBps_per_client, r.static_mb]


## Ends the frame: its _process has the last priority.
class FrameTail extends Node:
	var _metrics: ServerMetrics

	func _init(p_metrics: ServerMetrics) -> void:
		_metrics = p_metrics
		name = "FrameTail"
		process_priority = TAIL_PRIORITY

	func _process(_delta: float) -> void:
		_metrics.apply_frame_end()

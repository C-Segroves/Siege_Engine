extends Node3D
## Lag compensation (docs/DEDICATED_SERVER_SCALING.md chunk J): the server keeps about a second of hit capsules per
## tick (HitHistory, fed from the EntityTable) and tests a human's hitscan shot against the units as they stood
## when his screen showed them (round trip plus interpolation delay, capped at 250 ms).
##   godot --headless --audio-driver Dummy --path game res://tests/lag_comp_check.tscn
## Prints "lag_comp_check: OK|FAILED (<n> failures)"; exit code 0 / 1.

const TICK_HZ := 30
const TARGET_SPEED := 8.0
const TARGET_START := Vector3(10.0, 0.0, -40.0)
const SHOOTER_ID := 1
const TARGET_ID := 2
const SIMULATED_TICKS := 60
const RTT_MS := 150.0
const FAR_RTT_MS := 600.0
const MISS_NOTE := "miss"

var _failures := 0
var _table := EntityTable.new()
var _history := HitHistory.new(TICK_HZ)
var _target: Dummy
var _shooter: Dummy
var _trace := {}   # tick -> target position


## A unit for the entity table: a position and a capsule.
class Dummy extends Node3D:
	var alive := true
	var team := 0
	var integrity := 1.0
	var velocity := Vector3.ZERO

	func make_hit_capsule() -> Vector2:
		return Vector2(0.6, 2.0)


func _ready() -> void:
	_run_world()
	_check_hit_at_view_time()
	_check_rewind_cap()
	_check_history_window()
	await _check_world_blocks_rewound_hit()
	_check_latency_measurement()
	print("lag_comp_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


## Two seconds of ticks: the target runs along +x at 8 m/s, the shooter stands still; every tick is recorded.
func _run_world() -> void:
	_shooter = Dummy.new()
	_target = Dummy.new()
	add_child(_shooter)
	add_child(_target)
	_shooter.position = Vector3.ZERO
	_target.position = TARGET_START
	_table.register(SHOOTER_ID, _shooter)
	_table.register(TARGET_ID, _target)
	for tick in range(1, SIMULATED_TICKS + 1):
		_target.position = TARGET_START + Vector3(TARGET_SPEED * tick / TICK_HZ, 0.0, 0.0)
		_table.update_from_nodes(tick)
		_history.record(_table, tick)
		_trace[tick] = _target.position


## The target's position `ms` before `tick` (what a screen that far behind shows).
func _seen_position(tick: int, ms: float) -> Vector3:
	return TARGET_START + Vector3(TARGET_SPEED * (float(tick) - ms * TICK_HZ / 1000.0) / TICK_HZ, 0.0, 0.0)


## A shot from the shooter's eye straight at `aim`; the HitHistory ray against the units at `view_tick`.
func _shoot(aim: Vector3, view_tick: float) -> Dictionary:
	var from := _shooter.position + Vector3.UP * 1.5
	var dir := (aim + Vector3.UP * 1.0 - from).normalized()
	return _history.find_hit(from, dir, 200.0, view_tick, SHOOTER_ID)


func _check_hit_at_view_time() -> void:
	print("a moving target hit where the client saw it, 150 ms round trip:")
	var now := SIMULATED_TICKS
	var rewind_ms := LagCompensation.make_rewind_ms(RTT_MS)
	var aim := _seen_position(now, rewind_ms)
	_expect(absf(rewind_ms - (RTT_MS + LagCompensation.DEFAULT_INTERP_DELAY_MS)) < 0.01, "rewind = rtt + interpolation delay (%.0f ms)" % rewind_ms)
	var compensated := _shoot(aim, _history.make_view_tick(now, rewind_ms))
	_expect(not compensated.is_empty() and int(compensated.id) == TARGET_ID, "registers against the rewound world (%s)" % str(compensated.get("id", MISS_NOTE)))
	var uncompensated := _shoot(aim, float(now))
	_expect(uncompensated.is_empty(), "the same shot misses against the world as it is now (target moved %.1f m)" % (TARGET_SPEED * rewind_ms / 1000.0))
	var interpolated := _shoot(aim, _history.make_view_tick(now, rewind_ms + 1000.0 / TICK_HZ * 0.5))
	_expect(interpolated.is_empty() or int(interpolated.id) == TARGET_ID, "a view time between two ticks is interpolated, not an error")
	var capsule := _history.make_capsule(TARGET_ID, float(now) - 4.5)
	var expected := _trace[now - 5].lerp(_trace[now - 4], 0.5) as Vector3
	_expect(not capsule.is_empty() and (capsule.position as Vector3).distance_to(expected) < 0.001, "the capsule between ticks 55 and 56 is their midpoint")
	var own := _history.find_hit(Vector3(0.0, 1.5, 0.0), Vector3(0.0, 0.0, 1.0), 50.0, float(now), SHOOTER_ID)
	_expect(own.is_empty(), "a shooter is never hit by his own shot")


func _check_rewind_cap() -> void:
	print("a latency beyond the cap is clamped:")
	var now := SIMULATED_TICKS
	var rewind_ms := LagCompensation.make_rewind_ms(FAR_RTT_MS)
	_expect(rewind_ms == LagCompensation.MAX_REWIND_MS, "%.0f ms of round trip rewinds %.0f ms, not more" % [FAR_RTT_MS, rewind_ms])
	var view := _history.make_view_tick(now, rewind_ms)
	_expect(is_equal_approx(view, float(now) - LagCompensation.MAX_REWIND_MS * TICK_HZ / 1000.0), "the view tick is 250 ms back (%.1f)" % view)
	var aim_true_view := _seen_position(now, FAR_RTT_MS + LagCompensation.DEFAULT_INTERP_DELAY_MS)
	_expect(_shoot(aim_true_view, view).is_empty(), "a shot aimed at where the slow client really saw him misses (clamped)")
	var aim_capped := _seen_position(now, LagCompensation.MAX_REWIND_MS)
	var capped := _shoot(aim_capped, view)
	_expect(not capped.is_empty() and int(capped.id) == TARGET_ID, "a shot at his place 250 ms ago still hits")
	_expect(_history.make_view_tick(now, 5000.0) == float(_history.oldest_tick()), "asking further back than the history clamps to its oldest tick")


func _check_history_window() -> void:
	print("history window:")
	var kept := _history.size()
	_expect(kept == _history.capacity and kept <= TICK_HZ + 3, "about one second of ticks is kept (%d of %d)" % [kept, SIMULATED_TICKS])
	_expect(_history.newest_tick() == SIMULATED_TICKS and _history.oldest_tick() == SIMULATED_TICKS - kept + 1, "the oldest ticks fell off")
	_table.flags[_table.make_row(TARGET_ID)] = 0   # not alive: it leaves the next frame
	_history.record(_table, SIMULATED_TICKS + 1)
	_expect(_history.make_capsule(TARGET_ID, float(SIMULATED_TICKS + 1)).is_empty(), "a dead unit is not in the history")


func _check_world_blocks_rewound_hit() -> void:
	print("walls stay where they are:")
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 10.0, 1.0)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(0.0, 5.0, -20.0)
	add_child(wall)
	await get_tree().physics_frame
	var history := HitHistory.new(TICK_HZ)
	var ids := PackedInt32Array([TARGET_ID])
	history.record_capsules(ids, PackedFloat32Array([0.0, 0.0, -40.0, 0.0, 0.6, 2.0]), 1)
	history.record_capsules(ids, PackedFloat32Array([0.0, 0.0, -40.0, 0.0, 0.6, 2.0]), 2)
	var rewind := {"history": history, "view_tick": 1.0, "ignore_id": SHOOTER_ID, "unit_of": func(_id: int) -> Node3D: return _target}
	var from := Vector3(0.0, 1.0, 0.0)
	var behind_wall := LagCompensation.cast_ray(self, from, Vector3(0.0, 0.0, -1.0), 100.0, rewind, [])
	_expect(behind_wall.get("collider") == wall, "a target behind a wall is not hit through it")
	wall.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var open := LagCompensation.cast_ray(self, from, Vector3(0.0, 0.0, -1.0), 100.0, rewind, [])
	_expect(open.get("collider") == _target and bool(open.get("rewound", false)), "without the wall the rewound target is hit")
	var plain := LagCompensation.cast_ray(self, from, Vector3(0.0, 0.0, -1.0), 100.0, {}, [])
	_expect(plain.is_empty(), "no rewind: the plain ray of today (nothing there)")


func _check_latency_measurement() -> void:
	print("round trip measured over any transport:")
	var latency := PeerLatency.new()
	latency.note_sent(10, 1000)
	latency.note_sent(11, 1033)
	latency.note_echo(10, 1150)
	_expect(is_equal_approx(latency.rtt_ms, 150.0), "the echo of tick 10 after 150 ms (%.0f ms)" % latency.rtt_ms)
	latency.note_echo(11, 1033 + 170)
	_expect(latency.rtt_ms > 150.0 and latency.rtt_ms < 170.0, "later samples are smoothed (%.1f ms)" % latency.rtt_ms)
	latency.note_echo(99, 5000)
	_expect(latency.samples == 2, "an echo of a tick never sent is ignored")

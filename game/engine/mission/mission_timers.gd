class_name MissionTimers
extends RefCounted
## The timers of a mission by id. apply_tick returns the payloads of the timers that ran out, in the order they were added.

## Fast-forward steps (apply_advance): small enough that a repeating timer runs out as often as it would have.
const ADVANCE_STEP := 0.25

var _timers := {}                # id -> MissionTimer, insertion ordered


## Adds (or replaces) timer `id`.
func apply_add(id: Variant, timer: MissionTimer) -> void:
	_timers[id] = timer


func apply_cancel(id: Variant) -> void:
	_timers.erase(id)


func apply_clear() -> void:
	_timers.clear()


## A timer is pending until it ran out (a repeating one always is) or was cancelled.
func is_pending(id: Variant) -> bool:
	return _timers.has(id) and not (_timers[id] as MissionTimer).is_finished()


## The ids of the timers held, in the order they were added.
func make_ids() -> Array:
	return _timers.keys()


func get_timer(id: Variant) -> MissionTimer:
	return _timers.get(id)


## Seconds left on timer `id` (0 for none).
func make_time_left(id: Variant) -> float:
	return (_timers[id] as MissionTimer).make_time_left() if _timers.has(id) else 0.0


func apply_tick(dt: float) -> Array:
	var fired := []
	for id in _timers.keys():
		var t: MissionTimer = _timers[id]
		if t.apply_tick(dt):
			fired.append(t.payload)
		if t.is_finished():
			_timers.erase(id)
	return fired


## Fast-forwards `seconds` (a cut-scene skip) and returns every payload that ran out meanwhile.
func apply_advance(seconds: float) -> Array:
	var fired := []
	var left := seconds
	while left > 0.0:
		var step := minf(left, ADVANCE_STEP)
		fired.append_array(apply_tick(step))
		left -= step
	return fired

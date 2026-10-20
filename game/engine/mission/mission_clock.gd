class_name MissionClock
extends RefCounted
## Simulation time of a mission and its rules tick (the body of MissionRuntimeBase.make_rules_step).

## Seconds of simulation time since the mission started (advanced by apply_advance).
var elapsed := 0.0
var _until_tick := 0.0
var _pending := 0.0


## Adds `delta` to the elapsed time. Call once per physics step, before make_step.
func apply_advance(delta: float) -> void:
	elapsed += delta


## The rules tick: returns the simulation time since the last tick when one is due this step (a tick spans whole physics
## steps, so it is usually a bit more than `interval`; timers driven by it keep game time), else 0.
func make_step(delta: float, interval: float) -> float:
	_pending += delta
	_until_tick -= delta
	if _until_tick > 0.0:
		return 0.0
	_until_tick = maxf(_until_tick + interval, 0.0)
	var dt := _pending
	_pending = 0.0
	return dt

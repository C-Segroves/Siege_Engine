class_name MissionTimer
extends RefCounted
## One countdown. Three semantics the games use:
##   ONE_SHOT   runs out once after `seconds` (Starsiege schedule, Tribes schedules, Earthsiege 2 region countdowns)
##   REPEATING  runs out every `seconds` (respawns, task loops, reinforcement batches)
##   WHILE      accumulates only while `condition` holds and starts over when it breaks; runs out once per stretch
##              (the Aerial Assault script timers)
## An unarmed timer does not count (a countdown armed by a region). `payload` is whatever the owner wants back.

enum Mode { ONE_SHOT, REPEATING, WHILE }

var seconds := 0.0
var mode := Mode.ONE_SHOT
var payload: Variant = null
var armed := true
var condition := Callable()
var _elapsed := 0.0
var _done := false

static func make_timer(p_seconds: float, p_mode := Mode.ONE_SHOT, p_payload: Variant = null) -> MissionTimer:
	var t := MissionTimer.new()
	t.seconds = p_seconds
	t.mode = p_mode
	t.payload = p_payload
	return t

func is_finished() -> bool:
	return _done and mode == Mode.ONE_SHOT

func make_time_left() -> float:
	return maxf(seconds - _elapsed, 0.0)

## Starts the count (arming an armed timer changes nothing).
func apply_arm() -> void:
	armed = true

## Moves the timer on by `dt`; true when it runs out in this step.
func apply_tick(dt: float) -> bool:
	if not armed or is_finished():
		return false
	if mode == Mode.WHILE and condition.is_valid() and not bool(condition.call()):
		_elapsed = 0.0
		_done = false
		return false
	_elapsed += dt
	if _elapsed < seconds:
		return false
	return _run_out()

func _run_out() -> bool:
	if mode == Mode.REPEATING:
		_elapsed = fmod(_elapsed, maxf(seconds, 0.0001))
		return true
	if mode == Mode.WHILE and _done:
		return false
	_done = true
	return true

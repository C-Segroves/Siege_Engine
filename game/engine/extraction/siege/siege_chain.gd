class_name SiegeChain
extends RefCounted
## The hidden trigger chain of the Cybrid siege: the relays must be woken in `order` within `window_s` of the first one.
## A relay out of order, or the window running out, resets the chain quietly (nobody is told but the one who touched a
## plate). Pure logic over MissionTimers; CybridSiege tells the world.

enum Result { IGNORED, STEP, RESET, DONE }

const TIMER_WINDOW := "window"

signal timed_out

var order: Array = []
var window_s := 600.0
var progress := 0
var _timers := MissionTimers.new()


static func make(p_order: Array, p_window_s: float) -> SiegeChain:
	var c := SiegeChain.new()
	c.order = p_order.duplicate()
	c.window_s = p_window_s
	return c


## The ids of `ids` in a random order (the per-raid order).
static func make_shuffled(ids: Array, rng: RandomNumberGenerator) -> Array:
	var out := ids.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = out[i]
		out[i] = out[j]
		out[j] = t
	return out


func is_lit(relay_id: String) -> bool:
	return order.find(relay_id) >= 0 and order.find(relay_id) < progress


func is_running() -> bool:
	return progress > 0


func make_time_left() -> float:
	return _timers.make_time_left(TIMER_WINDOW)


## A player woke relay `relay_id`.
func apply_activate(relay_id: String) -> Result:
	if is_lit(relay_id):
		return Result.IGNORED
	if order[progress] != relay_id:
		apply_reset()
		return Result.RESET
	progress += 1
	if progress >= order.size():
		_timers.apply_cancel(TIMER_WINDOW)
		return Result.DONE
	if progress == 1:
		_timers.apply_add(TIMER_WINDOW, MissionTimer.make_timer(window_s, MissionTimer.Mode.ONE_SHOT, TIMER_WINDOW))
	return Result.STEP


func apply_reset() -> void:
	progress = 0
	_timers.apply_cancel(TIMER_WINDOW)


func apply_tick(dt: float) -> void:
	if _timers.apply_tick(dt).has(TIMER_WINDOW):
		apply_reset()
		timed_out.emit()

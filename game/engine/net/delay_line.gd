class_name DelayLine
extends RefCounted
## Holds Callables for a fixed time and releases them in order: the latency half of a network condition simulator
## (tests and experiments; a real connection supplies its own). Times are milliseconds on one clock the caller picks.

var delay_ms := 0
var _held: Array[Dictionary] = []   # {due: int, call: Callable}


func _init(p_delay_ms := 0) -> void:
	delay_ms = p_delay_ms


func is_active() -> bool:
	return delay_ms > 0


func count() -> int:
	return _held.size()


## Queues `call` to run `delay_ms` after `now_ms`.
func hold(now_ms: int, call: Callable) -> void:
	_held.append({"due": now_ms + delay_ms, "call": call})


## Runs everything due at `now_ms`, oldest first.
func release(now_ms: int) -> void:
	while not _held.is_empty() and int(_held[0].due) <= now_ms:
		var item: Dictionary = _held.pop_front()
		(item.call as Callable).call()

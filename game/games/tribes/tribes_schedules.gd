class_name TribesSchedules
extends RefCounted
## The script timers of a Tribes / Tribes 2 mission:
##   Tribes    schedule("code;", seconds)                       -> a code string run later
##   Tribes 2  schedule(ms, object, "function", args...)         -> a function call later
##             object.schedule(ms, "method", args...)            -> a method call later
## An event bound to an object is dropped when the object is gone by then (Torque cancels the schedules of a
## deleted object; object 0 = none). Each event has an id for cancel() / isEventPending().

const FIRST_EVENT_ID := 1

var _events := {}            # id -> {at, kind, code / name, args, object}
var _next_id := FIRST_EVENT_ID


func add_code(at: float, code: String) -> int:
	return _add({"at": at, "kind": "code", "code": code, "object": 0})


func add_call(at: float, object: int, function_name: String, args: Array) -> int:
	return _add({"at": at, "kind": "call", "name": function_name, "args": args, "object": object})


func add_method(at: float, object: int, method: String, args: Array) -> int:
	return _add({"at": at, "kind": "method", "name": method, "args": args, "object": object})


func _add(event: Dictionary) -> int:
	var id := _next_id
	_next_id += 1
	_events[id] = event
	return id


func cancel(id: int) -> void:
	_events.erase(id)


func is_pending(id: int) -> bool:
	return _events.has(id)


func time_left(id: int, now: float) -> float:
	return maxf(float(_events[id].at) - now, 0.0) if _events.has(id) else 0.0


func clear() -> void:
	_events.clear()


func count() -> int:
	return _events.size()


## The events due at `now`, earliest first (in the order they were made when due together); they are removed.
func take_due(now: float) -> Array:
	var due := []
	for id in _events:
		if float(_events[id].at) <= now:
			due.append(id)
	due.sort_custom(func(a: int, b: int) -> bool:
		return float(_events[a].at) < float(_events[b].at) or (_events[a].at == _events[b].at and a < b))
	var out := []
	for id in due:
		out.append(_events[id])
		_events.erase(id)
	return out

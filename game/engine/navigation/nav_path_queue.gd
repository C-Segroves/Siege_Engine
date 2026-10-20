class_name NavPathQueue
extends RefCounted
## The waiting path requests of BattleNavigation and the answers not yet collected. One request per asker (an
## asker's newer request replaces its older one in place, keeping its place in line), asked in arrival order.
## Answers are kept until the asker takes them or STALE_MSEC passes (a bot that died while its path was in flight).

const STALE_MSEC := 10000

var _waiting := {}   # asker id -> {asker, from, to, profile}
var _answers := {}   # asker id -> {path, msec}


## Queues a path from `from` to `to` for `asker` (an id: the asker's instance id), replacing its waiting request.
func apply_request(asker: int, from: Vector3, to: Vector3, profile: Dictionary) -> void:
	_waiting[asker] = {"asker": asker, "from": from, "to": to, "profile": profile}


func waiting_count() -> int:
	return _waiting.size()


func is_waiting(asker: int) -> bool:
	return _waiting.has(asker)


## Takes the oldest `most` waiting requests off the queue.
func take_requests(most: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for asker in _waiting.keys():
		if out.size() >= most:
			break
		out.append(_waiting[asker])
		_waiting.erase(asker)
	return out


## Puts a request that could not be asked yet back behind the others (unless the asker already sent a newer one).
func apply_requeue(request: Dictionary) -> void:
	if not _waiting.has(request.asker):
		_waiting[request.asker] = request


func apply_answer(asker: int, path: PackedVector3Array) -> void:
	_answers[asker] = {"path": path, "msec": Time.get_ticks_msec()}


func has_answer(asker: int) -> bool:
	return _answers.has(asker)


## The answer for `asker` ([] when none came; check has_answer first), removed from the queue.
func take_answer(asker: int) -> PackedVector3Array:
	var a: Dictionary = _answers.get(asker, {})
	_answers.erase(asker)
	return a.get("path", PackedVector3Array())


## Forgets the asker's waiting request and answer.
func apply_cancel(asker: int) -> void:
	_waiting.erase(asker)
	_answers.erase(asker)


func apply_stale_purge() -> void:
	var now := Time.get_ticks_msec()
	for asker in _answers.keys():
		if now - int(_answers[asker].msec) > STALE_MSEC:
			_answers.erase(asker)

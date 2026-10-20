class_name CallinCooldowns
extends RefCounted
## The host's call-in bookkeeping per player: the raid clock, each kind's cooldown, the shared cooldown and the uses so far
## (CallinChecks asks it for the facts of a request; cooldowns are times on this clock).

## Seconds since the raid began.
var clock := 0.0
var _until := {}    # peer -> {kind: clock}
var _shared := {}   # peer -> clock
var _used := {}     # peer -> {kind: n}


func apply_tick(delta: float) -> void:
	clock += delta


func make_cool_left(peer: int, kind: String) -> float:
	return float(_until.get(peer, {}).get(kind, 0.0)) - clock


func make_shared_left(peer: int) -> float:
	return float(_shared.get(peer, 0.0)) - clock


func make_used(peer: int, kind: String) -> int:
	return int(_used.get(peer, {}).get(kind, 0))


## The uses of every kind: {kind: n}.
func make_used_all(peer: int) -> Dictionary:
	return _used.get(peer, {}).duplicate()


func apply_use(peer: int, kind: String, config: Dictionary) -> void:
	if not _used.has(peer):
		_used[peer] = {}
		_until[peer] = {}
	_used[peer][kind] = make_used(peer, kind) + 1
	_until[peer][kind] = clock + float(CallinRules.rule(kind).get("cooldown_s", 0.0))
	_shared[peer] = clock + CallinRules.shared_cooldown(config)


## Takes back one use and the cooldown of a call-in that was cancelled.
func apply_unuse(peer: int, kind: String) -> void:
	if _used.has(peer):
		_used[peer][kind] = maxi(make_used(peer, kind) - 1, 0)
		_until[peer][kind] = 0.0
		_shared[peer] = 0.0


func apply_clear(peer: int) -> void:
	_until[peer] = {}
	_shared[peer] = 0.0

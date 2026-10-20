class_name AreaTrigger
extends RefCounted
## An area that tells when things enter it, stay in it and leave it. apply_scan(candidates) is called every rules tick with
## the things that could be inside (id -> position); it emits `entered` on the tick one arrives, `contact` on every tick
## one is inside (the entering tick too) and `left` on the tick one is gone or outside.

signal entered(id: Variant)
signal contact(id: Variant)
signal left(id: Variant)

var shape: AreaShape
## Callable(id) -> bool: only things it accepts count (a team, a vehicle type). Empty accepts all.
var filter := Callable()
## Entries the trigger tells in all (0 = unlimited): Vengeance triggers fire for a few entries only. A thing entering past
## the limit is told nothing, but it counts as inside, so its leaving is still told (Vengeance raises the exit message).
var max_enter := 0
## Disables the trigger after its first entry.
var one_shot := false
var _inside := {}
var _enter_count := 0
var _spent := false


func _init(p_shape: AreaShape) -> void:
	shape = p_shape


func is_occupied() -> bool:
	return not _inside.is_empty()


func is_spent() -> bool:
	return _spent


## Counts `id` as inside already, without an `entered` (a thing that starts inside, like the Tribes player in the
## mission area): only its leaving is told.
func apply_assume_inside(id: Variant) -> void:
	_inside[id] = true


func apply_scan(candidates: Dictionary) -> void:
	if _spent:
		return
	var now := {}
	for id in candidates:
		if shape.is_inside(candidates[id]) and (not filter.is_valid() or bool(filter.call(id))):
			now[id] = true
	for id in _inside.keys():
		if not now.has(id):
			left.emit(id)
	var previous := _inside
	_inside = {}
	for id in now:
		_apply_presence(id, previous.has(id))


func _apply_presence(id: Variant, was_inside: bool) -> void:
	if was_inside:
		_inside[id] = true
	else:
		if _spent:
			return
		if max_enter > 0 and _enter_count >= max_enter:
			_inside[id] = true
			return
		_enter_count += 1
		_inside[id] = true
		entered.emit(id)
		if one_shot:
			_spent = true
	contact.emit(id)

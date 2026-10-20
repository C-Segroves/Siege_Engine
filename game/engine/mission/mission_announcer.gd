class_name MissionAnnouncer
extends RefCounted
## The mission's radio: messages and voice prompts reach the sink one at a time, by one of three disciplines
## (the originals differ, the docs/MECHANICS_UNIFICATION.md inventory lists them):
##   REPLACE_WAITING  one waits behind the one playing; a newer waiting message replaces the older one (Aerial Assault)
##   FIFO             every message plays in turn; `first_delay` holds the very first one back (Earthsiege 2)
##   CUT              a new message cuts what plays (the timed end voices of the arena)
## In every discipline a voice with `interrupt` cuts the one playing and drops the waiting ones.

enum Discipline { REPLACE_WAITING, FIFO, CUT }

var discipline := Discipline.REPLACE_WAITING
var first_delay := 0.0
var _sink: MissionSink
var _waiting: Array[MissionMessage] = []
var _busy_left := 0.0
var _delay_left := 0.0
var _said_any := false


func _init(p_sink: MissionSink, p_discipline := Discipline.REPLACE_WAITING, p_first_delay := 0.0) -> void:
	_sink = p_sink
	discipline = p_discipline
	first_delay = p_first_delay


## Offers `message` to the radio.
func apply_say(message: MissionMessage) -> void:
	if not _said_any:
		_said_any = true
		_delay_left = first_delay
	if discipline == Discipline.CUT or (message.voice != null and message.voice.interrupt):
		_waiting.clear()
		_play(message)
	elif not is_busy() and _waiting.is_empty():
		_play(message)
	elif discipline == Discipline.REPLACE_WAITING:
		_waiting = [message]
	else:
		_waiting.append(message)


## Moves the radio on by `dt` seconds and plays the next waiting message once it is free.
func apply_tick(dt: float) -> void:
	_delay_left = maxf(_delay_left - dt, 0.0)
	_busy_left = maxf(_busy_left - dt, 0.0)
	if not _waiting.is_empty() and not is_busy():
		_play(_waiting.pop_front())


func is_busy() -> bool:
	return _busy_left > 0.0 or _delay_left > 0.0 or _sink.is_voice_playing()


func is_idle() -> bool:
	return _waiting.is_empty() and not is_busy()


## Seconds until the radio is free for what is playing now (the Vengeance script waits on it); the waiting messages
## are counted too.
func make_busy_seconds() -> float:
	var total := maxf(_busy_left, _delay_left)
	for m in _waiting:
		total += m.make_busy_seconds()
	return total


## When each of `messages` starts if they are played one after the other (FIFO) from time 0: the first at `first_delay`,
## each next one when the one before has kept the radio busy (its voice length, else its text time).
static func make_start_times(messages: Array[MissionMessage], p_first_delay := 0.0) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var at := p_first_delay
	for m in messages:
		out.append(at)
		at += m.make_busy_seconds()
	return out


func make_waiting_count() -> int:
	return _waiting.size()


func _play(message: MissionMessage) -> void:
	if message.text != "":
		_sink.apply_message(message)
	if message.voice != null:
		_sink.apply_voice(message.voice)
	_busy_left = message.make_busy_seconds()

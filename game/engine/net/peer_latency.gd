class_name PeerLatency
extends RefCounted
## Round-trip time of one client, measured over any transport: the server remembers when it sent each pilot state
## (by tick) and the client echoes the newest tick it has seen in its input packets. Times are wall clock
## milliseconds passed in by the caller; the figure only sets how far back lag compensation looks.

const SMOOTHING := 0.2
const KEPT_TICKS := 64
const MAX_PLAUSIBLE_MS := 5000.0

var rtt_ms := 0.0
var samples := 0
var _sent := {}   # server tick -> wall ms


func note_sent(tick: int, now_ms: int) -> void:
	_sent[tick] = now_ms
	if _sent.size() > KEPT_TICKS:
		_sent.erase(_sent.keys().min())


func note_echo(tick: int, now_ms: int) -> void:
	if not _sent.has(tick):
		return
	var sample := clampf(float(now_ms - int(_sent[tick])), 0.0, MAX_PLAUSIBLE_MS)
	rtt_ms = sample if samples == 0 else lerpf(rtt_ms, sample, SMOOTHING)
	samples += 1
	for t: int in _sent.keys():
		if t <= tick:
			_sent.erase(t)

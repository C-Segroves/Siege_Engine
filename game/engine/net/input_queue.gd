class_name InputQueue
extends RefCounted
## The server's queue of one pilot's input frames: frames arrive redundantly and out of step with the server's tick,
## the server consumes exactly one per tick. A frame seen twice is dropped, a backlog beyond MAX_BACKLOG loses its
## oldest frames, and a gap repeats the last frame for MAX_REPEAT ticks and then lets go of the movement (aim and
## weapons stay), so a dead connection does not run a body into a wall. After a gap (and at the start) the queue
## refills to PRIME_DEPTH frames before it feeds again, a small jitter buffer: network jitter then costs a frame of
## delay instead of a repeated frame the client did not predict.

const MAX_BACKLOG := 4
const MAX_REPEAT := 6
const PRIME_DEPTH := 2

## Sequence number of the last frame consumed: what the server echoes as "processed".
var last_seq := 0
var dropped := 0
var starved := 0
var _frames: Array[Dictionary] = []
var _last: Dictionary = {}
var _repeats := 0
var _primed := false


func size() -> int:
	return _frames.size()


## Adds the frames of one packet (ascending seq); returns how many were new.
func push_frames(frames: Array) -> int:
	var added := 0
	for f: Dictionary in frames:
		if int(f.seq) > last_seq and _insert(f):
			added += 1
	while _frames.size() > MAX_BACKLOG:
		_frames.pop_front()
		dropped += 1
	return added


## The frame to simulate this tick ({} before the first frame ever arrived).
func take_next() -> Dictionary:
	if _frames.size() >= (1 if _primed else PRIME_DEPTH):
		_primed = true
		_last = _frames.pop_front()
		last_seq = int(_last.seq)
		_repeats = 0
		return _last
	if _frames.is_empty():
		_primed = false
	starved += 1
	_repeats += 1
	if _last.is_empty() or _repeats <= MAX_REPEAT:
		return _last
	return InputFrame.make_neutral(_last)


func _insert(f: Dictionary) -> bool:
	var at := _frames.size()
	while at > 0 and int(_frames[at - 1].seq) > int(f.seq):
		at -= 1
	if at > 0 and int(_frames[at - 1].seq) == int(f.seq):
		return false
	_frames.insert(at, f)
	return true

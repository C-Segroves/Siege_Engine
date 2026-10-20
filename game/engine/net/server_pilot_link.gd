class_name ServerPilotLink
extends PilotLink
## Server side of a predicted pilot: the body steps exactly one queued input frame per physics step (InputQueue) and
## after the step keeps its state together with the sequence number of that frame; BattleNetSync echoes it to the
## client, which reconciles against it. The latency figures feed lag compensation.

## A link that saw no frame for this long is considered dropped (the client went back to plain input).
const STALE_MS := 500

var peer := 0
var body: Herc
var queue := InputQueue.new()
var latency := PeerLatency.new()
## Puts one frame's controls on the body: Callable(body: Herc, frame: Dictionary).
var apply_frame: Callable
## Echo of the last step: valid when `fresh`, cleared by the sender.
var state: PilotState
var fresh := false
var last_frame_ms := 0
var _echoed_seq := 0


func _init(p_peer: int, p_body: Herc, p_apply_frame: Callable, now_ms: int) -> void:
	peer = p_peer
	body = p_body
	apply_frame = p_apply_frame
	last_frame_ms = now_ms


## Takes the frames of an input packet.
func receive_frames(frames: Array, echo_tick: int, now_ms: int) -> void:
	queue.push_frames(frames)
	latency.note_echo(echo_tick, now_ms)
	last_frame_ms = now_ms


func is_stale(now_ms: int) -> bool:
	return now_ms - last_frame_ms > STALE_MS


func begin_step(stepped: Herc, _delta: float) -> void:
	var frame := queue.take_next()
	if not frame.is_empty():
		apply_frame.call(stepped, frame)


func end_step(stepped: Herc) -> void:
	state = PilotState.make_from(stepped)
	state.seq = queue.last_seq
	fresh = state.seq != _echoed_seq   # a repeated frame (the queue ran dry) has nothing new to answer
	_echoed_seq = state.seq

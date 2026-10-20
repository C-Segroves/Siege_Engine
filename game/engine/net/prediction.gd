class_name Prediction
extends PilotLink
## Client-side prediction of the local pilot's own body with server reconciliation (docs/DEDICATED_SERVER_SCALING.md
## section 2.2). The body steps its own movement every physics step from the pilot's controls, grouped into
## sequenced input frames (InputFrame); each recorded frame keeps the state it produced. The server echoes the state it
## reached after the last frame it processed (PilotState). The client compares that with what it predicted for the
## same sequence number:
##   within EPSILON_M            nothing to do, the prediction was right;
##   below the snap distance     the client rewinds to the server state, replays the unacked frames through the same
##                               movement code and blends the difference out over BLEND_S (the body keeps moving
##                               smoothly, `pending` is the part of the correction still to apply);
##   at or above it              the body snaps to the replayed state.
## Thresholds follow the game's feel (section 6): Tribes soldiers reconcile at 1.5 m, the slow Hercs at 3 m.

const EPSILON_M := 0.05
const CAPACITOR_EPSILON := 0.5
const BLEND_S := 0.1
const SNAP_INFANTRY_M := 1.5
const SNAP_HERC_M := 3.0
const MAX_FRAMES := 180

## Distance (m) from which a correction snaps instead of blending.
var snap_m := SNAP_HERC_M
## The thresholds a NetProfile tunes (defaults: the constants above).
var blend_s := BLEND_S
var epsilon_m := EPSILON_M
var step_dt := 1.0 / 60.0
## Physics steps per input frame (physics rate / server tick rate, at least 1).
var steps_per_frame := 1
## Callable(body: Herc) -> Dictionary: the pilot's controls now (BattleNetSync.make_controls).
var sample_controls: Callable
## Correction still to blend into the body.
var pending := Vector3.ZERO
var last_acked := 0
## A frame was recorded since the sender last looked.
var has_new_frame := false
var corrections := 0
var snaps := 0
var replays := 0
var max_error := 0.0
## Largest part of a correction applied in one physics step (what a player could see as a jerk).
var max_step_correction := 0.0
var _history: Array[Dictionary] = []   # {frame, state}: unacked frames and the state each produced
var _next_seq := 1
var _frame: Dictionary = {}
var _steps_done := 0
var _incoming: PilotState


func _init(p_sample_controls: Callable, p_step_dt: float, p_steps_per_frame: int, p_snap_m: float) -> void:
	sample_controls = p_sample_controls
	step_dt = p_step_dt
	steps_per_frame = maxi(p_steps_per_frame, 1)
	snap_m = p_snap_m


## The snap distance of `body`'s kind.
static func make_snap_distance(body: Herc) -> float:
	return SNAP_INFANTRY_M if body is Infantry else SNAP_HERC_M


## How many physics steps one server tick spans for a client physics rate.
static func make_steps_per_frame(physics_hz: int, tick_hz: int) -> int:
	return maxi(roundi(float(physics_hz) / float(maxi(tick_hz, 1))), 1)


func is_predicting(body: Herc) -> bool:
	return body.alive and not (body is Infantry and (body as Infantry).stowed)


func begin_step(body: Herc, delta: float) -> void:
	if _steps_done == 0:
		if _incoming != null:
			_reconcile(body, _incoming)
			_incoming = null
		_frame = InputFrame.make_quantized(sample_controls.call(body))
		_frame.seq = _next_seq
		_next_seq += 1
		InputFrame.apply_movement(body, _frame)
	_apply_pending(body, delta)


func end_step(body: Herc) -> void:
	_steps_done += 1
	if _steps_done < steps_per_frame:
		return
	_steps_done = 0
	var state := PilotState.make_from(body)
	state.position += pending
	state.seq = int(_frame.seq)
	_history.append({"frame": _frame, "state": state})
	while _history.size() > MAX_FRAMES:
		_history.pop_front()
	has_new_frame = true


## The server's echo; it is applied at the next frame boundary. An echo of a sequence number already answered is
## ignored: the server repeats a frame when its queue ran dry, and the next new sequence number carries those steps.
func receive_state(state: PilotState) -> void:
	if state.seq > last_acked and (_incoming == null or state.seq > _incoming.seq):
		_incoming = state


## The newest REDUNDANCY unacked frames, oldest first; clears `has_new_frame`.
func take_outgoing() -> Array:
	has_new_frame = false
	var frames := []
	for e in _history.slice(maxi(_history.size() - InputFrame.REDUNDANCY, 0)):
		frames.append(e.frame)
	return frames


## Forgets everything in flight (the body died, changed, was teleported by the game).
func reset() -> void:
	_history.clear()
	pending = Vector3.ZERO
	_incoming = null
	_steps_done = 0
	has_new_frame = false


func unacked_count() -> int:
	return _history.size()


func _reconcile(body: Herc, server: PilotState) -> void:
	last_acked = maxi(last_acked, server.seq)
	if not server.alive or server.seq == 0:
		return
	var index := _find_frame(server.seq)
	if index == -1 and (_history.is_empty() or server.seq > int((_history.back().frame as Dictionary).seq)):
		return   # the server is ahead of what was recorded (a reset): nothing to compare
	var error := INF if index == -1 else (_history[index].state as PilotState).make_error(server)
	var capacitor_error := INF if index == -1 else absf((_history[index].state as PilotState).capacitor - server.capacitor)
	max_error = maxf(max_error, error if error != INF else snap_m)
	_history.assign(_history.slice(index + 1))
	if error <= epsilon_m and capacitor_error <= CAPACITOR_EPSILON:
		return
	_rewind_and_replay(body, server, error)


func _rewind_and_replay(body: Herc, server: PilotState, error: float) -> void:
	var before := PilotState.make_from(body)
	server.apply_to(body)
	_replay(body)
	replays += 1
	if error >= snap_m:
		snaps += 1
		pending = Vector3.ZERO
		return
	corrections += 1
	var after := PilotState.make_from(body)
	body.global_position = before.position
	body.velocity = after.velocity
	body.speed = after.speed
	body.capacitor = after.capacitor
	body.rotation.y = after.yaw
	pending = after.position - before.position


func _replay(body: Herc) -> void:
	for e in _history:
		InputFrame.apply_movement(body, e.frame)
		for i in steps_per_frame:
			body.step_movement(step_dt)
		var state := PilotState.make_from(body)
		state.seq = int((e.frame as Dictionary).seq)
		e.state = state


func _find_frame(seq: int) -> int:
	for i in _history.size():
		if int((_history[i].frame as Dictionary).seq) == seq:
			return i
	return -1


func _apply_pending(body: Herc, delta: float) -> void:
	if pending.length_squared() < 1e-8:
		pending = Vector3.ZERO
		return
	var chunk := pending * minf(1.0, delta / blend_s)
	body.global_position += chunk
	max_step_correction = maxf(max_step_correction, chunk.length())
	pending -= chunk

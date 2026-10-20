class_name MissionEnder
extends RefCounted
## The one door out of a mission. Rules and objectives hand it verdicts; the first verdict wins. It holds the end for the
## verdict's grace (`delay`) and, when asked, while a voice prompt plays (at most VOICE_WAIT_MAX seconds), then makes the
## one call to the game's end function (MissionRuntimeBase.end_mission) with (success, code, text).

## Longest a mission waits for a closing voice prompt (Aerial Assault: the end waits for the prompt, up to 15 s).
const VOICE_WAIT_MAX := 15.0

var _end: Callable
var _is_voice_busy: Callable
var _verdict: MissionVerdict = null
var _waited_voice := 0.0
var _delay_left := 0.0
var _ended := false


## `p_end` is called once as (success, code, text); `p_is_voice_busy` returns true while a voice plays.
func _init(p_end: Callable, p_is_voice_busy: Callable) -> void:
	_end = p_end
	_is_voice_busy = p_is_voice_busy


## Takes `verdict` when no verdict came before it.
func apply_verdict(verdict: MissionVerdict) -> void:
	if verdict == null or _verdict != null:
		return
	_verdict = verdict
	_delay_left = verdict.delay


## A verdict that cannot wait for the one held (a script's own debriefing during a death grace): it takes over, unless
## the mission already ended.
func apply_override(verdict: MissionVerdict) -> void:
	if verdict == null or _ended:
		return
	_verdict = verdict
	_delay_left = verdict.delay


func apply_tick(dt: float) -> void:
	if _verdict == null or _ended:
		return
	if not _verdict.grace_after_voice and not _is_grace_over(dt):
		return
	if _verdict.wait_for_voice and _waited_voice < VOICE_WAIT_MAX and bool(_is_voice_busy.call()):
		_waited_voice += dt
		return
	if _verdict.grace_after_voice and not _is_grace_over(dt):
		return
	_ended = true
	_end.call(_verdict.success, _verdict.code, _verdict.text)


## Runs `dt` seconds off the grace; true once it has run out.
func _is_grace_over(dt: float) -> bool:
	_delay_left -= dt
	return _delay_left <= 0.0


func has_verdict() -> bool:
	return _verdict != null


func is_ended() -> bool:
	return _ended

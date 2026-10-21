class_name MissionVerdict
extends RefCounted
## The ruling of a rule or objective on how the mission ends: a value only, the MissionEnder carries it out.
##   success          the mission is won
##   code, text       the game's own end code and debriefing text
##   delay            seconds to wait before the end (grace, a death debrief)
##   wait_for_voice   hold the end while a voice prompt plays (up to MissionEnder.VOICE_WAIT_MAX)

var success := false
var code := 0
var text := ""
var delay := 0.0
var wait_for_voice := false
## The grace runs after the voice has played, not beside it (Aerial Assault: the closing prompt, then 2 s).
var grace_after_voice := false
## A pending verdict with a different code replaces this one and restarts its grace (Earthsiege 2: a change of status
## starts the 4.9 s over, 7 -> 8); other verdicts leave the first one standing.
var rearms_on_code_change := false


static func make_win(p_code: int, p_text := "", p_delay := 0.0, p_wait_for_voice := false) -> MissionVerdict:
	return _make(true, p_code, p_text, p_delay, p_wait_for_voice)


static func make_loss(p_code: int, p_text := "", p_delay := 0.0, p_wait_for_voice := false) -> MissionVerdict:
	return _make(false, p_code, p_text, p_delay, p_wait_for_voice)


## Makes the grace start once the voice has played; returns this verdict.
func apply_grace_after_voice() -> MissionVerdict:
	grace_after_voice = true
	return self


## Makes a pending verdict re-arm when a verdict with another code arrives; returns this verdict.
func apply_rearm_on_code_change() -> MissionVerdict:
	rearms_on_code_change = true
	return self


static func _make(p_success: bool, p_code: int, p_text: String, p_delay: float, p_wait: bool) -> MissionVerdict:
	var v := MissionVerdict.new()
	v.success = p_success
	v.code = p_code
	v.text = p_text
	v.delay = p_delay
	v.wait_for_voice = p_wait
	return v

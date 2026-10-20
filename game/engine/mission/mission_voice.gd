class_name MissionVoice
extends RefCounted
## One voice prompt: the game's own id (a bank index, a sound name), how long it lasts when the game knows
## (0 = ask the sink's is_voice_playing) and whether it cuts what is playing (a closing prompt does).

var id: Variant = 0
var seconds := 0.0
var interrupt := false


static func make_voice(p_id: Variant, p_seconds := 0.0, p_interrupt := false) -> MissionVoice:
	var v := MissionVoice.new()
	v.id = p_id
	v.seconds = p_seconds
	v.interrupt = p_interrupt
	return v

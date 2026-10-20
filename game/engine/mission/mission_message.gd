class_name MissionMessage
extends RefCounted
## A line shown to the player, with the voice that goes with it when there is one.
##   text      the line ("" for a voice alone)
##   seconds   how long the line stays up (and holds a FIFO queue)
##   channel   where it shows: "radio", "info", "error" (the game's sink maps these)
##   speaker   who talks ("" for the mission itself)
##   voice     a MissionVoice or null

const CHANNEL_RADIO := "radio"
const CHANNEL_INFO := "info"
const CHANNEL_ERROR := "error"

var text := ""
var seconds := 0.0
var channel := CHANNEL_RADIO
var speaker := ""
var voice: MissionVoice = null


static func make_message(p_text: String, p_seconds := 0.0, p_channel := CHANNEL_RADIO, p_speaker := "",
		p_voice: MissionVoice = null) -> MissionMessage:
	var m := MissionMessage.new()
	m.text = p_text
	m.seconds = p_seconds
	m.channel = p_channel
	m.speaker = p_speaker
	m.voice = p_voice
	return m


## A voice prompt alone.
static func make_voice_only(p_voice: MissionVoice) -> MissionMessage:
	return make_message("", 0.0, CHANNEL_RADIO, "", p_voice)


## How long this message keeps the radio busy: its voice's length, else the time its text stays up (0 = unknown).
func make_busy_seconds() -> float:
	if voice != null and voice.seconds > 0.0:
		return voice.seconds
	return seconds

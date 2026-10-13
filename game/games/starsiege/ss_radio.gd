class_name SSRadio
extends RefCounted
## Turns a Starsiege script say() into a campaign radio line {speaker, text, voice} (Battle.radio;
## docs/formats/starsiege.md "Radio"):
## - the campaign string tables name the speaker at the start of the line ("<NAME>: <words>", 193 of the 219
##   string ids the missions speak), so a leading name is taken as the speaker [H, data];
## - otherwise the speaker is the AI vehicle `who` names (actorTalks(actor, ...) in missionStdLib.cs passes the
##   actor; $playerId as `who` addresses the player, so it names no speaker) [M], else none;
## - Darkstar font-select codes "<F<n>>" inside the text are dropped (the chat draws its own colours) [M];
## - the wav argument names a clip exported to audio/voice/ (tools/export_starsiege_voice.py).

const PACK := "starsiege"
## A leading speaker: up to 25 characters of name, a colon, a space (after optional font codes).
const SPEAKER_PATTERN := "^\\s*(?:<F\\d+>\\s*)*([A-Z0-9][A-Za-z0-9 .'\\-]{0,24}):\\s+(.+)$"
const FONT_CODE_PATTERN := "<F\\d+>"

static var _speaker_re := RegEx.create_from_string(SPEAKER_PATTERN)
static var _font_re := RegEx.create_from_string(FONT_CODE_PATTERN)


## The line `text` says, spoken by `who_name` unless the text names its own speaker.
static func make_line(text: String, who_name: String, wav: String) -> Dictionary:
	var clean := _font_re.sub(text, "", true).strip_edges()
	var speaker := who_name
	var m := _speaker_re.search(text)
	if m != null:
		speaker = m.get_string(1).strip_edges()
		clean = _font_re.sub(m.get_string(2), "", true).strip_edges()
	return RadioLine.make(speaker, clean, make_voice_name(wav))


## Sfx sound name of a script's wav argument ("HA1_X01.wav" -> "starsiege:ha1_x01"), "" when none.
static func make_voice_name(wav: String) -> String:
	var file := wav.strip_edges().get_file()
	if not file.to_lower().ends_with(".wav"):
		return ""
	return RadioLine.make_voice_name(PACK, file)

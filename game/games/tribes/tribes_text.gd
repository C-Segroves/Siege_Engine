class_name TribesText
extends RefCounted
## Plain text of the Tribes / Tribes 2 message strings: Darkstar font and layout codes (<f1>, <jc>, <B0,0:x.bmp>),
## Torque markup (<spush>, <font:...>, <bitmap:...>, <lmargin:24>) and Tribes sound cues (~w<file>) are dropped,
## %1..%9 are filled in (Tribes 2 tagged strings).

const MAX_TAG_LENGTH := 64
## "~w<file>": a Tribes message plays a sound instead of (or after) its text.
const SOUND_CUE := "~w"

static var _tags := RegEx.create_from_string("<[^<>\\n]{1,%d}>" % MAX_TAG_LENGTH)
static var _spaces := RegEx.create_from_string("[ \\t]+")


static func make_plain(text: String) -> String:
	var s := _tags.sub(text, "", true)
	var cue := s.find(SOUND_CUE)
	if cue >= 0:
		s = s.substr(0, cue)
	return _spaces.sub(s, " ", true).strip_edges()


## The sound file a Tribes message cues ("~wshell_click.wav" -> "shell_click.wav"; "" when none).
static func make_sound_cue(text: String) -> String:
	var cue := text.find(SOUND_CUE)
	return text.substr(cue + SOUND_CUE.length()).strip_edges() if cue >= 0 else ""


## "%1: %2" with args -> the filled-in text (Tribes 2 messageClient / messageAll).
static func make_formatted(text: String, args: Array) -> String:
	var s := text
	for i in range(mini(args.size(), 9), 0, -1):
		s = s.replace("%" + str(i), DarkstarScript.to_str(args[i - 1]))
	return s

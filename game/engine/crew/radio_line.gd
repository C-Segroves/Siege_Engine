class_name RadioLine
extends RefCounted
## What every game's radio producer hands Battle.radio: a speaker, a line of text and the Sfx name of its
## voice clip. The producers differ only in where the line comes from (Earthsiege pilot / command STR tables:
## RadioTable; Starsiege script say(): SSRadio; Tribes 2 training alxPlay: Tribes2Functions); the clip naming
## is shared here. Exported clips live under the pack's audio/voice/ folder as lower-case stems
## ("es2:sim/p1_01000", "starsiege:ha1_x01", "tribes2:training/mission1/t1_01").


## Sfx sound name of a clip at `clip_path` inside `pack`'s voice folder ("" when there is no clip).
static func make_voice_name(pack: String, clip_path: String) -> String:
	var stem := clip_path.strip_edges().to_lower().get_basename()
	if stem == "":
		return ""
	return "%s:%s" % [pack, stem]


## One radio line as the producers hand it on ({speaker, text, voice}).
static func make(speaker: String, text: String, voice: String) -> Dictionary:
	return {"speaker": speaker, "text": text, "voice": voice}

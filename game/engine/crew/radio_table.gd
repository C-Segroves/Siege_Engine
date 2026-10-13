class_name RadioTable
extends RefCounted
## One radio voice table of a pack (audio/tables/<name>_voice.json, written at import from the originals' STR
## files: tools/audio.py for Earthsiege, tools/export_es2_radio.py for Earthsiege 2; docs/formats/audio_video.md
## "Pilot radio", docs/formats/es2.md section 11). Rows {text, message, variant, file, exists[, voice]}: a
## message number has one or more variants. Wingman tables pick one variant at random; command tables speak
## all of a message's variants as one line (they are its successive sentences).
##
## A line is {text, voice}: `voice` is a Sfx sound name ("<pack>:<dir>/<stem>", "" when the clip is missing).

## Earthsiege 1 rows have no "voice" field: their clips sit in audio/voice/sim/ (tools/audio.py PCM_SETS).
const DEFAULT_VOICE_DIR := "sim"
const TABLE_PATH := "audio/tables/%s_voice.json"

var pack := ""
var _by_message := {}       # message number -> Array of rows, in variant order


## The table `name` ("pilot1", "command2" ...) of `pack`; empty when the pack has none (is_empty()).
static func load_table(p_pack: String, name: String) -> RadioTable:
	var t := RadioTable.new()
	t.pack = p_pack
	var rows = Assets.load_json(TABLE_PATH % name, p_pack)
	if rows is Array:
		t.apply_rows(rows)
	return t


## Indexes `rows` by message number.
func apply_rows(rows: Array) -> void:
	for r in rows:
		if r is Dictionary:
			var m := int(r.get("message", -1))
			if not _by_message.has(m):
				_by_message[m] = []
			_by_message[m].append(r)
	for m in _by_message:
		_by_message[m].sort_custom(func(a, b): return int(a.get("variant", 0)) < int(b.get("variant", 0)))


func is_empty() -> bool:
	return _by_message.is_empty()


func has_message(message: int) -> bool:
	return _by_message.has(message)


## Every message number the table has, ascending.
func message_numbers() -> Array:
	var keys := _by_message.keys()
	keys.sort()
	return keys


## A random variant of `message` ({} when the table lacks it).
func make_random_line(message: int) -> Dictionary:
	var rows: Array = _by_message.get(message, [])
	if rows.is_empty():
		return {}
	var r: Dictionary = rows[randi() % rows.size()]
	return {"text": make_clean_text(str(r.get("text", ""))), "voice": make_voice_name(r)}


## All variants of `message` as one line, with the first variant's clip ({} when the table lacks it).
func make_joined_line(message: int) -> Dictionary:
	var rows: Array = _by_message.get(message, [])
	if rows.is_empty():
		return {}
	var parts := PackedStringArray()
	for r in rows:
		parts.append(make_clean_text(str(r.get("text", ""))))
	return {"text": " ".join(parts), "voice": make_voice_name(rows[0])}


## Sfx sound name of a row's clip, "" when the clip does not exist.
func make_voice_name(row: Dictionary) -> String:
	if not bool(row.get("exists", false)):
		return ""
	var clip := str(row.get("voice", ""))
	if clip == "":
		clip = "%s/%s" % [DEFAULT_VOICE_DIR, str(row.get("file", ""))]
	return RadioLine.make_voice_name(pack, clip)


## The STR texts are upper case subtitles; whitespace runs collapse to single spaces.
static func make_clean_text(text: String) -> String:
	return " ".join(text.strip_edges().split(" ", false))

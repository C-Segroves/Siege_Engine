class_name BdVoices
extends RefCounted
## Battledrome's in-sim voice data, decoded from the user's SIM.EXE at import (tools/bd_voices.py ->
## bd/cockpit/voices.json; message texts: bd/cockpit/strings.json, MSGTEXT.BIN).  Voices are "bd:<stem>" Sfx names.

const PACK := "bd"
const VOICES_FILE := "cockpit/voices.json"
const STRINGS_FILE := "cockpit/strings.json"

static var _cache := {}


## voices.json ({} when Battledrome is not imported).
static func table() -> Dictionary:
	return _load(VOICES_FILE)


## The Sfx name of a voice stem ("" for a text-only message).
static func sound_name(stem: String) -> String:
	return "%s:%s" % [PACK, stem] if stem != "" else ""


## Message `index` of the MessageManager table ({} if unknown): {text, voice, queued, urgent, repeat_s}.
static func message(index: int) -> Dictionary:
	var messages: Array = table().get("messages", [])
	return messages[index] if index >= 0 and index < messages.size() else {}


## The MSGTEXT.BIN line of message `index`.
static func message_text(index: int) -> String:
	var lines: Array = _load(STRINGS_FILE).get("messages", [])
	var line := int(message(index).get("text", -1))
	return String(lines[line]) if line >= 0 and line < lines.size() else ""


## Forgets the cached tables (after an import).
static func clear_cache() -> void:
	_cache.clear()


static func _load(rel: String) -> Dictionary:
	if not _cache.has(rel):
		var j = Assets.load_json(rel, PACK) if Assets.has_pack(PACK) else null
		_cache[rel] = j if j is Dictionary else {}
	return _cache[rel]

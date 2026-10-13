class_name ChatLog
extends RefCounted
## The chat's history: every line the local player received, oldest first (ChatChannels). An entry is
## {channel, sender, text, team, msec, stamp}: `sender` "" for system lines, `msec` the local receive time
## (Time.get_ticks_msec, for fading), `stamp` the wall-clock "HH:MM" for the optional timestamps.

signal added(entry: Dictionary)

const MAX_ENTRIES := 300
## Longest line a player may send (characters); the host cuts longer ones.
const MAX_TEXT_LENGTH := 160

var entries: Array = []


## Adds a line now; returns nothing (listeners get `added`).
func add(channel: String, sender: String, text: String, team := -1) -> void:
	var entry := {"channel": channel, "sender": sender, "text": text, "team": team,
		"msec": Time.get_ticks_msec(), "stamp": make_stamp()}
	entries.append(entry)
	if entries.size() > MAX_ENTRIES:
		entries.pop_front()
	added.emit(entry)


func clear() -> void:
	entries.clear()


## The entries whose channel `filters` shows (a channel missing from `filters` shows).
func make_shown(filters: Dictionary) -> Array:
	return entries.filter(func(e: Dictionary) -> bool: return bool(filters.get(e.channel, true)))


## The newest entry of `channel` ({} when none).
func find_newest(channel: String) -> Dictionary:
	for i in range(entries.size() - 1, -1, -1):
		if entries[i].channel == channel:
			return entries[i]
	return {}


## `text` as a chat line: control characters removed, spaces collapsed at the ends, cut to MAX_TEXT_LENGTH.
static func make_clean(text: String) -> String:
	var out := ""
	for c in text:
		if c.unicode_at(0) >= 32:
			out += c
	return out.strip_edges().left(MAX_TEXT_LENGTH)


static func make_stamp() -> String:
	var t := Time.get_time_dict_from_system()
	return "%02d:%02d" % [int(t.hour), int(t.minute)]

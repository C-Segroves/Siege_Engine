class_name ChatLines
## The chat panel's text lines: each ChatLog entry as "[stamp ][[Team] ]Sender: text", word-wrapped to the
## panel width. A line is {prefix, text, channel, msec}: `prefix` (the stamp and sender, drawn in a lighter
## colour) only on an entry's first line.


## Every entry of `entries` as wrapped lines, oldest first; `style` = {font, font_size, width, timestamps}.
static func make_lines(entries: Array, style: Dictionary) -> Array:
	var font: Font = style.font
	var font_size := int(style.font_size)
	var measure := func(t: String) -> float: return font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var out := []
	for e in entries:
		var prefix := make_prefix(e, bool(style.timestamps))
		var wrapped := TextWrap.make_lines(prefix + str(e.text), float(style.width), measure)
		for i in wrapped.size():
			var line := {"prefix": "", "text": wrapped[i], "channel": e.channel, "msec": e.msec}
			if i == 0 and prefix != "" and wrapped[i].begins_with(prefix.strip_edges()):
				line.prefix = wrapped[i].left(prefix.length())
				line.text = wrapped[i].substr(prefix.length())
			out.append(line)
	return out


## "12:34 [Team] Rook: " (stamp only with `timestamps`; no sender on system lines).
static func make_prefix(entry: Dictionary, timestamps: bool) -> String:
	var prefix := "%s " % entry.stamp if timestamps else ""
	if entry.channel == ChatChannels.TEAM:
		prefix += "[%s] " % ChatChannels.label_of(ChatChannels.TEAM)
	if str(entry.sender) != "":
		prefix += "%s: " % entry.sender
	return prefix

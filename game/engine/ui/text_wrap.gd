class_name TextWrap
## Word wrapping for text drawn by hand (the cockpit message windows, the chat panel): `measure` is a Callable
## (String) -> float giving a text's drawn width.


## `text` broken at spaces into lines no wider than `width`; a word wider than a line is cut.
static func make_lines(text: String, width: float, measure: Callable) -> PackedStringArray:
	var lines := PackedStringArray()
	var line := ""
	for word in text.split(" ", false):
		var joined := word if line == "" else "%s %s" % [line, word]
		if float(measure.call(joined)) <= width:
			line = joined
			continue
		if line != "":
			lines.append(line)
		line = _make_cut(word, width, measure, lines)
	if line != "":
		lines.append(line)
	return lines


## Appends the full-width pieces of a too-long `word` to `lines`; returns the rest.
static func _make_cut(word: String, width: float, measure: Callable, lines: PackedStringArray) -> String:
	var rest := word
	while rest.length() > 1 and float(measure.call(rest)) > width:
		var n := rest.length() - 1
		while n > 1 and float(measure.call(rest.left(n))) > width:
			n -= 1
		lines.append(rest.left(n))
		rest = rest.substr(n)
	return rest

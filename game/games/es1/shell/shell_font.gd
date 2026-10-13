class_name ShellFont
extends RefCounted
## Dynamix DFN bitmap font (exported as an index atlas + metrics). Draws palette indices into LA8 images.

## Unicode -> CP437 for the upper half (strings were decoded as cp437 by the exporter).
const CP437_HIGH := "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ "

var name := ""
var height := 8
var atlas: Image
var glyphs := {}          # code -> Image (LA8) or null for empty glyphs
var widths := {}          # code -> advance


static func load_font(font_name: String) -> ShellFont:
	var f := ShellFont.new()
	f.name = font_name
	var j = ShellData.json("fonts/%s.json" % font_name)
	f.atlas = ShellData.image("fonts/%s.png" % font_name)
	if not (j is Dictionary) or f.atlas == null:
		push_warning("shell font missing: " + font_name)
		return f
	f.height = int(j.height)
	for k in j.chars:
		var c: Array = j.chars[k]
		var code := int(k)
		var w := int(c[2])
		f.widths[code] = w
		f.glyphs[code] = f.atlas.get_region(Rect2i(int(c[0]), int(c[1]), w, f.height)) if w > 0 else null
	return f


static func code_of(ch: String) -> int:
	var u := ch.unicode_at(0)
	if u < 128:
		return u
	var i := CP437_HIGH.find(ch)
	return 128 + i if i >= 0 else 63


func char_width(code: int) -> int:
	return int(widths.get(code, 0))


func width(s: String) -> int:
	var w := 0
	for i in s.length():
		w += char_width(code_of(s[i]))
	return w


## Draws `s` with its top-left at (x, y); returns the x after the last glyph.
func draw(dst: Image, x: int, y: int, s: String) -> int:
	for i in s.length():
		var code := code_of(s[i])
		var g: Image = glyphs.get(code)
		if g:
			dst.blit_rect_mask(g, g, Rect2i(Vector2i.ZERO, g.get_size()), Vector2i(x, y))
		x += char_width(code)
	return x


## Draws aligned in a rect: halign 0 left, 1 right, 2 centre; vertically centred.
func draw_in(dst: Image, r: Rect2i, s: String, halign := 0, dx := 0, dy := 0) -> void:
	var w := width(s)
	var x := r.position.x
	if halign == 1:
		x = r.end.x - w
	elif halign == 2:
		x = r.position.x + (r.size.x - w) / 2
	var y := r.position.y + (r.size.y - height) / 2 + 1
	draw(dst, x + dx, y + dy, s)


## Greedy word wrap to `max_w` pixels.
func wrap(s: String, max_w: int) -> PackedStringArray:
	var out := PackedStringArray()
	for para in s.split("\n"):
		var line := ""
		for word in para.split(" ", false):
			var t := word if line == "" else line + " " + word
			if width(t) > max_w and line != "":
				out.append(line)
				line = word
			else:
				line = t
		out.append(line)
	return out

class_name CockpitCanvas
extends RefCounted
## Drawing primitives of the cockpit's virtual canvas (the layout's pixel space: Earthsiege 1 320x200,
## Earthsiege 2 320x240): bitmaps, fills, DFN text, drawn on `item` during its _draw() with the cockpit's
## assets. A bitmap or font stored at a higher resolution (CockpitAssets.scale_of) is drawn at its layout
## size. Rects in the layout files are inclusive [x1, y1, x2, y2] (rect_of).

const NO_CLIP := Rect2()
const NO_TINT := Color(0, 0, 0, 0)
const DEFAULT_FONT_HEIGHT := 8

var item: CanvasItem
var assets: CockpitAssets


func _init(p_item: CanvasItem, p_assets: CockpitAssets) -> void:
	item = p_item
	assets = p_assets


## Layout rect [x1, y1, x2, y2] (inclusive) -> Rect2.
static func rect_of(a) -> Rect2:
	return Rect2(float(a[0]), float(a[1]), float(a[2]) - float(a[0]) + 1.0, float(a[3]) - float(a[1]) + 1.0)


func color(i: int) -> Color:
	return assets.color(i)


func dba(n: String, i: int) -> Texture2D:
	return assets.dba(n, i)


## Size of `tex` on the canvas.
func size_of(tex: Texture2D) -> Vector2:
	return tex.get_size() / assets.scale_of(tex) if tex else Vector2.ZERO


func blit(tex: Texture2D, x: float, y: float, clip := NO_CLIP, mod := Color.WHITE) -> void:
	if tex == null:
		return
	var s := assets.scale_of(tex)
	var dst := Rect2(x, y, tex.get_width() / s, tex.get_height() / s)
	if clip.size == Vector2.ZERO:
		item.draw_texture_rect_region(tex, dst, Rect2(Vector2.ZERO, dst.size * s), mod)
		return
	var c := dst.intersection(clip)
	if c.size.x > 0.0 and c.size.y > 0.0:
		item.draw_texture_rect_region(tex, c, Rect2((c.position - dst.position) * s, c.size * s), mod)


## Draws all of `tex` stretched over canvas rect `r` (a rendered picture, e.g. the missile camera).
func stretch(tex: Texture2D, r: Rect2, mod := Color.WHITE) -> void:
	if tex != null:
		item.draw_texture_rect(tex, r, false, mod)


## Blits `tex` mirrored (flip_x / flip_y) with its top-left at (x, y).
func blit_flipped(tex: Texture2D, x: float, y: float, flip: Vector2i, mod := Color.WHITE) -> void:
	if tex == null:
		return
	var sz := size_of(tex)
	var dst := Rect2(x + (sz.x if flip.x else 0.0), y + (sz.y if flip.y else 0.0),
		-sz.x if flip.x else sz.x, -sz.y if flip.y else sz.y)
	item.draw_texture_rect(tex, dst, false, mod)


## Blits frame `i` of DBA `n` at the top-left of layout rect `r`, clipped to it.
func blit_button(n: String, i: int, r) -> void:
	blit(dba(n, i), float(r[0]), float(r[1]), rect_of(r))


func fill(r: Rect2, col: Color, clip := NO_CLIP) -> void:
	if clip.size != Vector2.ZERO:
		r = r.intersection(clip)
	if r.size.x > 0.0 and r.size.y > 0.0:
		item.draw_rect(r, col)


## Line height of font `n` on the canvas.
func font_height(n: String) -> float:
	var f := assets.font(n)
	return float(f.h) / float(f.scale) if not f.is_empty() else float(DEFAULT_FONT_HEIGHT)


func text_width(n: String, s: String) -> float:
	var f := assets.font(n)
	if f.is_empty():
		return 0.0
	var w := 0
	for ch in s:
		var gl = f.chars.get(str(ch.unicode_at(0)))
		if gl != null:
			w += int(gl[2])
	return w / float(f.scale)


## Draws `s` at (x, y) in cockpit font `n`; returns the advance. `clip` limits the drawn area.
func text(n: String, x: float, y: float, s: String, clip := NO_CLIP, tint := NO_TINT, mod := Color.WHITE) -> float:
	var f := assets.font(n)
	if f.is_empty():
		return 0.0
	var tex := assets.font_texture(n, tint)
	var sc: float = f.scale
	var cx := x
	var fh: int = f.h
	for ch in s:
		var gl = f.chars.get(str(ch.unicode_at(0)))
		if gl == null:
			continue
		var gw := int(gl[2])
		if gw > 0:
			_draw_glyph(tex, Rect2(cx, y, gw / sc, fh / sc), Rect2(float(gl[0]), float(gl[1]), gw, fh), clip, mod)
		cx += gw / sc
	return cx - x


func _draw_glyph(tex: Texture2D, dst: Rect2, src: Rect2, clip: Rect2, mod: Color) -> void:
	if clip.size == Vector2.ZERO:
		item.draw_texture_rect_region(tex, dst, src, mod)
		return
	var c := dst.intersection(clip)
	if c.size.x > 0.0 and c.size.y > 0.0:
		var k := src.size / dst.size
		item.draw_texture_rect_region(tex, c, Rect2(src.position + (c.position - dst.position) * k, c.size * k), mod)


## Draws `s` centred in `r` (clipped to it).
func text_centered(n: String, r: Rect2, s: String, tint := NO_TINT) -> void:
	var x := r.position.x + floorf((r.size.x - text_width(n, s)) * 0.5)
	var y := r.position.y + floorf((r.size.y - font_height(n)) * 0.5)
	text(n, x, y, s, r, tint)

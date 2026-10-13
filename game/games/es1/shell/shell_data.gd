class_name ShellData
extends RefCounted
## Loader / cache for the exported front-end data (gamedata/es1/shell, written by tools/export_shell.py).
##
## All pictures are palette-index images in FORMAT_LA8 (L = palette index, A = 0 for transparent index 0),
## so the shell composites a real 8-bit 320x200 frame buffer and applies palettes in a shader.

const ROOT := "shell"
const SUBDIRS := ["RES32", "INTRO", "DBA", "ANM"]

static var _json := {}
static var _images := {}
static var _sheets := {}
static var _fonts := {}
static var _palettes := {}


static func available() -> bool:
	return FileAccess.file_exists(Assets.path(ROOT + "/shell.json"))


static func json(rel: String) -> Variant:
	if not _json.has(rel):
		_json[rel] = Assets.load_json(ROOT + "/" + rel)
	return _json[rel]


static func meta() -> Dictionary:
	var j = json("shell.json")
	return j if j is Dictionary else {}


static func _load_la8(rel: String) -> Image:
	var p := Assets.path(ROOT + "/" + rel)
	if not FileAccess.file_exists(p):
		return null
	var img := Image.load_from_file(p)
	if img == null:
		return null
	if img.get_format() != Image.FORMAT_LA8:
		img.convert(Image.FORMAT_LA8)
	return img


static func image(rel: String) -> Image:
	if not _images.has(rel):
		_images[rel] = _load_la8(rel)
	return _images[rel]


## Resource name ("REGN1000", "c0_brd.BMP", ...) -> base name in upper case without extension.
static func base_name(n: String) -> String:
	var i := n.rfind(".")
	if i >= 0:
		n = n.substr(0, i)
	return n.get_file().to_upper()


static func _search(kind: String, n: String, ext: String, first_dir := "") -> String:
	var dirs: Array = SUBDIRS.duplicate()
	if first_dir != "":
		dirs.erase(first_dir)
		dirs.push_front(first_dir)
	for d in dirs:
		var rel := "%s/%s/%s.%s" % [kind, d, n, ext]
		if FileAccess.file_exists(Assets.path(ROOT + "/" + rel)):
			return rel
	return ""


## Full-screen picture (DBM) as an opaque index image.
static func background(name: String, first_dir := "") -> Image:
	var rel := _search("bg", base_name(name), "png", first_dir)
	return image(rel) if rel != "" else null


## 256 colours of a DPL palette (Array of Color); missing -> grey ramp.
static func palette(name: String, first_dir := "") -> PackedColorArray:
	var n := base_name(name)
	var key := first_dir + ":" + n
	if not _palettes.has(key):
		var out := PackedColorArray()
		out.resize(256)
		var rel := _search("palettes", n, "json", first_dir)
		var j = json(rel) if rel != "" else null
		for i in 256:
			if j is Array and i < j.size():
				out[i] = Color8(int(j[i][0]), int(j[i][1]), int(j[i][2]))
			else:
				out[i] = Color8(i, i, i)
		_palettes[key] = out
	return _palettes[key]


## Sprite sheet (DBA): Array of LA8 frame images. Returns [] when missing.
static func sheet(name: String, first_dir := "") -> Array:
	var n := base_name(name)
	var key := first_dir + ":" + n
	if not _sheets.has(key):
		var frames := []
		var rel := _search("dba", n, "json", first_dir)
		if rel != "":
			var j: Dictionary = json(rel)
			var img := image(rel.get_basename() + ".png")
			if img:
				for r in j.frames:
					var w := int(r[2])
					var h := int(r[3])
					if w <= 0 or h <= 0:
						frames.append(null)
					else:
						frames.append(img.get_region(Rect2i(int(r[0]), int(r[1]), w, h)))
		_sheets[key] = frames
	return _sheets[key]


static func font(name: String) -> ShellFont:
	if not _fonts.has(name):
		_fonts[name] = ShellFont.load_font(name)
	return _fonts[name]


static func strings(name: String) -> Array:
	var j = json("strings/%s.json" % name)
	if j is Dictionary:
		return j.get("strings", [])
	return []


static func dlg(menu_id: int) -> Dictionary:
	var j = json("dlg/MENU%d.json" % menu_id)
	return j if j is Dictionary else {}


static func has_dlg(menu_id: int) -> bool:
	return FileAccess.file_exists(Assets.path(ROOT + "/dlg/MENU%d.json" % menu_id))


## "INTRO/DYNAMIX", "C0_SYNC" or "c0_sync.ttm" -> decoded TTM dictionary (or {}).
static func ttm(name: String) -> Dictionary:
	var dir := ""
	var n := name
	if name.find("/") >= 0:
		dir = name.get_slice("/", 0).to_upper()
		n = name.get_slice("/", 1)
	n = base_name(n)
	var rel := _search("ttm", n, "json", dir)
	if rel == "":
		return {}
	var j = json(rel)
	return j if j is Dictionary else {}


## Blits an LA8 sprite (index 0 transparent) into an LA8 target, optionally flipped.
static func blit(dst: Image, src: Image, x: int, y: int, flip := 0) -> void:
	if src == null:
		return
	var s := src
	if flip != 0:
		s = src.duplicate()
		if flip & 1:
			s.flip_x()
		if flip & 2:
			s.flip_y()
	dst.blit_rect_mask(s, s, Rect2i(Vector2i.ZERO, s.get_size()), Vector2i(x, y))


static func fill(dst: Image, r: Rect2i, index: int) -> void:
	r = r.intersection(Rect2i(0, 0, dst.get_width(), dst.get_height()))
	if r.size.x > 0 and r.size.y > 0:
		dst.fill_rect(r, idx_color(index))


static func idx_color(index: int) -> Color:
	var v := clampi(index, 0, 255) / 255.0
	return Color(v, v, v, 1.0)


static func pset(dst: Image, x: int, y: int, index: int) -> void:
	if x >= 0 and y >= 0 and x < dst.get_width() and y < dst.get_height():
		dst.set_pixel(x, y, idx_color(index))


static func line(dst: Image, x0: int, y0: int, x1: int, y1: int, index: int) -> void:
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	var guard := 0
	while guard < 4096:
		guard += 1
		pset(dst, x0, y0, index)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy


static func new_screen() -> Image:
	var img := Image.create(320, 200, false, Image.FORMAT_LA8)
	img.fill(Color(0, 0, 0, 1))
	return img

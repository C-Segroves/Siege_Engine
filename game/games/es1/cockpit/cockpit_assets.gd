class_name CockpitAssets
extends RefCounted
## Cached cockpit data of one pack (gamedata/<pack>/cockpit/, tools/export_cockpit.py and
## tools/export_es2_cockpit.py): palette, strings0.json, instrument bitmaps, DFN fonts (plain and tinted),
## PDG damage diagrams recoloured by component health, and the wingman pilot pictures' metadata.
##
## Bitmaps come as RGBA (Earthsiege 1: coloured at export) or as 8-bit palette indices (Earthsiege 2:
## coloured here with the cockpit's palette, which differs per Herc). An image may be drawn at a smaller
## size than it is stored: scale_of() (Earthsiege 2's 640x480 art on the 320x240 layout).

const PALETTE_SIZE := 256
const MISSING_COLOR := Color.MAGENTA
const TRANSPARENT_INDEX := 0
## HDD damage list text colours: green above GOOD, yellow above FAIR, else red.
const HEALTH_GOOD := 0.66
const HEALTH_FAIR := 0.33
## PDG image 2 (the small STATUS / TARGET diagram): region component id -> the components whose
## damage the region averages (DBSIM 0x332ab jump table 0x9361c: cockpit = front + rear cockpit,
## a leg = its quad + shin + foot, 13 / 14 = the extra leg parts 13..18).
const SMALL_DIAGRAM_IMAGE := 2
const INTERNAL_IMAGE := 1
const SMALL_DIAGRAM_REGIONS := {0: [0, 1], 4: [4], 5: [5], 6: [6], 7: [7, 9, 11], 8: [8, 10, 12],
	13: [13, 15, 17], 14: [14, 16, 18]}

var pack := "es1"
var skin: CockpitSkin
var palette: Array = []             # Color x 256
var strings: Array = []
var _textures := {}
var _scales := {}                   # Texture2D -> drawn size divisor
var _fonts := {}
var _tinted := {}
var _pdg := {}
var _diagrams := {}                 # key -> [signature, ImageTexture]
var _diagram_sources := {}
var _pilots := {}
var _dba_meta := {}
var _index_lut := PackedByteArray()


## `palette_file`: the cockpit palette, relative to cockpit/ (per Herc in Earthsiege 2).
func _init(p_pack: String, p_skin: CockpitSkin, palette_file := "palette.json") -> void:
	pack = p_pack
	skin = p_skin
	_load_palette(palette_file)
	var s = Assets.load_json("cockpit/strings0.json", pack)
	strings = s if s is Array else []


## CRT gamma (remake display setting) applied to the cockpit palette, bitmaps and fonts alike.
var gamma := DisplaySettings.crt_gamma()


## The palette as stored on disc (no display gamma): bitmap recolouring matches pixels against it.
var raw_palette := PackedColorArray()


func _load_palette(palette_file: String) -> void:
	var p = Assets.load_json("cockpit/" + palette_file, pack)
	palette.clear()
	raw_palette.clear()
	for i in PALETTE_SIZE:
		var e = p[i] if p is Array and i < p.size() else [i, i, i]
		raw_palette.append(Color8(int(e[0]), int(e[1]), int(e[2])))
		palette.append(DisplaySettings.make_corrected(raw_palette[i], gamma))


func raw_color(i: int) -> Color:
	return raw_palette[i] if i >= 0 and i < raw_palette.size() else MISSING_COLOR


func color(i: int) -> Color:
	return palette[i] if i >= 0 and i < palette.size() else MISSING_COLOR


## String `i` of strings0 group `group`, or `fallback`.
func text_string(group: int, i: int, fallback := "") -> String:
	if group >= 0 and group < strings.size() and i < strings[group].size():
		return strings[group][i]
	return fallback


## Image `rel` (under cockpit/) as shown: palette-index images coloured, CRT gamma applied.
func make_display_image(rel: String) -> Image:
	var img := Assets.load_image("cockpit/" + rel, pack)
	if img == null:
		return null
	if img.get_format() == Image.FORMAT_L8:
		return _make_colourised(img)
	return DisplaySettings.make_corrected_image(img, gamma)


## Texture of a palette-index image built at run time (e.g. a recoloured HUD bitmap).
func make_index_texture(img: Image) -> ImageTexture:
	return ImageTexture.create_from_image(_make_colourised(img))


## `img` (palette indices) in the display palette (gamma included); index 0 transparent.
func _make_colourised(img: Image) -> Image:
	if _index_lut.is_empty():
		_index_lut = _make_index_lut()
	var src := img.get_data()
	var out := PackedByteArray()
	out.resize(src.size() * 4)
	for i in src.size():
		var k := src[i] * 4
		var o := i * 4
		out[o] = _index_lut[k]
		out[o + 1] = _index_lut[k + 1]
		out[o + 2] = _index_lut[k + 2]
		out[o + 3] = _index_lut[k + 3]
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, out)


func _make_index_lut() -> PackedByteArray:
	var lut := PackedByteArray()
	lut.resize(PALETTE_SIZE * 4)
	for i in PALETTE_SIZE:
		var c: Color = palette[i]
		lut[i * 4] = c.r8
		lut[i * 4 + 1] = c.g8
		lut[i * 4 + 2] = c.b8
		lut[i * 4 + 3] = 0 if i == TRANSPARENT_INDEX else 255
	return lut


## Texture of image `rel`, drawn at 1 / `scale` of its stored size.
func texture(rel: String, scale := 1.0) -> Texture2D:
	if not _textures.has(rel):
		var img := make_display_image(rel)
		var tex: Texture2D = ImageTexture.create_from_image(img) if img else null
		_textures[rel] = tex
		if tex:
			_scales[tex] = scale
	return _textures[rel]


## Makes `tex` (built from one of these bitmaps) drawn at 1 / `scale` of its stored size.
func set_scale_of(tex: Texture2D, scale: float) -> void:
	_scales[tex] = scale


## How many stored pixels make one layout pixel of `tex`.
func scale_of(tex: Texture2D) -> float:
	return _scales.get(tex, 1.0)


## Frame `i` of instrument bitmap DBA `n`.
func dba(n: String, i: int) -> Texture2D:
	if i < 0:
		return null
	return texture("dba/%s/%d.png" % [n, i], float(_meta_of(n).get("scale", 1.0)))


## Number of frames of instrument bitmap DBA `n`.
func dba_count(n: String) -> int:
	return int(_meta_of(n).get("count", 0))


func _meta_of(n: String) -> Dictionary:
	if not _dba_meta.has(n):
		var j = Assets.load_json("cockpit/dba/%s.json" % n, pack)
		_dba_meta[n] = j if j is Dictionary else {}
	return _dba_meta[n]


## {h, chars, img, tex, scale} of cockpit font `n` ({} if missing).
func font(n: String) -> Dictionary:
	if not _fonts.has(n):
		var j = Assets.load_json("cockpit/fonts/%s.json" % n, pack)
		var img := make_display_image("fonts/%s.png" % n)
		if j == null or img == null:
			_fonts[n] = {}
		else:
			_fonts[n] = {"h": int(j.height), "chars": j.chars, "img": img, "tex": ImageTexture.create_from_image(img),
				"scale": float(j.get("scale", 1.0))}
	return _fonts[n]


## Font atlas of `n`, recoloured to `tint` (tint.a == 0: the original colours).
func font_texture(n: String, tint: Color) -> Texture2D:
	var f := font(n)
	if f.is_empty():
		return null
	if tint.a == 0.0:
		return f.tex
	var key := n + tint.to_html()
	if not _tinted.has(key):
		var img: Image = f.img.duplicate()
		for y in img.get_height():
			for x in img.get_width():
				if img.get_pixel(x, y).a > 0.0:
					img.set_pixel(x, y, tint)
		_tinted[key] = ImageTexture.create_from_image(img)
	return _tinted[key]


# ------------------------------------------------------------------ damage diagrams (PDG)

func load_pdg(key: String) -> Dictionary:
	if not _pdg.has(key):
		var j = Assets.load_json("cockpit/pdg/%s.json" % key, pack)
		_pdg[key] = j if j is Dictionary else {}
	return _pdg[key]


## Health (0..1) a diagram region of `u` shows: image 2 averages its components
## (SMALL_DIAGRAM_REGIONS), image 0 shows its component, image 1 (internal systems, not modelled
## separately) the overall integrity.
static func make_component_health(u: Herc, comp: int, image: int) -> float:
	if image == INTERNAL_IMAGE:
		return clampf(u.integrity, 0.0, 1.0)
	if image == SMALL_DIAGRAM_IMAGE and SMALL_DIAGRAM_REGIONS.has(comp):
		return DamageLevels.mean_health(u.components, SMALL_DIAGRAM_REGIONS[comp])
	if comp >= 0 and comp < u.components.size():
		return DamageLevels.component_health(u.components[comp])
	return clampf(u.integrity, 0.0, 1.0)


## Palette colour bases of the damage levels (DamageLevels order) and the shades per level: Earthsiege 1
## three-shade ramps, Earthsiege 2 single colours (skin "damage").
func damage_bases() -> Array:
	var c := skin.list("damage", "colors")
	return c if not c.is_empty() else DamageLevels.RAMP_BASES


func damage_shades() -> int:
	return int(skin.value("damage", "shades", DamageLevels.SHADES))


## PDG image `image` of unit `key` with every region coloured by `u`'s damage (DamageLevels; cached
## until a region changes level).
func diagram(key: String, image: int, u: Herc) -> Texture2D:
	var pdg := load_pdg(key)
	if pdg.is_empty() or image >= pdg.images.size():
		return null
	var regions: Array = pdg.images[image].regions
	var levels := []
	for reg in regions:
		levels.append(DamageLevels.level_of(make_component_health(u, int(reg.component), image)))
	var ck := "%s/%d" % [key, image]
	if _diagrams.has(ck) and _diagrams[ck][0] == levels:
		return _diagrams[ck][1]
	if not _diagram_sources.has(ck):
		_diagram_sources[ck] = _load_diagram_source(key, image)
	var src: Image = _diagram_sources[ck]
	if src == null:
		return null
	# recolour in the original colours (exact pixel matches), then apply the display gamma
	var scale := float(pdg.get("scale", 1.0))
	var tex := ImageTexture.create_from_image(DisplaySettings.make_corrected_image(_make_recoloured(src, regions, levels, scale), gamma))
	_scales[tex] = scale
	_diagrams[ck] = [levels, tex]
	return tex


## The diagram bitmap in raw palette colours (no gamma: the recolour matches original colours).
func _load_diagram_source(key: String, image: int) -> Image:
	var img := Assets.load_image("cockpit/pdg/%s_%d.png" % [key, image], pack)
	if img == null or img.get_format() != Image.FORMAT_L8:
		return img
	var raw := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var i := img.get_pixel(x, y).r8
			if i != TRANSPARENT_INDEX:
				raw.set_pixel(x, y, raw_palette[i])
	return raw


## The original's region recolour (DBSIM 0x308f0; ES2 0x437e94), region by region on one bitmap: inside
## the region rect (layout pixels x `scale`), pixels of the region's drawn colours (colour .. colour + shades
## - 1) move to the level's colours, keeping their shade. Regions sharing a rect: the first one that changes
## the colour wins.
func _make_recoloured(src: Image, regions: Array, levels: Array, scale: float) -> Image:
	var img: Image = src.duplicate()
	var bases := damage_bases()
	for r in regions.size():
		var reg: Dictionary = regions[r]
		var old_base := int(reg.color)
		var new_base := int(bases[levels[r]])
		if new_base != old_base:
			_shift_ramp(img, _scaled_rect(reg.rect, scale), old_base, new_base)
	return img


static func _scaled_rect(rc: Array, scale: float) -> Array:
	if is_equal_approx(scale, 1.0):
		return rc
	return [int(rc[0] * scale), int(rc[1] * scale), int((rc[2] + 1) * scale) - 1, int((rc[3] + 1) * scale) - 1]


func _shift_ramp(img: Image, rc: Array, old_base: int, new_base: int) -> void:
	var from := {}
	for k in damage_shades():
		from[raw_color(old_base + k).to_rgba32()] = raw_color(new_base + k)
	for y in range(maxi(int(rc[1]), 0), mini(int(rc[3]) + 1, img.get_height())):
		for x in range(maxi(int(rc[0]), 0), mini(int(rc[2]) + 1, img.get_width())):
			var p := img.get_pixel(x, y)
			if p.a > 0.0 and from.has(p.to_rgba32()):
				img.set_pixel(x, y, from[p.to_rgba32()])


## pilots/PILOT<n>.json metadata (null if missing).
func pilot_meta(pilot: int) -> Variant:
	if not _pilots.has(pilot):
		_pilots[pilot] = Assets.load_json("cockpit/pilots/PILOT%d.json" % pilot, pack)
	return _pilots[pilot]

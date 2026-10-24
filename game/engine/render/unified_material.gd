class_name UnifiedMaterial
extends RefCounted
## Builds the shared runtime material (shaders/unified_*.gdshader) from a game's palette / texture data.
## The prototype bakes at load time what the importers will write to disk (docs/RENDER_UNIFICATION.md section 2):
## palette-indexed art becomes true-colour layers, one per light level, so the palette lookup, the ramp tables
## and the game's colour handling are gone from drawing.

const SHADER_NEAREST := preload("res://engine/shaders/unified_nearest.gdshader")
const SHADER_NEAREST_UNHAZED := preload("res://engine/shaders/unified_nearest_unhazed.gdshader")
const SHADER_LIT := preload("res://engine/shaders/unified_lit.gdshader")
const SHADER_LIT_BLEND := preload("res://engine/shaders/unified_lit_blend.gdshader")
const SHADER_LIT_ADD := preload("res://engine/shaders/unified_lit_add.gdshader")
const SHADER_LIT_LIGHTMAP := preload("res://engine/shaders/unified_lit_lightmap.gdshader")
const SHADE_LEVELS := 32
const FLAG_TRANSLUCENT := 4
const FLAG_ADDITIVE := 8
const FLAG_SELF_ILLUMINATING := 32

static var _cache := {}
static var _lightmap_cache := {}   # lightmap file -> ImageTexture (a page is shared by the many materials of its sections)
## Folder holding a `unified/` directory of baked strips instead of the pack's own (verification of scratch bakes).
static var bake_root := ""
## Texture memory of the baked arrays (RenderUnified memory check): {arrays, bytes}.
static var stats := {"arrays": 0, "bytes": 0}


## Material for a 3Space colour descriptor {kind: tex|shade|solid, index}; same arguments as Palette.material.
static func from_palette(palette_id: String, m: Dictionary, texset_key := "", texset: Array = []) -> Material:
	var key := "p|%s|%s|%d|%s" % [palette_id, m.kind, int(m.index), texset_key]
	if _cache.has(key):
		return _cache[key]
	var look := Palette.look(palette_id)
	var pal: Image = (look.palette as ImageTexture).get_image()
	var idx := int(m.index)
	var layers: Array[Image] = []
	var levels := 0
	var scale := 0.0
	var alpha_cut := 0.0
	if m.kind == "tex" and idx < texset.size():
		var tex_light: Image = (look.texlight as ImageTexture).get_image()
		levels = tex_light.get_height()
		scale = float(levels - 1)
		alpha_cut = 0.5
		var index_img := (texset[idx] as ImageTexture).get_image()
		layers = _load_baked_levels(palette_id, texset_key, idx, levels, index_img.get_size())
		if layers.is_empty():   # no importer-baked strip (old import): bake at load time
			layers = _bake_texture_levels(index_img, tex_light, pal)
	elif m.kind == "shade":
		var lists: Image = (look.shade as ImageTexture).get_image()
		levels = SHADE_LEVELS
		scale = float(SHADE_LEVELS)
		for col in SHADE_LEVELS:
			layers.append(_pixel(pal, int(lists.get_pixel(col, clampi(idx, 0, 255)).r8)))
	else:
		layers.append(_pixel(pal, clampi(idx, 0, 255)))
		levels = 1
		scale = 1.0
	var shader := SHADER_NEAREST
	if m.kind == "tex" and str(Assets.split_id(palette_id)[0]) in Palette.UNHAZED_TEXTURE_PACKS:
		shader = SHADER_NEAREST_UNHAZED
	var mat := _make(shader, layers, false)
	mat.set_shader_parameter("ramp_levels", levels)
	mat.set_shader_parameter("ramp_scale", scale)
	mat.set_shader_parameter("alpha_cut", alpha_cut)
	if m.kind != "tex" and m.kind != "shade":
		mat.set_shader_parameter("self_lit", true)   # solid polys are drawn flat by the originals
	_cache[key] = mat
	return mat


## Material for a true-colour Torque material {name, texture, flags}: lit by the scene, or additive / alpha-blended
## (damage decals, hidden until a damage state shows them) per its flags.
static func from_rgba(pack: String, md: Dictionary) -> Material:
	if String(md.get("lightmap", "")) != "":
		return from_lightmapped(pack, md)
	var flags := int(md.get("flags", 0))
	var decal := String(md.get("name", "")).contains("damage")
	var key := "t|%s|%s|%d|%s" % [pack, md.get("texture", ""), flags, decal]
	if _cache.has(key):
		return _cache[key]
	var mat := from_texture(pack, String(md.get("texture", "")), flags, decal)
	if mat != null:
		_cache[key] = mat
	return mat


## Material of a texture with a baked lightmap {texture, lightmap}: the surface shows texture x lightmap, takes no scene light.
static func from_lightmapped(pack: String, md: Dictionary) -> Material:
	var key := "m|%s|%s|%s" % [pack, md.get("texture", ""), md.get("lightmap", "")]
	if _cache.has(key):
		return _cache[key]
	var img := Assets.load_image(String(md.get("texture", "")), pack)
	var lightmap := _load_lightmap(pack, String(md.lightmap))
	if img == null or lightmap == null:
		return null
	img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	var mat := _make(SHADER_LIT_LIGHTMAP, [img] as Array[Image], true)
	mat.set_shader_parameter("lightmap", lightmap)
	_cache[key] = mat
	return mat


static func _load_lightmap(pack: String, file: String) -> Texture2D:
	var cache_key := "%s|%s" % [pack, file]
	if not _lightmap_cache.has(cache_key):
		var img := Assets.load_image(file, pack)
		if img == null:
			return null
		img.convert(Image.FORMAT_RGB8)
		img.generate_mipmaps()
		_lightmap_cache[cache_key] = ImageTexture.create_from_image(img)
	return _lightmap_cache[cache_key]


## Lit material of a plain texture file (skins: SkinCatalog texture overrides; Torque flags optional).
static func from_texture(pack: String, file: String, flags := 0, decal := false) -> Material:
	var key := "f|%s|%s|%d|%s" % [pack, file, flags, decal]
	if _cache.has(key):
		return _cache[key]
	var img := Assets.load_image(file, pack)
	if img == null:
		return null
	img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	var shader := SHADER_LIT
	if decal:
		shader = SHADER_LIT_BLEND
	elif flags & FLAG_ADDITIVE:
		shader = SHADER_LIT_ADD
	var mat := _make(shader, [img] as Array[Image], true)
	mat.set_shader_parameter("self_lit", bool(flags & FLAG_SELF_ILLUMINATING))
	mat.set_shader_parameter("alpha_cut", 0.5 if flags & FLAG_TRANSLUCENT and not decal and not (flags & FLAG_ADDITIVE) else 0.0)
	if decal:
		mat.set_shader_parameter("alpha_mul", 0.0)   # hidden until damaged
	_cache[key] = mat
	return mat


static func _make(shader: Shader, layers: Array[Image], _mips: bool) -> ShaderMaterial:
	var arr := Texture2DArray.new()
	arr.create_from_images(layers)
	stats.arrays += 1
	for l in layers:
		stats.bytes += l.get_data().size()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("albedo_array", arr)
	return mat


static func _pixel(pal: Image, i: int) -> Image:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, pal.get_pixel(i, 0))
	return img


## The importer-baked strip (tools/unified_bake.py) of an indexed texture, cut into one image per light level;
## empty when it is missing or does not fit (wrong size or level count).
static func _load_baked_levels(palette_id: String, texset_key: String, idx: int, levels: int, size: Vector2i) -> Array[Image]:
	var out: Array[Image] = []
	var pack := texset_key.get_slice("/", 0)
	var texset := texset_key.get_slice("/", 1).split(":")[-1]
	var rel := "unified/%s__%s__%d.png" % [Assets.qualify(palette_id).replace(":", "_"), texset, idx]
	var file := bake_root.path_join(rel) if bake_root != "" else Assets.path(rel, pack)
	if not FileAccess.file_exists(file):
		return out
	var strip := Image.load_from_file(file)
	if strip == null or strip.get_width() != size.x or strip.get_height() != size.y * levels:
		return out
	strip.convert(Image.FORMAT_RGBA8)
	for level in levels:
		out.append(strip.get_region(Rect2i(0, level * size.y, size.x, size.y)))
	return out


## One RGBA layer per light level: palette[texlight[level][index]]; index 0 is transparent.
static func _bake_texture_levels(index_img: Image, tex_light: Image, pal: Image) -> Array[Image]:
	index_img.convert(Image.FORMAT_L8)
	tex_light.convert(Image.FORMAT_L8)
	pal.convert(Image.FORMAT_RGBA8)
	var idx := index_img.get_data()
	var light := tex_light.get_data()
	var pdata := pal.get_data()
	var w := index_img.get_width()
	var h := index_img.get_height()
	var out: Array[Image] = []
	for level in tex_light.get_height():
		var rgba := PackedByteArray()
		rgba.resize(w * h * 4)
		var lut := PackedInt32Array()
		lut.resize(256)
		for i in 256:
			lut[i] = light[level * 256 + i]
		for p in w * h:
			var src := idx[p]
			var pi := lut[src] * 4
			rgba[p * 4] = pdata[pi]
			rgba[p * 4 + 1] = pdata[pi + 1]
			rgba[p * 4 + 2] = pdata[pi + 2]
			rgba[p * 4 + 3] = 0 if src == 0 else 255
		out.append(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba))
	return out

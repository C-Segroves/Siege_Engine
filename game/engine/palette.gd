class_name Palette
extends RefCounted
## Per-palette rendering "look": palette texture plus the original lighting lookup tables
## (shade lists for shaded polys, light remap tables for textured polys).

## Games whose textured polys take no distance haze (Earthsiege 1, DBSIM 0x5410c: textures are not
## ramp-indexed; docs/formats/world.md section 4). Earthsiege 2 hazes them through its RMP haze rows.
const UNHAZED_TEXTURE_PACKS := ["es1"]
const HAZED_TEXTURE_SHADER := preload("res://engine/shaders/indexed.gdshader")
const UNHAZED_TEXTURE_SHADER := preload("res://engine/shaders/indexed_unhazed.gdshader")

static var _looks := {}
static var _identity_shade: ImageTexture
static var _identity_light: ImageTexture
static var _materials := {}


## Returns {palette, shade, texlight} textures for a qualified palette id ("es1:WORLD4").
static func look(palette_id: String) -> Dictionary:
	palette_id = Assets.qualify(palette_id)
	if _looks.has(palette_id):
		return _looks[palette_id]
	var p := Assets.split_id(palette_id)
	var n := String(p[1]).trim_prefix("WORLD")
	var l := {"palette": Assets.palette_texture(palette_id)}
	var shade: Image = null
	var light: Image = null
	if n.is_valid_int():
		shade = Assets.load_image("worlds/shade_%s.png" % n, p[0])
		light = Assets.load_image("worlds/texlight_%s.png" % n, p[0])
	if shade == null:
		shade = Assets.load_image("looks/%s_shade.png" % p[1], p[0])
		light = Assets.load_image("looks/%s_texlight.png" % p[1], p[0])
	l["shade"] = ImageTexture.create_from_image(_l8(shade)) if shade else _identity_shade_tex()
	l["texlight"] = ImageTexture.create_from_image(_l8(light)) if light else _identity_light_tex()
	_looks[palette_id] = l
	return l


static func _l8(img: Image) -> Image:
	if img.get_format() != Image.FORMAT_L8:
		img.convert(Image.FORMAT_L8)
	return img


static func _identity_shade_tex() -> ImageTexture:
	if _identity_shade == null:
		var img := Image.create(32, 256, false, Image.FORMAT_L8)
		for r in 256:
			for c in 32:
				img.set_pixel(c, r, Color8(r, r, r))
		_identity_shade = ImageTexture.create_from_image(img)
	return _identity_shade


static func _identity_light_tex() -> ImageTexture:
	if _identity_light == null:
		var img := Image.create(256, 8, false, Image.FORMAT_L8)
		for l in 8:
			for c in 256:
				img.set_pixel(c, l, Color8(c, c, c))
		_identity_light = ImageTexture.create_from_image(img)
	return _identity_light


## The textured-poly shader of the world palette `palette_id` ("es1:WORLD4"): hazed unless its game draws
## textures without haze.
static func make_texture_shader(palette_id: String) -> Shader:
	var pack := str(Assets.split_id(palette_id)[0])
	return UNHAZED_TEXTURE_SHADER if pack in UNHAZED_TEXTURE_PACKS else HAZED_TEXTURE_SHADER


## Material for a 3Space colour descriptor {kind: tex|shade|solid, index}.
static func material(palette_id: String, m: Dictionary, texset_key := "", texset: Array = []) -> Material:
	var key := "%s|%s|%d|%s" % [palette_id, m.kind, int(m.index), texset_key]
	if _materials.has(key):
		return _materials[key]
	var l := look(palette_id)
	var mat: Material
	var idx := int(m.index)
	if m.kind == "tex" and idx < texset.size():
		var sm := ShaderMaterial.new()
		sm.shader = make_texture_shader(palette_id)
		sm.set_shader_parameter("index_tex", texset[idx])
		sm.set_shader_parameter("palette", l.palette)
		sm.set_shader_parameter("tex_light", l.texlight)
		mat = sm
	elif m.kind == "shade":
		var sm := ShaderMaterial.new()
		sm.shader = preload("res://engine/shaders/shaded.gdshader")
		sm.set_shader_parameter("palette", l.palette)
		sm.set_shader_parameter("shade_lists", l.shade)
		sm.set_shader_parameter("list_index", clampi(idx, 0, 255))
		mat = sm
	else:
		var std := StandardMaterial3D.new()
		std.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		std.albedo_color = Assets.palette_color(palette_id, clampi(idx, 0, 255))
		mat = std
	_materials[key] = mat
	return mat

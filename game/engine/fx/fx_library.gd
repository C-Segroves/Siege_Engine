class_name FxLibrary
extends RefCounted
## Weapon visual-effect data of every pack (docs/formats/weapon_fx.md): the pack effect library
## (gamedata/<pack>/fx/effects.json: sprites + effects) and each weapon's `fx` block.
##
## Sprites are loaded once into textures. Indexed sprites (8-bit DOS packs) are expanded through their
## palette with the remake's CRT gamma (DisplaySettings), the same as the cockpit and shell, so the
## cache is keyed by the palette and the gamma in use. Earthsiege 1/2 blit effect bitmaps and beam texels
## unchanged into the frame buffer (ES1 TSBitmapPart 0x52b90 -> 0x67178 only decompresses; ES2 span drawer
## 0x46ab10), so they show in the mission's WORLD<n> palette: sprites and beams marked `palette_per_world`
## and every `palette_index` colour use the world palette the battle sets (set_world_palette). A weapon without an `fx` block gets a generic look built from
## its kind and colour (marked "fallback": weapon_fx_check reports those as missing data).

## Frame rate when a sprite gives none (frames per second).
const DEFAULT_FPS := 15.0
const EMPTY_LIBRARY := {"sprites": {}, "effects": {}}
const SURFACES := ["miss", "shield", "armor", "water"]
## Generic look of weapons without data (fallback only).
const FALLBACK_TRACER_LENGTH := 1.6
const FALLBACK_BOLT_SIZE := 0.9
const FALLBACK_BEAM_WIDTH := 0.18
const FALLBACK_BEAM_SECONDS := 0.12
const FALLBACK_SMOKE := [0.75, 0.75, 0.72, 0.6]
const FALLBACK_TRAIL_INTERVAL := 0.06
const FALLBACK_PUFF_SIZE := 0.8
const FALLBACK_PUFF_SECONDS := 0.8

static var _libraries := {}     # pack -> library Dictionary
static var _sprites := {}       # "<pack>:<name>@<gamma>" -> sprite resource Dictionary
static var _fallback_fx := {}   # weapon id -> generated fx block
static var _textures := {}      # "<pack>:<path>@<palette>@<gamma>" -> Texture2D (beam / trail bitmaps)
static var _world_palettes := {}  # pack -> palette name of the battle's world ("WORLD4")


static func clear_cache() -> void:
	_libraries.clear()
	_sprites.clear()
	_fallback_fx.clear()
	_textures.clear()


## The palette of the world being played ("es1:WORLD4"): per-world effect bitmaps and palette-index colours
## of that pack are drawn through it until another world is set.
static func set_world_palette(palette_id: String) -> void:
	var p := Assets.split_id(Assets.qualify(palette_id))
	_world_palettes[p[0]] = p[1]


static func clear_world_palettes() -> void:
	_world_palettes.clear()


## Palette name a sprite / beam block `d` of `pack` is drawn with: the world's when it follows the world.
static func make_palette_name(d: Dictionary, pack: String) -> String:
	if bool(d.get("palette_per_world", false)) and _world_palettes.has(pack):
		return str(_world_palettes[pack])
	return str(d.get("palette", ""))


## Colour of an fx block: a `palette_index` (ES1/ES2 beams, tracers) is looked up in the world's palette with
## the CRT gamma, keeping the block colour's alpha; otherwise the block `color` (or `fallback`).
static func make_block_color(block: Dictionary, pack: String, fallback := Color.WHITE) -> Color:
	var color := make_color(block.get("color"), fallback)
	var index = block.get("palette_index")
	if not (index is int or index is float):
		return color
	var name := make_palette_name({"palette": block.get("palette", ""), "palette_per_world": true}, pack)
	if name == "":
		name = Packs.default_palette(pack).get_slice(":", 1)
	var colors := _palette_colors({"palette": name}, pack, DisplaySettings.crt_gamma())
	if int(index) < 0 or int(index) >= colors.size():
		return color
	var c: Color = colors[int(index)]
	return Color(c.r, c.g, c.b, color.a)


## The pack's effect library ({} parts when the pack has none).
static func library(pack: String) -> Dictionary:
	if not _libraries.has(pack):
		var j = Assets.load_json("fx/effects.json", pack)
		_libraries[pack] = j if j is Dictionary else EMPTY_LIBRARY.duplicate(true)
	return _libraries[pack]


## [pack, name] of a reference that may be qualified "<pack>:<name>".
static func split_ref(ref: String, pack: String) -> Array:
	var i := ref.find(":")
	return [ref.substr(0, i), ref.substr(i + 1)] if i >= 0 else [pack, ref]


## An effect definition ({} when unknown); its "pack" key names the pack it came from.
static func effect(ref: String, pack: String) -> Dictionary:
	if ref == "":
		return {}
	var p := split_ref(ref, pack)
	var e = library(p[0]).get("effects", {}).get(p[1])
	if not (e is Dictionary):
		return {}
	var out: Dictionary = e
	out["pack"] = p[0]
	return out


## A death entry {"steps", "source"} of `pack` (the library's "deaths" block, weapon_fx.md section 9): the
## first of `keys` found in the kind's per-key map ("<kind>s", e.g. "vehicles"), else the kind's default;
## {} when the pack exported none.
static func death(pack: String, kind: String, keys: Array = []) -> Dictionary:
	var deaths = library(pack).get("deaths")
	if not (deaths is Dictionary):
		return {}
	var by_key = deaths.get(kind + "s")
	if by_key is Dictionary:
		for k in keys:
			if by_key.get(str(k)) is Dictionary:
				return by_key[str(k)]
	return deaths[kind] if deaths.get(kind) is Dictionary else {}


static func has_sprite(ref: String, pack: String) -> bool:
	var p := split_ref(ref, pack)
	return library(p[0]).get("sprites", {}).has(p[1])


## A sprite ready to draw: {"textures": [Texture2D], "sizes": [Vector2i px], "origins": [Vector2 px],
## "fps", "loop", "metres_per_pixel", "frame_metres_per_pixel", "phases", "phase_frames", "blend", "pixel_art"}; {} when unknown or its frames are missing.
static func sprite(ref: String, pack: String) -> Dictionary:
	var p := split_ref(ref, pack)
	var d = library(p[0]).get("sprites", {}).get(p[1])
	if not (d is Dictionary):
		return {}
	var gamma := DisplaySettings.crt_gamma()
	var palette := make_palette_name(d, p[0])
	var key := "%s:%s@%s@%.3f" % [p[0], p[1], palette, gamma]
	if not _sprites.has(key):
		_sprites[key] = _load_sprite(p[0], p[1], {"palette": palette, "gamma": gamma})
	return _sprites[key]


## `look` = {"palette": palette name the indexed frames are expanded through, "gamma"}.
static func _load_sprite(pack: String, name: String, look: Dictionary) -> Dictionary:
	var d: Dictionary = library(pack).sprites[name]
	var indexed := str(d.get("format", "rgba")) == "indexed"
	var colors := _palette_colors(look, pack, float(look.gamma)) if indexed else []
	var textures := []
	var sizes := []
	for rel in d.get("frames", []):
		var img := Assets.load_image(str(rel), pack)
		if img == null:
			push_error("fx sprite %s:%s: missing frame %s" % [pack, name, rel])
			return {}
		img = _expand_indexed(img, colors, int(d.get("transparent_index", 0))) if indexed else img
		textures.append(ImageTexture.create_from_image(img))
		sizes.append(Vector2i(img.get_width(), img.get_height()))
	if textures.is_empty():
		return {}
	return {"textures": textures, "sizes": sizes, "origins": _origins(d, sizes),
		"fps": float(d.get("fps", DEFAULT_FPS)), "loop": bool(d.get("loop", false)),
		"metres_per_pixel": float(d.get("metres_per_pixel", 0.0)),
		"frame_metres_per_pixel": _frame_scales(d, sizes.size()),
		"phases": maxi(1, int(d.get("phases", 1))), "phase_frames": int(d.get("phase_frames", sizes.size())),
		"blend": str(d.get("blend", "alpha")), "pixel_art": indexed}


## A beam / trail texture (pack-relative path); `format` "indexed" expands it through `palette` with the
## CRT gamma. Cached; null when the file is missing.
## `across` turns the bitmap a quarter so its width runs across the beam (Darkstar bitmaps whose length runs along V).
static func texture(rel: String, pack: String, format: String, palette: String, across := false) -> Texture2D:
	var gamma := DisplaySettings.crt_gamma()
	var key := "%s:%s@%s@%.3f%s" % [pack, rel, palette, gamma, "/across" if across else ""]
	if not _textures.has(key):
		var img := Assets.load_image(rel, pack)
		if img == null:
			push_error("fx texture missing: %s:%s" % [pack, rel])
		elif format == "indexed":
			img = _expand_indexed(img, _palette_colors({"palette": palette}, pack, gamma), 0)
		if img and across:
			img.rotate_90(CLOCKWISE)
		_textures[key] = ImageTexture.create_from_image(img) if img else null
	return _textures[key]


## Palette colours as displayed (CRT gamma), index -> Color.
static func _palette_colors(d: Dictionary, pack: String, gamma: float) -> Array:
	var out := []
	var pal: Array = Assets.palette("%s:%s" % [pack, d.get("palette", "")])
	for c in pal:
		out.append(DisplaySettings.make_corrected(Color8(int(c[0]), int(c[1]), int(c[2])), gamma))
	return out


## An 8-bit index image (value = palette index) as RGBA; `transparent` index drawn clear.
static func _expand_indexed(src: Image, colors: Array, transparent: int) -> Image:
	if src.get_format() != Image.FORMAT_L8:
		src.convert(Image.FORMAT_L8)
	var w := src.get_width()
	var h := src.get_height()
	var data := src.get_data()
	var out := PackedByteArray()
	out.resize(w * h * 4)
	for i in w * h:
		var idx := data[i]
		if idx == transparent or idx >= colors.size():
			continue
		var c: Color = colors[idx]
		out[i * 4] = c.r8
		out[i * 4 + 1] = c.g8
		out[i * 4 + 2] = c.b8
		out[i * 4 + 3] = 255
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, out)


## World metres per pixel of each frame (Battledrome: radius / 64 per bitmap part), else the sprite's one.
static func _frame_scales(d: Dictionary, count: int) -> Array:
	var given: Array = d.get("frame_metres_per_pixel", []) if d.get("frame_metres_per_pixel") is Array else []
	var out := []
	for i in count:
		out.append(float(given[i]) if i < given.size() else float(d.get("metres_per_pixel", 0.0)))
	return out


## Anchor pixel per frame: the sprite's "origins", else the frame centre.
static func _origins(d: Dictionary, sizes: Array) -> Array:
	var given: Array = d.get("origins", []) if d.get("origins") is Array else []
	var out := []
	for i in sizes.size():
		if i < given.size() and given[i] is Array and given[i].size() >= 2:
			out.append(Vector2(float(given[i][0]), float(given[i][1])))
		else:
			out.append(Vector2(sizes[i]) * 0.5)
	return out


# ------------------------------------------------------------------ weapon fx blocks

## The weapon's `fx` block; a generated generic look (with "fallback": true) when it has none.
static func weapon_fx(def: Dictionary) -> Dictionary:
	if def.get("fx") is Dictionary:
		return def.fx
	var id := str(def.get("id", def.get("name", "?")))
	if not _fallback_fx.has(id):
		_fallback_fx[id] = make_fallback_fx(def)
	return _fallback_fx[id]


static func is_fallback(fx: Dictionary) -> bool:
	return bool(fx.get("fallback", false))


## Pack the weapon's effect names resolve in (cross-game weapons keep their own game's look).
static func weapon_pack(def: Dictionary) -> String:
	return str(def.get("pack", Assets.split_id(str(def.get("id", "")))[0]))


## Effect names for a hit on `surface`, falling back armour -> miss when the weapon names none for it.
static func impact_effects(fx: Dictionary, surface: String) -> Array:
	var impact: Dictionary = fx.get("impact", {}) if fx.get("impact") is Dictionary else {}
	for s in [surface, "armor", "miss"]:
		var list = impact.get(s)
		if list is Array and not list.is_empty():
			return list
	return []


## Generic look from the weapon's kind and colour, for weapons whose pack exported no fx data.
static func make_fallback_fx(def: Dictionary) -> Dictionary:
	var color := _weapon_color(def)
	var kind := str(def.get("kind", "cannon"))
	var fx := {"fallback": true, "projectile": null, "beam": null, "trail": null, "muzzle": null,
		"impact": {"miss": ["@spark"], "shield": ["@spark"], "armor": ["@spark"]}}
	if kind in ["beam", "emp", "flame"]:
		fx.beam = {"color": color, "width": FALLBACK_BEAM_WIDTH, "duration": FALLBACK_BEAM_SECONDS, "style": "solid", "glow": true}
		return fx
	var pr: Dictionary = def.projectile if def.get("projectile") is Dictionary else {}
	var guided := str(pr.get("guidance", "none")) != "none"
	var heavy := kind in ["missile", "grenade", "artillery", "mine", "bomb"] or float(def.get("splash", 0.0)) > 0.0
	fx.projectile = {"sprite": null, "shape": pr.get("shape") if pr.get("shape") is String else null, "color": color,
		"size": FALLBACK_TRACER_LENGTH if kind == "cannon" else FALLBACK_BOLT_SIZE,
		"face": "velocity" if kind == "cannon" else "billboard"}
	var trail := str(pr.get("trail", "smoke" if guided or kind == "missile" else "none"))
	if trail != "none":
		var puff: Array = FALLBACK_SMOKE if trail == "smoke" else color
		fx.trail = {"effect": null, "interval": FALLBACK_TRAIL_INTERVAL, "style": "puffs", "color": puff,
			"size": FALLBACK_PUFF_SIZE, "lifetime": FALLBACK_PUFF_SECONDS}
	if heavy:
		fx.impact = {"miss": ["@explosion"], "shield": ["@explosion"], "armor": ["@explosion"]}
	return fx


static func _weapon_color(def: Dictionary) -> Array:
	for block in [def.get("beam"), def.get("projectile")]:
		if block is Dictionary and block.get("color") is Array and block.color.size() >= 3:
			return block.color
	return [1.0, 0.85, 0.4, 1.0]


## Colour from a data array [r, g, b] or [r, g, b, a] (0..1); `fallback` when absent.
static func make_color(v: Variant, fallback := Color.WHITE) -> Color:
	if v is Array and v.size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]), float(v[3]) if v.size() > 3 else 1.0)
	return fallback

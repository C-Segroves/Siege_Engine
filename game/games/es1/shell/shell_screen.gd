class_name ShellScreen
extends Control
## The shell's virtual VGA mode 13h display: a 320x200 8-bit frame buffer (LA8 image, L = palette index)
## shown through a palette shader and letterboxed into the window. Scaling is "sharp bilinear": the
## frame is first drawn at a whole-number scale with nearest filtering (crisp, every source pixel the
## same size), then that image is resized to the window with linear filtering, so odd window sizes
## (e.g. 5.4x at 1920x1080) don't make some pixels wider than others.
## Also owns the 256-colour palette (with TTM-style palette fades) and the original mouse cursor.
## Palette colours are shown through the remake's CRT gamma (DisplaySettings) — the frame buffer
## and palettes themselves stay exact.

const W := 320
const H := 200

const PALETTE_SHADER := """
shader_type canvas_item;
uniform sampler2D pal : filter_nearest;
void fragment() {
	float i = texture(TEXTURE, UV).r;
	// alpha 0 = see-through to the underlay (the 3D hangar behind the career hangar menus)
	COLOR = vec4(texture(pal, vec2((floor(i * 255.0 + 0.5) + 0.5) / 256.0, 0.5)).rgb, step(0.5, texture(TEXTURE, UV).a));
}
"""

## Frame buffer the current page draws into (cursor is added on presentation).
var image: Image
var overlay: TextureRect          # RGBA layer above the frame buffer (blast-door ANM frames)
## Control drawn under the frame buffer at 320x200 (shows through pixels with alpha 0), e.g. HangarView.
var underlay: Control
var cursor_visible := true
var cursor_pos := Vector2i(160, 100)

var _view: TextureRect
var _frame: Control                       # the 320x200 page, drawn at a whole-number scale in _canvas
var _canvas: SubViewport                  # integer-scaled render of _frame
var _display: TextureRect                 # _canvas resized to the window (linear filtering)
var _display_scale := 1.0                 # window pixels per virtual pixel
var _tex: ImageTexture
var _out: Image
var _pal_img: Image
var _pal_tex: ImageTexture
var _target := PackedColorArray()       # palette as loaded
var _level := PackedFloat32Array()      # per index: 1 = true colour, 0 = fade colour
var _fade_col := PackedColorArray()     # per index: colour faded from / to
var _fades: Array = []                  # running fades
var _pal_dirty := true
var _gamma := 0.0                         # CRT gamma the palette texture was built with
var _cursor: Image
var _cursor_hot := Vector2i.ZERO


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg = ColorRect.new()
	var bg := _bg
	bg.color = Color.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_build_canvas()
	image = ShellData.new_screen()
	_out = image.duplicate()
	_tex = ImageTexture.create_from_image(_out)
	_pal_img = Image.create(256, 1, false, Image.FORMAT_RGBA8)
	_pal_tex = ImageTexture.create_from_image(_pal_img)
	_view = TextureRect.new()
	_view.texture = _tex
	_view.size = Vector2(W, H)
	_view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = PALETTE_SHADER
	mat.shader = sh
	mat.set_shader_parameter("pal", _pal_tex)
	_view.material = mat
	_frame.add_child(_view)
	overlay = TextureRect.new()
	overlay.size = Vector2(W, H)
	overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.visible = false
	_frame.add_child(overlay)
	_gamma = DisplaySettings.crt_gamma()
	_target.resize(256)
	_level.resize(256)
	_fade_col.resize(256)
	for i in 256:
		_target[i] = Color8(i, i, i)
		_level[i] = 1.0
		_fade_col[i] = Color.BLACK
	set_cursor("ARROW")
	resized.connect(_layout)
	_layout()


func _build_canvas() -> void:
	_canvas = SubViewport.new()
	_canvas.size = Vector2i(W, H)
	_canvas.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_canvas.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(_canvas)
	_frame = Control.new()
	_frame.size = Vector2(W, H)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_frame)
	_display = TextureRect.new()
	_display.texture = _canvas.get_texture()
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_display.stretch_mode = TextureRect.STRETCH_SCALE
	_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_display)


var _laid_out_for := Vector2(-1, -1)
var _bg: ColorRect


func _layout() -> void:
	var area := size
	if area.x < 1.0 or area.y < 1.0:
		area = get_viewport_rect().size
	_laid_out_for = area
	_bg.position = Vector2.ZERO
	_bg.size = area
	var s: float = minf(area.x / W, area.y / H)
	if s <= 0.0:
		s = 1.0
	var whole := maxi(1, int(floor(s)))
	_canvas.size = Vector2i(W * whole, H * whole)
	_frame.scale = Vector2(whole, whole)
	_display_scale = s
	_display.size = Vector2(W, H) * s
	_display.position = ((area - _display.size) * 0.5).floor()


## Window position -> virtual 320x200 pixel.
func to_virtual(p: Vector2) -> Vector2i:
	var v := (p - _display.position) / _display_scale
	return Vector2i(clampi(int(floor(v.x)), 0, W - 1), clampi(int(floor(v.y)), 0, H - 1))


## Virtual pixel -> window position (centre of the pixel).
func to_window(v: Vector2i) -> Vector2:
	return _display.position + (Vector2(v) + Vector2(0.5, 0.5)) * _display_scale


func set_cursor(cursor_name: String) -> void:
	_cursor = ShellData.image("cursors/%s.png" % cursor_name)
	var j = ShellData.json("cursors/cursors.json")
	if j is Dictionary and j.has(cursor_name):
		_cursor_hot = Vector2i(int(j[cursor_name].hotspot[0]), int(j[cursor_name].hotspot[1]))


# ------------------------------------------------------------------ palette

func set_palette(colors: PackedColorArray, keep_fade := true) -> void:
	_target = colors.duplicate()
	if not keep_fade:
		for i in 256:
			_level[i] = 1.0
		_fades.clear()
	_pal_dirty = true


func palette_color(index: int) -> Color:
	return _target[clampi(index, 0, 255)]


## TTM FADE_IN / FADE_OUT: indices [first, first+count) go from / to the colour of index `color_index`.
## Returns the fade duration in seconds (speed 0 = instant).
func fade(fade_in: bool, first: int, count: int, color_index: int, speed: int) -> float:
	var c := _target[clampi(color_index, 0, 255)]
	var last := clampi(first + count, 0, 256)
	first = clampi(first, 0, 255)
	for i in range(first, last):
		_fade_col[i] = c
	var dur := 0.0 if speed <= 0 else (320.0 / speed) * 0.005
	if dur <= 0.0:
		for i in range(first, last):
			_level[i] = 1.0 if fade_in else 0.0
	else:
		for i in range(first, last):
			if fade_in:
				_level[i] = 0.0
		var start := PackedFloat32Array()
		for i in range(first, last):
			start.append(_level[i])
		_fades.append({"first": first, "last": last, "in": fade_in, "t": 0.0, "dur": dur, "start": start})
	_pal_dirty = true
	return dur


func clear_fades() -> void:
	_fades.clear()
	for i in 256:
		_level[i] = 1.0
	_pal_dirty = true


func _update_fades(delta: float) -> void:
	for f in _fades.duplicate():
		f.t += delta
		var k: float = clampf(f.t / f.dur, 0.0, 1.0)
		var st: PackedFloat32Array = f.start
		for i in range(f.first, f.last):
			_level[i] = k if f.in else minf(st[i - f.first], 1.0 - k)
		_pal_dirty = true
		if k >= 1.0:
			_fades.erase(f)


# ------------------------------------------------------------------ presentation

func _process(delta: float) -> void:
	var area := size if size.x >= 1.0 and size.y >= 1.0 else get_viewport_rect().size
	if area != _laid_out_for:
		_layout()
	if not _fades.is_empty():
		_update_fades(delta)
	if _gamma != DisplaySettings.crt_gamma():
		_gamma = DisplaySettings.crt_gamma()
		_pal_dirty = true
	if _pal_dirty:
		_pal_dirty = false
		for i in 256:
			_pal_img.set_pixel(i, 0, make_shown_color(i))
		_pal_tex.update(_pal_img)
	present()


## Colour of palette index `i` on screen: current fade level, then CRT gamma.
func make_shown_color(i: int) -> Color:
	var c := _fade_col[i].lerp(_target[i], _level[i])
	return DisplaySettings.make_corrected(c, _gamma)


## Copies the frame buffer (+ cursor) to the display texture.
func present() -> void:
	_out.copy_from(image)
	if cursor_visible and _cursor:
		var p := cursor_pos - _cursor_hot
		_out.blit_rect_mask(_cursor, _cursor, Rect2i(Vector2i.ZERO, _cursor.get_size()), p)
	_tex.update(_out)


## Puts `c` under the frame buffer, sized to the virtual screen (null removes the current one).
func set_underlay(c: Control) -> void:
	if underlay == c:
		return
	if underlay and is_instance_valid(underlay):
		underlay.queue_free()
	underlay = c
	if c:
		c.position = Vector2.ZERO
		c.size = Vector2(W, H)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_frame.add_child(c)
		_frame.move_child(c, 0)


func show_overlay(tex: Texture2D) -> void:
	overlay.texture = tex
	overlay.visible = tex != null


## Saves what is on screen (palette applied) — used by automated screenshots.
func snapshot() -> Image:
	var img := Image.create(W, H, false, Image.FORMAT_RGB8)
	var under: Image = null
	if underlay and underlay.visible and underlay.has_method("get_image"):
		under = underlay.call("get_image")
		if under:
			under.convert(Image.FORMAT_RGB8)
			if under.get_size() != Vector2i(W, H):
				under.resize(W, H, Image.INTERPOLATE_NEAREST)
	for y in H:
		for x in W:
			var px := _out.get_pixel(x, y)
			if under and px.a < 0.5:
				img.set_pixel(x, y, under.get_pixel(x, y))
				continue
			img.set_pixel(x, y, make_shown_color(int(round(px.r * 255.0))))
	if overlay.visible and overlay.texture:
		var o := overlay.texture.get_image()
		if o:
			o.convert(Image.FORMAT_RGBA8)
			img.convert(Image.FORMAT_RGBA8)
			img.blend_rect(o, Rect2i(0, 0, W, H), Vector2i.ZERO)
	return img

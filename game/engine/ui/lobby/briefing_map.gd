class_name BriefingMap
extends RefCounted
## The top-down picture of a mission's area for the lobby's briefing pane. A lobby has no battle world to draw it from
## (CommandMapBackground needs one), so it is made from the map file alone: the terrain's colour map lit by the relief of
## its heightfield (the command map's light and shading limits), then the map's objective stations and the player's start
## marked on it. Missions on a flat Earthsiege world have no terrain: they get no picture (the pane shows a note instead).
## Made once per map and cached.

const MAX_SIZE := 384
const NO_TERRAIN_NOTE := "No map preview for this mission."
const NO_ALBEDO_COLOR := Color(0.32, 0.36, 0.3)
const MARK_RADIUS := 8
const MARK_OUTLINE := Color(0.02, 0.05, 0.06)
const OBJECTIVE_COLOR := Color(1.0, 0.87, 0.0)
const START_COLOR := Color(0.3, 0.9, 0.9)
const OBJECTIVE_KINDS := ["flag", "objective", "generator", "sensor"]
const START_KINDS := ["herc", "infantry"]

static var _cache := {}


## The picture of the map `mission` names (its "map" id) or null when it has none or no terrain.
static func make_texture(mission: Dictionary) -> Texture2D:
	var map_id := str(mission.get("map", ""))
	if map_id == "":
		return null
	if not _cache.has(map_id):
		_cache[map_id] = _make_from_map(MapBuilder.load_map(map_id))
	return _cache[map_id]


static func _make_from_map(m: Dictionary) -> Texture2D:
	if not m.get("terrain") is Dictionary:
		return null
	var t: Dictionary = m.terrain
	var dir := str(m.get("_dir", ""))
	var heights := _load_heights(t, dir)
	var grid := Vector2i(int(t.get("size", MapTerrain.DEFAULT_SIZE)[0]), int(t.get("size", MapTerrain.DEFAULT_SIZE)[1]))
	if grid.x < 2 or grid.y < 2 or heights.size() < grid.x * grid.y:
		return null
	var area := _make_area(m, t, grid)
	var img := _make_relief_image(t, dir, heights, grid, area)
	_draw_marks(img, area, m)
	return ImageTexture.create_from_image(img)


## The terrain's metres from its file or memory, scaled by height_scale.
static func _load_heights(t: Dictionary, dir: String) -> PackedFloat32Array:
	var heights := PackedFloat32Array()
	if t.get("heights_data") is PackedFloat32Array:
		heights = PackedFloat32Array(t.heights_data)
	else:
		heights = FileAccess.get_file_as_bytes(dir.path_join(str(t.get("heights", "height.r32")))).to_float32_array()
	var height_scale := float(t.get("height_scale", 1.0))
	if height_scale != 1.0:
		for i in heights.size():
			heights[i] *= height_scale
	return heights


## The world rectangle (x, z) the picture shows: the playable bounds inside the terrain, else the whole terrain.
static func _make_area(m: Dictionary, t: Dictionary, grid: Vector2i) -> Rect2:
	var terrain := Rect2(_make_origin(t), Vector2(grid.x - 1, grid.y - 1) * _make_square(t))
	var b = m.get("bounds")
	if b is Dictionary and b.get("min") is Array and b.get("max") is Array:
		var wanted := Rect2(Vector2(float(b.min[0]), float(b.min[1])), Vector2.ZERO).expand(Vector2(float(b.max[0]), float(b.max[1])))
		if wanted.intersects(terrain) and wanted.intersection(terrain).has_area():
			return wanted.intersection(terrain)
	return terrain


static func _make_origin(t: Dictionary) -> Vector2:
	var origin: Array = t.get("origin", [0.0, 0.0])
	return Vector2(float(origin[0]), float(origin[1]))


static func _make_square(t: Dictionary) -> float:
	return float(t.get("square", MapTerrain.DEFAULT_SQUARE))


static func _make_relief_image(t: Dictionary, dir: String, heights: PackedFloat32Array, grid: Vector2i, area: Rect2) -> Image:
	var square := _make_square(t)
	var longest := maxf(area.size.x, area.size.y)
	var side := MAX_SIZE
	var size := Vector2i(maxi(1, int(side * area.size.x / longest)), maxi(1, int(side * area.size.y / longest)))
	var colours := _load_albedo(t, dir)
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
	var flat := CommandMapBackground.LIGHT_DIR.normalized().y
	var span := _make_span(heights)
	for j in size.y:
		for i in size.x:
			var world := area.position + area.size * Vector2((i + 0.5) / size.x, (j + 0.5) / size.y)
			var g := (world - _make_origin(t)) / square
			var factor := clampf(_make_light(heights, grid, g, square) / flat, CommandMapBackground.RELIEF_DARK, CommandMapBackground.RELIEF_LIGHT)
			img.set_pixel(i, j, (_make_base_colour(colours, g, grid, heights, span) * factor).clamp())
	return img


static func _load_albedo(t: Dictionary, dir: String) -> Image:
	var img: Image = (t.albedo_data as Image).duplicate() if t.get("albedo_data") is Image else null
	var path := dir.path_join(str(t.get("albedo", "albedo.png")))
	if img == null and FileAccess.file_exists(path):
		img = Image.load_from_file(path)
	if img != null:
		img.convert(Image.FORMAT_RGB8)
	return img


## The ground colour at grid position `g`: the colour map's pixel, else a tint by height.
static func _make_base_colour(colours: Image, g: Vector2, grid: Vector2i, heights: PackedFloat32Array, span: Vector2) -> Color:
	if colours != null:
		var u := clampf(g.x / (grid.x - 1), 0.0, 1.0)
		var v := clampf(g.y / (grid.y - 1), 0.0, 1.0)
		return colours.get_pixel(mini(int(u * colours.get_width()), colours.get_width() - 1), mini(int(v * colours.get_height()), colours.get_height() - 1))
	var k := inverse_lerp(span.x, span.y, _height_at(heights, grid, g)) if span.y > span.x else 0.5
	return NO_ALBEDO_COLOR.lerp(CommandMapBackground.HIGH_COLOR, k)


static func _make_span(heights: PackedFloat32Array) -> Vector2:
	var span := Vector2(INF, -INF)
	for h in heights:
		span = Vector2(minf(span.x, h), maxf(span.y, h))
	return span


static func _height_at(heights: PackedFloat32Array, grid: Vector2i, g: Vector2) -> float:
	return heights[clampi(int(g.y), 0, grid.y - 1) * grid.x + clampi(int(g.x), 0, grid.x - 1)]


## How much light the ground at grid position `g` gets: the surface normal (slopes steepened for the relief) against the light.
static func _make_light(heights: PackedFloat32Array, grid: Vector2i, g: Vector2, square: float) -> float:
	var dx := _height_at(heights, grid, g + Vector2(1, 0)) - _height_at(heights, grid, g - Vector2(1, 0))
	var dz := _height_at(heights, grid, g + Vector2(0, 1)) - _height_at(heights, grid, g - Vector2(0, 1))
	var normal := Vector3(-dx, 2.0 * square / CommandMapBackground.RELIEF_EXAGGERATION, -dz).normalized()
	return maxf(normal.dot(CommandMapBackground.LIGHT_DIR.normalized()), 0.0)


# ------------------------------------------------------------------ markers

static func _draw_marks(img: Image, area: Rect2, m: Dictionary) -> void:
	for s in m.get("spawns", []):
		if str(s.get("kind", "")) in START_KINDS and int(s.get("team", 0)) == 0:
			_draw_diamond(img, _to_pixel(img, area, s.get("pos", [])), START_COLOR)
			break   # the first start is enough
	for st in m.get("stations", []):
		if str(st.get("kind", "")) in OBJECTIVE_KINDS:
			_draw_diamond(img, _to_pixel(img, area, st.get("pos", [])), OBJECTIVE_COLOR)


## The picture pixel of engine position `pos` ([x, y, z]); (-1, -1) when it lies outside `area`.
static func _to_pixel(img: Image, area: Rect2, pos: Array) -> Vector2i:
	if pos.size() < 3:
		return Vector2i(-1, -1)
	var p := Vector2(float(pos[0]), float(pos[2]))
	if not area.has_point(p):
		return Vector2i(-1, -1)
	var f := (p - area.position) / area.size
	return Vector2i(int(f.x * img.get_width()), int(f.y * img.get_height()))


static func _draw_diamond(img: Image, centre: Vector2i, colour: Color) -> void:
	if centre.x < 0:
		return
	for dy in range(-MARK_RADIUS, MARK_RADIUS + 1):
		for dx in range(-MARK_RADIUS, MARK_RADIUS + 1):
			var d := absi(dx) + absi(dy)
			var p := centre + Vector2i(dx, dy)
			if d <= MARK_RADIUS and p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height():
				img.set_pixelv(p, colour if d < MARK_RADIUS else MARK_OUTLINE)

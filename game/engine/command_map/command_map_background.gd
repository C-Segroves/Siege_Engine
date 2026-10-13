class_name CommandMapBackground
extends RefCounted
## The picture under the command map (docs/COMMAND_MAP.md section 4): the battlefield seen from straight above,
## drawn by the game's own world - its terrain with that game's textures and palette, its buildings - through an
## orthographic camera over the playable area (fog, distance haze and the sky left out), shaded with the relief of
## the ground (read with rays, lit from the north-west) so hills and buildings stand out even where the game's own
## lighting is flat seen from above (Earthsiege worlds). Without a renderer (headless runs) it is the hillshade
## alone, in the map theme's teal.

const RENDER_SIZE := 1024
const SHADE_SIZE := 160
## Camera height above the highest ground and how far it sees (metres).
const CAMERA_LIFT := 1500.0
const CAMERA_FAR := 6000.0
const RAY_TOP := 3000.0
const RAY_BOTTOM := -3000.0
## Hillshade: light from the north-west, the theme's teal from dark (low, shaded) to light (high, lit).
const LIGHT_DIR := Vector3(-0.6, 0.7, -0.4)
const LOW_COLOR := Color(0.04, 0.14, 0.14)
const HIGH_COLOR := Color(0.45, 0.72, 0.68)
const EMPTY_COLOR := Color(0.02, 0.05, 0.06)
## The render's size when shaded, and the relief's brightness range (shaded slope .. lit slope; flat ground ~1).
const SHADED_SIZE := 512
const RELIEF_DARK := 0.45
const RELIEF_LIGHT := 1.25
## Slopes are steepened this much for the relief (a map's gentle hills seen from kilometres up read flat).
const RELIEF_EXAGGERATION := 3.0


## The background of `area` (world x, z) of `battle`: a top-down render when the display renders, else a hillshade.
static func make(battle: Node3D, area: Rect2) -> Texture2D:
	if DisplayServer.get_name() == "headless":
		return make_hillshade(battle, area)
	var tex := await make_render(battle, area)
	if tex == null:
		return make_hillshade(battle, area)
	return ImageTexture.create_from_image(apply_relief(tex.get_image(), make_heights(battle, area), area))


## An orthographic render of `area` from above, in the battle's own world.
static func make_render(battle: Node3D, area: Rect2) -> Texture2D:
	var view := SubViewport.new()
	var aspect := area.size.x / maxf(area.size.y, 1.0)
	view.size = Vector2i(RENDER_SIZE, maxi(1, int(RENDER_SIZE / aspect))) if aspect >= 1.0 else Vector2i(maxi(1, int(RENDER_SIZE * aspect)), RENDER_SIZE)
	view.world_3d = battle.get_viewport().world_3d
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = area.size.y
	cam.far = CAMERA_FAR
	cam.environment = _make_clear_environment(battle)
	view.add_child(cam)
	battle.add_child(view)
	var centre := area.get_center()
	cam.global_position = Vector3(centre.x, _make_top(battle, area) + CAMERA_LIFT, centre.y)
	cam.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	cam.current = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := view.get_texture().get_image()
	view.queue_free()
	return ImageTexture.create_from_image(img) if img and not img.is_empty() else null


## The battle's environment without fog (the camera is far above the ground).
static func _make_clear_environment(battle: Node) -> Environment:
	var env := Environment.new()
	for we in battle.find_children("*", "WorldEnvironment", true, false):
		if (we as WorldEnvironment).environment:
			env = (we as WorldEnvironment).environment.duplicate()
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	env.background_mode = Environment.BG_COLOR
	env.background_color = EMPTY_COLOR
	return env


static func _make_top(battle: Node3D, area: Rect2) -> float:
	var top := 0.0
	for k in 9:
		var p := area.position + area.size * Vector2((k % 3) / 2.0, (k / 3) / 2.0)
		top = maxf(top, _ground_at(battle, p, 0.0))
	return top


## A hillshade of `area`: ray-cast ground heights, lit from LIGHT_DIR, tinted by height.
static func make_hillshade(battle: Node3D, area: Rect2) -> Texture2D:
	var heights := make_heights(battle, area)
	var img := Image.create(SHADE_SIZE, SHADE_SIZE, false, Image.FORMAT_RGB8)
	var cell := area.size / SHADE_SIZE
	var span := _make_span(heights)
	for j in SHADE_SIZE:
		for i in SHADE_SIZE:
			img.set_pixel(i, j, _shade(heights, i, j, cell, span))
	return ImageTexture.create_from_image(img)


## The ground height (any solid) over `area` on a SHADE_SIZE grid, row by row (NAN where nothing is).
static func make_heights(battle: Node3D, area: Rect2) -> PackedFloat32Array:
	var heights := PackedFloat32Array()
	heights.resize(SHADE_SIZE * SHADE_SIZE)
	for j in SHADE_SIZE:
		for i in SHADE_SIZE:
			heights[j * SHADE_SIZE + i] = _ground_at(battle, area.position + area.size * Vector2((i + 0.5) / SHADE_SIZE, (j + 0.5) / SHADE_SIZE), NAN)
	return heights


static func _make_span(heights: PackedFloat32Array) -> Vector2:
	var span := Vector2(INF, -INF)
	for h in heights:
		if not is_nan(h):
			span = Vector2(minf(span.x, h), maxf(span.y, h))
	return span


## `img` (the render) darkened on slopes facing away from the light and brightened on lit ones.
static func apply_relief(img: Image, heights: PackedFloat32Array, area: Rect2) -> Image:
	img.convert(Image.FORMAT_RGB8)
	img.resize(SHADED_SIZE, SHADED_SIZE, Image.INTERPOLATE_BILINEAR)
	var light := Image.create(SHADE_SIZE, SHADE_SIZE, false, Image.FORMAT_L8)
	var cell := area.size / SHADE_SIZE
	var flat := LIGHT_DIR.normalized().y
	for j in SHADE_SIZE:
		for i in SHADE_SIZE:
			var factor := _light(heights, i, j, cell, RELIEF_EXAGGERATION) / flat if not is_nan(heights[j * SHADE_SIZE + i]) else 1.0
			light.set_pixel(i, j, Color.from_hsv(0.0, 0.0, inverse_lerp(RELIEF_DARK, RELIEF_LIGHT, clampf(factor, RELIEF_DARK, RELIEF_LIGHT))))
	light.resize(SHADED_SIZE, SHADED_SIZE, Image.INTERPOLATE_BILINEAR)
	var data := img.get_data()
	var shade := light.get_data()
	for k in shade.size():
		var f := lerpf(RELIEF_DARK, RELIEF_LIGHT, shade[k] / 255.0)
		for c in 3:
			data[k * 3 + c] = mini(int(data[k * 3 + c] * f), 255)
	return Image.create_from_data(SHADED_SIZE, SHADED_SIZE, false, Image.FORMAT_RGB8, data)


## How much light the ground at cell i, j gets (0..1).
static func _light(heights: PackedFloat32Array, i: int, j: int, cell: Vector2, exaggeration := 1.0) -> float:
	var h := heights[j * SHADE_SIZE + i]
	var hx := _height_or(heights, mini(i + 1, SHADE_SIZE - 1), j, h) - _height_or(heights, maxi(i - 1, 0), j, h)
	var hz := _height_or(heights, i, mini(j + 1, SHADE_SIZE - 1), h) - _height_or(heights, i, maxi(j - 1, 0), h)
	var normal := Vector3(-hx * exaggeration / (2.0 * cell.x), 1.0, -hz * exaggeration / (2.0 * cell.y)).normalized()
	return clampf(normal.dot(LIGHT_DIR.normalized()), 0.0, 1.0)


static func _shade(heights: PackedFloat32Array, i: int, j: int, cell: Vector2, span: Vector2) -> Color:
	var h := heights[j * SHADE_SIZE + i]
	if is_nan(h):
		return EMPTY_COLOR
	var light := _light(heights, i, j, cell)
	var height := (h - span.x) / maxf(span.y - span.x, 1.0)
	return LOW_COLOR.lerp(HIGH_COLOR, clampf(0.25 + 0.45 * height + 0.5 * (light - 0.5), 0.0, 1.0))


static func _height_or(heights: PackedFloat32Array, i: int, j: int, fallback: float) -> float:
	var h := heights[j * SHADE_SIZE + i]
	return fallback if is_nan(h) else h


## The ground (any solid) height at world x, z (`fallback` where a ray finds nothing).
static func _ground_at(battle: Node3D, xz: Vector2, fallback: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(xz.x, RAY_TOP, xz.y), Vector3(xz.x, RAY_BOTTOM, xz.y))
	q.collide_with_areas = false
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else fallback

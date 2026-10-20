class_name TribesBaseLights
extends RefCounted
## The lit parts of a base object (TribesBaseObject; docs/TRIBES_BASE_EQUIPMENT.md section 2, "Lights"). The
## games light their stations, generators and turrets with the shapes' self-illuminating materials (Tribes 2 DTS
## material flag SelfIlluminating, the blinking IFL panels; Tribes 1 palette materials drawn unshaded), which the
## remake draws unshaded (ShapeInstance). They glow only while the object works: unpowered, disabled or destroyed
## they go dark (drawn shaded and dimmed), and the light they cast on their surroundings goes out with them.
## The cast light is the remake's: one OmniLight3D at the lit parts' centre, in their average texture colour,
## reaching as far as the shape is large (the originals bake this into the interiors' lightmaps).

## How bright the cast light is, and how much darker an unlit glow panel is drawn.
const LIGHT_ENERGY := 0.8
const DARK_SHADE := 0.3
## Reach of the cast light per metre of the shape's size.
const RANGE_PER_SIZE := 1.5
const MIN_RANGE := 3.0

var light: OmniLight3D
var lit := true
var _surfaces: Array = []        # [MeshInstance3D, surface index, dark material]


## The lights of `shape` (null when it has no self-illuminated parts).
static func make(owner: Node3D, shape: ShapeInstance) -> TribesBaseLights:
	var lights := TribesBaseLights.new()
	var colour_sum := Color(0, 0, 0)
	var centre_sum := Vector3.ZERO
	for mi in shape.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for i in m.mesh.get_surface_count():
			var mat := m.get_active_material(i)
			if _is_glowing(mat):
				lights._surfaces.append([m, i, _make_dark(mat)])
				colour_sum += _make_average_colour(mat)
				centre_sum += owner.global_transform.affine_inverse() * m.global_transform * m.mesh.get_aabb().get_center()
	if lights._surfaces.is_empty():
		return null
	var n := float(lights._surfaces.size())
	lights._build_light(owner, centre_sum / n, colour_sum / n, TribesBaseObject.make_shape_bounds(owner, shape))
	return lights


## Glowing = drawn unshaded: a StandardMaterial3D, or the unified render path's ShaderMaterial with self_lit set.
static func _is_glowing(mat: Material) -> bool:
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("self_lit") == true   # null when never set (shader default false)
	return false


static func _make_dark(mat: Material) -> Material:
	if mat is ShaderMaterial:
		var dark_shader := mat.duplicate() as ShaderMaterial
		dark_shader.set_shader_parameter("self_lit", false)
		return dark_shader
	var dark := mat.duplicate() as StandardMaterial3D
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	dark.albedo_color = mat.albedo_color * Color(DARK_SHADE, DARK_SHADE, DARK_SHADE, 1.0)
	return dark


static func _make_average_colour(mat: Material) -> Color:
	if mat is ShaderMaterial:
		return _make_array_colour((mat as ShaderMaterial).get_shader_parameter("albedo_array"))
	return _make_standard_colour(mat as StandardMaterial3D)


## Average colour of the first layer of a unified material's texture array (white when it has none).
static func _make_array_colour(arr: Variant) -> Color:
	if not (arr is Texture2DArray) or (arr as Texture2DArray).get_layers() == 0:
		return Color.WHITE
	var img := (arr as Texture2DArray).get_layer_data(0)
	if img == null or img.is_empty():
		return Color.WHITE
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var c := img.get_pixel(0, 0)
	return Color(c.r, c.g, c.b)


static func _make_standard_colour(mat: StandardMaterial3D) -> Color:
	var tex := mat.albedo_texture
	if tex == null:
		return mat.albedo_color
	var img := tex.get_image()
	if img == null or img.is_empty():
		return mat.albedo_color
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var c := img.get_pixel(0, 0)
	return Color(c.r, c.g, c.b) * mat.albedo_color


func _build_light(owner: Node3D, at: Vector3, colour: Color, bounds: AABB) -> void:
	light = DynamicLights.make_light({"color": colour.lightened(0.2), "energy": LIGHT_ENERGY,
		"range": maxf(MIN_RANGE, bounds.size.length() * RANGE_PER_SIZE)})
	light.name = "BaseLight"
	light.position = at
	owner.add_child(light)


## On (glowing, casting light) or off (dark).
func apply_lit(on: bool) -> void:
	if on == lit:
		return
	lit = on
	light.visible = on
	for s in _surfaces:
		(s[0] as MeshInstance3D).set_surface_override_material(int(s[1]), null if on else s[2])

class_name PaletteLights
extends Node
## Earthsiege 1 / 2 point lights in the palette shaders (3Space light type 2, docs/formats/weapon_fx.md 2.1,
## world.md section 4): an explosion's light raises the light level I of every polygon it reaches - no colour, no
## normal - by I_light x min(1, full / d) within its cutoff radius (light manager 0x55b8 / 0x5015: full brightness
## within `full_range`, then 1/d; the radius and I follow the explosion's per-frame curve). The shaders read the
## live lights from the global "palette_lights" texture (MAX_LIGHTS x 2: position + cutoff, then I + full range)
## and "palette_light_count".
## Lights join through DynamicLights (an fx light block with "full_range": the 3Space exports); this node, created
## once under the scene tree's root, writes the nearest MAX_LIGHTS to the camera every frame.

const GROUP := "palette_lights"
const MAX_LIGHTS := 8
## OmniLight3D metas: the light's 3Space full-brightness radius and its cutoff at peak I (metres).
const FULL_META := "palette_full_m"
const CUTOFF_META := "palette_cutoff_m"
## light_energy of a light at I = 255 (FxPlayer.LIGHT_ENERGY): the energy curve is I / 255.
const ENERGY_AT_PEAK := 2.0
const NODE_NAME := "PaletteLights"

var _img := Image.create(MAX_LIGHTS, 2, false, Image.FORMAT_RGBAF)
var _tex := ImageTexture.create_from_image(_img)


## Marks `l` as a 3Space light (light block with "full_range") and makes sure the writer runs.
static func adopt(l: OmniLight3D, block: Dictionary) -> void:
	if not block.has("full_range"):
		return
	l.set_meta(FULL_META, float(block.full_range))
	l.set_meta(CUTOFF_META, float(block.get("cutoff", l.omni_range)))
	l.add_to_group(GROUP)
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root.get_node_or_null(NODE_NAME) == null:
		var n := PaletteLights.new()
		n.name = NODE_NAME
		tree.root.add_child.call_deferred(n)


## [position, cutoff m, I (0..1), full m] of light `l` this frame.
static func make_light_row(l: OmniLight3D) -> Array:
	var share := clampf(l.light_energy / ENERGY_AT_PEAK, 0.0, 1.0)
	return [l.global_position, float(l.get_meta(CUTOFF_META)) * share, share, float(l.get_meta(FULL_META))]


func _ready() -> void:
	RenderingServer.global_shader_parameter_set("palette_lights", _tex)


func _process(_delta: float) -> void:
	var lights := get_tree().get_nodes_in_group(GROUP).filter(func(l): return l is OmniLight3D and l.is_inside_tree())
	var cam := get_viewport().get_camera_3d()
	if cam != null and lights.size() > MAX_LIGHTS:
		var eye := cam.global_position
		lights.sort_custom(func(a, b): return eye.distance_squared_to(a.global_position) < eye.distance_squared_to(b.global_position))
	var n := mini(lights.size(), MAX_LIGHTS)
	for i in n:
		var row := make_light_row(lights[i])
		var p: Vector3 = row[0]
		_img.set_pixel(i, 0, Color(p.x, p.y, p.z, row[1]))
		_img.set_pixel(i, 1, Color(row[2], row[3], 0.0, 0.0))
	_tex.update(_img)
	RenderingServer.global_shader_parameter_set("palette_light_count", n)

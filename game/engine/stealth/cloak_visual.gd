class_name CloakVisual
extends RefCounted
## Draws one unit through the shared cloak shader (engine/shaders/cloak.gdshader) while its CloakState fades in and out:
## every mesh of its body (and the weapon in a soldier's hand) takes one per-unit material override, restored when the
## cloak is fully off. render_unified only changes how the shapes' own materials are made, so the override works the
## same for every game's shapes.

const SHADER := preload("res://engine/shaders/cloak.gdshader")
const PARAM_AMOUNT := "amount"
const PARAM_REVEAL := "reveal_range"
const PARAM_TILE := "tile_per_m"
## The pattern repeats this many times over the unit's height, so a soldier and a Herc show the same detail.
const TILE_REPEATS_PER_UNIT_HEIGHT := 1.6
const MIN_HEIGHT_M := 0.5

static var _textures := {}
## Below this fade the unit is drawn plainly again.
const PLAIN_BELOW := 0.001

var _material: ShaderMaterial
var _meshes: Array[MeshInstance3D] = []
var _shown := -1.0
var _held_model: Node = null
var _body_model: Node = null


## Sets how far `unit` is hidden (0 plain .. 1 fully cloaked); `profile` gives the metres within which the camera sees it
## plainly and the cloak bitmap.
func apply_amount(unit: Node, amount: float, profile: CloakProfile) -> void:
	if amount < PLAIN_BELOW:
		if not _meshes.is_empty():
			_restore()
		_shown = 0.0
		return
	var stale: bool = _meshes.is_empty() or _held_model != _make_held_model(unit) or _body_model != unit.get("shape")
	if stale:
		_apply_override(unit, profile)
	elif is_equal_approx(amount, _shown):
		return
	_material.set_shader_parameter(PARAM_AMOUNT, amount)
	_shown = amount


func is_shown() -> bool:
	return not _meshes.is_empty()


## The meshes the cloak covers: the body shape and a soldier's held weapon.
static func make_meshes(unit: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var roots := []
	if unit.get("shape") is Node:
		roots.append(unit.get("shape"))
	if _make_held_model(unit) != null:
		roots.append(_make_held_model(unit))
	for root in roots:
		if is_instance_valid(root):
			_collect(root, out)
	return out


## The weapon model in a soldier's hand (null for vehicles).
static func _make_held_model(unit: Node) -> Node:
	var held = unit.get("held")
	return held.get("world_model") if held != null and held.get("world_model") is Node else null


static func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		_collect(c, out)


func _apply_override(unit: Node, profile: CloakProfile) -> void:
	_restore()
	_meshes = make_meshes(unit)
	_held_model = _make_held_model(unit)
	_body_model = unit.get("shape") if unit.get("shape") is Node else null
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
	_material.set_shader_parameter(PARAM_REVEAL, profile.reveal_range_m)
	_apply_texture(profile)
	_material.set_shader_parameter(PARAM_TILE, TILE_REPEATS_PER_UNIT_HEIGHT / maxf(_make_height(_meshes), MIN_HEIGHT_M))
	for m in _meshes:
		m.material_override = _material


func _restore() -> void:
	for m in _meshes:
		if is_instance_valid(m):
			m.material_override = null
	_meshes.clear()


func _apply_texture(profile: CloakProfile) -> void:
	var tex := _make_texture(profile)
	_material.set_shader_parameter("use_texture", tex != null)
	_material.set_shader_parameter("cloak_tex", tex)


## The pack's cloak bitmap (cached; null when the profile names none or it is not installed: the shader's own pattern).
static func _make_texture(profile: CloakProfile) -> Texture2D:
	if profile.texture == "":
		return null
	var pack := profile.id.get_slice(":", 0)
	var key := "%s:%s" % [pack, profile.texture]
	if not _textures.has(key):
		var img := Assets.load_image(profile.texture, pack)
		if img != null:
			img.generate_mipmaps()
		_textures[key] = ImageTexture.create_from_image(img) if img != null else null
	return _textures[key]


## The height in metres of the world box around `meshes`.
static func _make_height(meshes: Array[MeshInstance3D]) -> float:
	var top := -INF
	var bottom := INF
	for m in meshes:
		var box := m.global_transform * m.get_aabb()
		top = maxf(top, box.end.y)
		bottom = minf(bottom, box.position.y)
	return top - bottom if top > bottom else MIN_HEIGHT_M

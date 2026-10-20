class_name CloakVisual
extends RefCounted
## Draws one unit through the shared cloak shader (engine/shaders/cloak.gdshader) while its CloakState fades in and out:
## every mesh of its body (and the weapon in a soldier's hand) takes one per-unit material override, restored when the
## cloak is fully off. render_unified only changes how the shapes' own materials are made, so the override works the
## same for every game's shapes.

const SHADER := preload("res://engine/shaders/cloak.gdshader")
const PARAM_AMOUNT := "amount"
const PARAM_REVEAL := "reveal_range"
## Below this fade the unit is drawn plainly again.
const PLAIN_BELOW := 0.001

var _material: ShaderMaterial
var _meshes: Array[MeshInstance3D] = []
var _shown := -1.0
var _held_model: Node = null


## Sets how far `unit` is hidden (0 plain .. 1 fully cloaked); `reveal_range` is the metres within which the camera sees it plainly.
func apply_amount(unit: Node, amount: float, reveal_range: float) -> void:
	if amount < PLAIN_BELOW:
		if not _meshes.is_empty():
			_restore()
		_shown = 0.0
		return
	if is_equal_approx(amount, _shown):
		return
	if _meshes.is_empty() or _held_model != _make_held_model(unit):
		_apply_override(unit, reveal_range)
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


func _apply_override(unit: Node, reveal_range: float) -> void:
	_restore()
	_meshes = make_meshes(unit)
	_held_model = _make_held_model(unit)
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
	_material.set_shader_parameter(PARAM_REVEAL, reveal_range)
	for m in _meshes:
		m.material_override = _material


func _restore() -> void:
	for m in _meshes:
		if is_instance_valid(m):
			m.material_override = null
	_meshes.clear()

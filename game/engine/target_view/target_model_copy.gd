class_name TargetModelCopy
extends Node3D
## A live visual copy of a vehicle's model (its ShapeInstance with cells, fixtures and weapon pods) for
## a separate 3D world: built once by duplicating the model's node tree (scripts, sounds and effects
## left out), then kept in the source's pose and cell states by apply_source_pose().

## Node classes the copy keeps (geometry and its frames); everything else is left out.
const KEPT_CLASSES := ["Node3D", "MeshInstance3D", "Marker3D"]

var source: ShapeInstance
## [source Node3D, copy Node3D] pairs in tree order.
var _pairs: Array = []
## copy MeshInstance3D -> source MeshInstance3D
var copy_to_source := {}


## Copies `model` (its local transform included) under this node.
func build_from(model: ShapeInstance) -> void:
	source = model
	var dup := model.duplicate(0) as Node3D
	add_child(dup)
	_pairs.clear()
	copy_to_source.clear()
	_pair_tree(model, dup)
	apply_source_pose()


func _pair_tree(src: Node, dst: Node) -> void:
	_pairs.append([src, dst])
	if dst is MeshInstance3D:
		copy_to_source[dst] = src
	var src_children := src.get_children()
	var dst_children := dst.get_children()
	for i in mini(src_children.size(), dst_children.size()):
		if is_kept(dst_children[i]):
			_pair_tree(src_children[i], dst_children[i])
		else:
			dst_children[i].free()


static func is_kept(n: Node) -> bool:
	return n.get_class() in KEPT_CLASSES


## True while every copied source node still exists (a rebuilt or freed model needs a new copy).
func is_source_valid() -> bool:
	if source == null or not is_instance_valid(source):
		return false
	for p in _pairs:
		if not is_instance_valid(p[0]):
			return false
	return true


## Copies every node's transform and visibility from the source (animation pose, torso twist, cell
## states, hidden pods).
func apply_source_pose() -> void:
	for p in _pairs:
		var dst: Node3D = p[1]
		dst.transform = (p[0] as Node3D).transform
		dst.visible = (p[0] as Node3D).visible


## Copy meshes currently shown (works outside the scene tree too).
func visible_meshes() -> Array:
	return copy_to_source.keys().filter(_is_shown)


func _is_shown(n: Node3D) -> bool:
	while n != null and n != self:
		if not n.visible:
			return false
		n = n.get_parent() as Node3D
	return true


## Transform of copy node `n` in this copy's parent space.
func make_transform_of(n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	while n != null and n != self:
		xf = n.transform * xf
		n = n.get_parent() as Node3D
	return transform * xf

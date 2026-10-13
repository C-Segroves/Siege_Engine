extends RefCounted
## Node poses of a ShapeInstance as values, so two sequence poses can be cross-faded (remake addition:
## the original games snap between sequences). A pose is a Dictionary node index -> Transform3D (the
## node's local transform); a node a pose does not list is at its default transform.


## The pose sequence `index` gives at cycle `phase` (empty for -1: every node at its default).
## Poses the instance on the way; the caller applies the pose it wants afterwards.
static func make_sample(inst: ShapeInstance, index: int, phase: float, wrap := true) -> Dictionary:
	if index < 0:
		return {}
	ShapeCycles.pose(inst, index, phase, wrap)
	return make_capture(inst, ShapeCycles.animated_nodes(inst, index))


## Current local transforms of the nodes in `node_ids` (keys of a Dictionary or an Array).
static func make_capture(inst: ShapeInstance, node_ids: Variant) -> Dictionary:
	var out := {}
	for i in node_ids:
		var ni := int(i)
		if ni >= 0 and ni < inst.nodes.size():
			out[ni] = inst.nodes[ni].transform
	return out


## `from` cross-faded to `to` by `weight` (0 = from, 1 = to): rotations slerp, offsets lerp.
static func make_mix(inst: ShapeInstance, from: Dictionary, to: Dictionary, weight: float) -> Dictionary:
	var out := {}
	for i in make_union(from, to):
		var a: Transform3D = from.get(i, default_transform(inst, i))
		var b: Transform3D = to.get(i, default_transform(inst, i))
		out[i] = a.interpolate_with(b, weight)
	return out


static func make_union(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for i in a:
		out[i] = true
	for i in b:
		out[i] = true
	return out


static func default_transform(inst: ShapeInstance, i: int) -> Transform3D:
	return ShapeInstance.tf_to_transform(inst.shape.transforms[int(inst.shape.nodes[i].default)])


## Writes `pose` to the instance's nodes.
static func apply(inst: ShapeInstance, pose: Dictionary) -> void:
	for i in pose:
		inst.nodes[i].transform = pose[i]


## Ease in and out over 0..1 (no velocity jump at either end of a cross-fade).
static func make_weight(progress: float) -> float:
	return smoothstep(0.0, 1.0, progress)

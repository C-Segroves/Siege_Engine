class_name ShapeCycles
extends RefCounted
## One way to pose and measure the animation sequences of a ShapeInstance, whatever the shape format:
##   * 3Space (Earthsiege 1/2, Battledrome): shape.sequences, frames in original ticks, node 0 = ground
##     tracker whose per-frame transform is that frame's ground step (docs/RE_NOTES.md).
##   * Darkstar (Starsiege, Tribes): shape.ds_sequences, keyframe tracks over a 0..1 cycle; the root node
##     "bounds" carries the cumulative ground motion of the cycle (docs/formats/animation.md).
## A sequence is addressed by index (3Space) or by its name suffix ("walk" finds Darkstar "Seq00_walk").
## Positions are given as a cycle phase: 0..1 = one full cycle.

## Darkstar root node that carries the ground motion; never posed (it is every detail level's parent).
const DARKSTAR_GROUND_NODE := "bounds"
## 3Space ground tracker node.
const ES_GROUND_NODE := 0
const ES_TF_Z_ROT := 2
const ES_TF_X := 3
## An object's animated visibility above this draws it (Torque fades between; the remake shows or hides).
const VISIBLE_THRESHOLD := 0.5
const ES_TF_Y := 4


static func is_darkstar(inst: ShapeInstance) -> bool:
	return inst.shape.get("sequences", []).is_empty() and not inst.shape.get("ds_sequences", []).is_empty()


static func count(inst: ShapeInstance) -> int:
	return inst.shape.get("ds_sequences", []).size() if is_darkstar(inst) else inst.sequence_count()


## Sequence index from a catalog reference: an int index, or a Darkstar name suffix; -1 when missing.
static func find(inst: ShapeInstance, ref: Variant) -> int:
	if ref is int or ref is float:
		var i := int(ref)
		return i if i >= 0 and i < count(inst) else -1
	if not (ref is String) or String(ref) == "" or not is_darkstar(inst):
		return -1
	var suffix := "_" + String(ref).to_lower()
	var seqs: Array = inst.shape.ds_sequences
	for i in seqs.size():
		if String(seqs[i].get("name", "")).to_lower().ends_with(suffix):
			return i
	return -1


## Index of the first Darkstar sequence whose whole name (case-insensitive) is one of `names`, tried in their order
## (a role's preferred name first); -1 when the shape has none of them.
static func find_named(inst: ShapeInstance, names: Array) -> int:
	var seqs: Array = inst.shape.get("ds_sequences", [])
	for want in names:
		var w := str(want).to_lower()
		for i in seqs.size():
			if str(seqs[i].get("name", "")).to_lower() == w:
				return i
	return -1


## Applies sequence `index` at cycle `phase` (wrapped into one cycle, or clamped to 0..1 when not `wrap`).
static func pose(inst: ShapeInstance, index: int, phase: float, wrap := true) -> void:
	if index < 0 or index >= count(inst):
		return
	if is_darkstar(inst):
		_pose_darkstar(inst, inst.shape.ds_sequences[index], fposmod(phase, 1.0) if wrap else clampf(phase, 0.0, 1.0))
	else:
		inst.pose(index, phase * inst.sequence_ticks(index), wrap)


## Authored length of one cycle in seconds; `tick_seconds` converts 3Space ticks (pack-specific).
static func cycle_seconds(inst: ShapeInstance, index: int, tick_seconds: float) -> float:
	if index < 0 or index >= count(inst):
		return 0.0
	if is_darkstar(inst):
		return float(inst.shape.ds_sequences[index].get("duration", 0.0))
	return inst.sequence_ticks(index) * tick_seconds


## Ground motion of one cycle in the instance's parent space: x = forward metres, y = left turn (rad).
static func ground_motion(inst: ShapeInstance, index: int) -> Vector2:
	if index < 0 or index >= count(inst):
		return Vector2.ZERO
	var raw := _darkstar_ground(inst, index) if is_darkstar(inst) else _es_ground(inst, index)
	return Vector2(raw.x * Assets.UNIT * inst.scale.x, raw.y * ShapeInstance.ANGLE)


## Horizontal ground travel of one cycle in metres (forward and sideways alike): a Torque sequence's ground
## transform (`ground`, Tribes 2 .dsq ground frames), else the Darkstar root node's motion, else 3Space's.
static func ground_travel(inst: ShapeInstance, index: int) -> float:
	if index < 0 or index >= count(inst):
		return 0.0
	if is_darkstar(inst):
		var seq: Dictionary = inst.shape.ds_sequences[index]
		var raw := Vector2.ZERO
		if seq.has("ground"):
			raw = Vector2(float(seq.ground[0]), float(seq.ground[1]))
		else:
			raw = _darkstar_ground_shift(inst, index)
		return raw.length() * Assets.UNIT * inst.scale.x
	return absf(_es_ground(inst, index).x) * Assets.UNIT * inst.scale.x


## Node indices that sequence `index` writes when posed.
static func animated_nodes(inst: ShapeInstance, index: int) -> Dictionary:
	var out := {}
	if index < 0 or index >= count(inst):
		return out
	if is_darkstar(inst):
		var ground := _darkstar_ground_index(inst)
		for track in inst.shape.ds_sequences[index].tracks:
			if int(track.node) != ground:
				out[int(track.node)] = true
	else:
		for p in inst.shape.sequences[index].parts:
			out[int(p)] = true
	return out


# ------------------------------------------------------------------ 3Space

static func _es_ground_part(parts: Array) -> int:
	for i in parts.size():
		if int(parts[i]) == ES_GROUND_NODE:   # JSON numbers load as floats
			return i
	return -1


## Sum of the ground tracker's per-frame steps: (forward units, z rotation angle units).
static func _es_ground(inst: ShapeInstance, index: int) -> Vector2:
	var seq: Dictionary = inst.shape.sequences[index]
	var parts: Array = seq.parts
	var p := _es_ground_part(parts)
	if p < 0:
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for fi in seq.frames.size():
		var tf: Array = inst.shape.transforms[int(seq.tf[fi * parts.size() + p])]
		sum += Vector2(float(tf[ES_TF_Y]), float(tf[ES_TF_Z_ROT]))
	return sum


# ------------------------------------------------------------------ Darkstar

static func _darkstar_ground_index(inst: ShapeInstance) -> int:
	var nodes: Array = inst.shape.get("nodes", [])
	for i in nodes.size():
		if int(nodes[i].parent) < 0 and String(nodes[i].get("name", "")) == DARKSTAR_GROUND_NODE:
			return i
	return -1


## Ground node at the cycle's end minus its start: (forward units, z rotation angle units).
static func _darkstar_ground(inst: ShapeInstance, index: int) -> Vector2:
	var ground := _darkstar_ground_index(inst)
	for track in inst.shape.ds_sequences[index].tracks:
		if int(track.node) != ground or track.keys.is_empty():
			continue
		var a: Array = inst.shape.transforms[int(track.keys[0][1])]
		var b: Array = inst.shape.transforms[int(track.keys[track.keys.size() - 1][1])]
		return Vector2(float(b[ES_TF_Y]) - float(a[ES_TF_Y]), float(b[ES_TF_Z_ROT]) - float(a[ES_TF_Z_ROT]))
	return Vector2.ZERO


## The Darkstar ground node's translation from the cycle's start to its end: (x, y) shape units.
static func _darkstar_ground_shift(inst: ShapeInstance, index: int) -> Vector2:
	var ground := _darkstar_ground_index(inst)
	for track in inst.shape.ds_sequences[index].tracks:
		if int(track.node) != ground or track.keys.is_empty():
			continue
		var a: Array = inst.shape.transforms[int(track.keys[0][1])]
		var b: Array = inst.shape.transforms[int(track.keys[track.keys.size() - 1][1])]
		return Vector2(float(b[ES_TF_X]) - float(a[ES_TF_X]), float(b[ES_TF_Y]) - float(a[ES_TF_Y]))
	return Vector2.ZERO


static func _pose_darkstar(inst: ShapeInstance, seq: Dictionary, pos: float) -> void:
	for track in seq.get("vis", []):
		var keys: Array = track.keys
		var k := 0
		while k < keys.size() - 1 and float(keys[k + 1][0]) <= pos:
			k += 1
		inst.set_piece_visible(str(track.piece), float(keys[k][1]) > VISIBLE_THRESHOLD)
	var ground := _darkstar_ground_index(inst)
	for track in seq.tracks:
		var ni := int(track.node)
		if ni == ground or ni < 0 or ni >= inst.nodes.size() or track.keys.is_empty():
			continue
		inst.nodes[ni].transform = _track_transform(inst, track.keys, pos)


## Track keys [[pos 0..1, transform index], ...] sampled at `pos` (linear between the bracketing keys).
static func _track_transform(inst: ShapeInstance, keys: Array, pos: float) -> Transform3D:
	var k := 0
	while k < keys.size() - 1 and float(keys[k + 1][0]) <= pos:
		k += 1
	var a := ShapeInstance.tf_to_transform(inst.shape.transforms[int(keys[k][1])])
	if k >= keys.size() - 1 or not inst.interpolate:
		return a
	var span := float(keys[k + 1][0]) - float(keys[k][0])
	if span <= 0.0:
		return a
	var b := ShapeInstance.tf_to_transform(inst.shape.transforms[int(keys[k + 1][1])])
	return a.interpolate_with(b, clampf((pos - float(keys[k][0])) / span, 0.0, 1.0))

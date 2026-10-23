class_name InfantryAnimationLayers
extends RefCounted
## The additive layers of a soldier's animation, composed onto the base locomotion pose after InfantryAnimation poses it
## (InfantryLayerSpec holds each game's sequence names):
##   * the weapon-arm sequence (look / lookms / looksn / looknw, Tribes 1 "looks") is scrubbed by the look pitch,
##   * the head sequences by the pitch ("head") and by the head's yaw off the body ("headside"),
##   * the recoil sequence plays once from each shot.
## A scrubbed sequence runs from full look down (position 0) over level (0.5) to full look up (1), as Torque's Player
## maps the look angle over min/maxLookAngle onto the look threads. Nodes a layer moves that the base sequence does not key
## are put back to their rest pose first, so a delta never builds up from frame to frame.
## The keys of a layer at a position are sampled once and cached (QUANT steps per cycle): a soldier holding his aim costs
## one transform multiply per keyed node per layer.

const PoseBlend := preload("res://engine/pose_blend.gd")
## Cache resolution of a scrubbed position.
const QUANT := 64

var _shape: ShapeInstance
var _spec: Dictionary
var _index := {}              # lower sequence name -> index
var _cache := {}              # (sequence << 8 | quantized position) -> [[node, delta basis, delta origin, pose], ...]
var _rest := {}               # node -> rest transform
var _touched := {}            # node -> true: nodes a layer wrote
var _base_nodes := {}         # base sequence index -> {node: true}
var _recoil_t := -1.0         # seconds into the recoil, -1 = not playing
var _last_cooldown := 0.0
var _last_weapon: Weapon = null
var _applied := 0             # layers applied in the last apply(), for tests
## Layer passes run (a soldier that skips the layers leaves it alone).
var passes := 0


func _init(shape: ShapeInstance, shape_id: String) -> void:
	_shape = shape
	_spec = InfantryLayerSpec.make_spec(shape_id)
	var seqs: Array = shape.shape.get("ds_sequences", [])
	for i in seqs.size():
		var n := str(seqs[i].get("name", "")).to_lower()
		if not _index.has(n):
			_index[n] = i


## True when this body has a layer to play (its game has a spec and the shape the sequences).
func has_layers() -> bool:
	return not _spec.is_empty() and (_find(_spec.arm.armed) >= 0 or _find(_spec.head.pitch) >= 0 or _find(_spec.recoil.seq) >= 0)


## Layers applied in the last apply().
func make_layer_count() -> int:
	return _applied


## True while the recoil plays.
func is_recoiling() -> bool:
	return _recoil_t >= 0.0


## Puts the layer pass on the pose of base sequence `base` (the one InfantryAnimation just posed): look `pitch` (up positive)
## within +-`limit`, the head's `yaw` off the body (left positive), weapon `w` in hand (null = unarmed). A shot of `w` (its
## cooldown restarted) starts the recoil.
func apply(base: int, pitch: float, yaw: float, limit: float, w: Weapon, delta: float) -> void:
	_applied = 0
	if _spec.is_empty():
		return
	passes += 1
	_follow_shot(w, delta)
	_restore_unkeyed(base)
	var up := clampf(pitch / maxf(limit, 0.01), -1.0, 1.0)
	var side := clampf(yaw / maxf(limit, 0.01), -1.0, 1.0)
	var weight := float(_spec.weight)
	_apply_layer(_find(_arm_names(w)), _scrub(up), weight)
	_apply_layer(_find(_spec.head.pitch), _scrub(up), weight)
	_apply_layer(_find(_spec.head.yaw), _scrub(side), weight)
	if _recoil_t >= 0.0:
		var r := _find(_spec.recoil.seq)
		var length := ShapeCycles.cycle_seconds(_shape, r, 0.0)
		if r < 0 or _recoil_t >= length:
			_recoil_t = -1.0
		else:
			_apply_layer(r, _recoil_t / length, weight)


## Puts every node a layer wrote back to its rest pose (death and seat poses key the nodes themselves).
func release() -> void:
	for ni in _touched:
		_shape.nodes[ni].transform = _rest_of(ni)
	_touched.clear()
	_recoil_t = -1.0


func _arm_names(w: Weapon) -> Array:
	if w == null:
		return _spec.arm.unarmed
	return _spec.arm.by_weapon.get(_weapon_name(w), _spec.arm.armed)


func _weapon_name(w: Weapon) -> String:
	return str(w.def.get("name", "")).to_upper()


## The cycle position a look in -1..1 (down .. up) scrubs to.
func _scrub(look: float) -> float:
	return 0.5 + (float(_spec.up_at) - 0.5) * look


func _follow_shot(w: Weapon, delta: float) -> void:
	if _recoil_t >= 0.0:
		_recoil_t += delta
	if w == null:
		_last_weapon = null
		return
	var fired := w == _last_weapon and w.cooldown > _last_cooldown + 0.001
	_last_weapon = w
	_last_cooldown = w.cooldown
	var allowed: Array = _spec.recoil.weapons
	if fired and (allowed.is_empty() or allowed.has(_weapon_name(w))):
		_recoil_t = 0.0


## Nodes written by an earlier pass that the base sequence does not key go back to rest.
func _restore_unkeyed(base: int) -> void:
	if _touched.is_empty():
		return
	if not _base_nodes.has(base):
		_base_nodes[base] = ShapeCycles.animated_nodes(_shape, base)
	var keyed: Dictionary = _base_nodes[base]
	for ni in _touched:
		if not keyed.has(ni):
			_shape.nodes[ni].transform = _rest_of(ni)
	_touched.clear()


func _apply_layer(seq: int, pos: float, weight: float) -> void:
	if seq < 0 or weight <= 0.0:
		return
	_applied += 1
	var replace: bool = _spec.mode == "replace"
	for k in _keys_at(seq, pos):
		var ni: int = k[0]
		var node: Node3D = _shape.nodes[ni]
		if replace:
			node.transform = node.transform.interpolate_with(k[3], weight)
		else:
			var rot: Basis = k[1] if weight >= 1.0 else Basis().slerp(k[1], weight)
			node.transform = Transform3D(node.transform.basis * rot, node.transform.origin + k[2] * weight)
		_touched[ni] = true


## [[node, delta basis, delta origin, pose], ...] of sequence `seq` at cycle position `pos`.
func _keys_at(seq: int, pos: float) -> Array:
	var q := clampi(roundi(pos * QUANT), 0, QUANT)
	var key := (seq << 8) | q
	if _cache.has(key):
		return _cache[key]
	var out := []
	var poses := ShapeCycles.make_node_transforms(_shape, seq, float(q) / QUANT)
	var rest_keyed := str(_spec.get("reference", "identity")) == "rest"
	for ni in poses:
		var pose: Transform3D = poses[ni]
		var rest := _rest_of(ni)
		var delta := rest.basis.inverse() * pose.basis if rest_keyed else pose.basis
		out.append([ni, delta, pose.origin - rest.origin if rest_keyed else pose.origin, pose])
	_cache[key] = out
	return out


func _rest_of(ni: int) -> Transform3D:
	if not _rest.has(ni):
		_rest[ni] = PoseBlend.default_transform(_shape, ni)
	return _rest[ni]


func _find(names: Array) -> int:
	for n in names:
		if _index.has(str(n).to_lower()):
			return int(_index[str(n).to_lower()])
	return -1

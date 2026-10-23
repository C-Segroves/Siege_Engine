extends Node
## The additive animation layers of a soldier (InfantryAnimationLayers, InfantryLayerSpec): for every body of Tribes 1, Tribes 2
## (with the Bioderms) and Aerial Assault that has look / head / recoil sequences,
##   * looking up and looking down turn the head and arm bones apart by the angle the sequences' own keys give (up at the end of
##     the look sequence, down at its start), and a level look leaves the base pose alone (Torque blend keys, identity at neutral),
##   * a long run of frames at one aim holds one pose (a layer never builds up on nodes the base sequence does not key),
##   * a shot starts the recoil (the games' recoil weapons only) and it moves bones, then ends,
##   * a FAR_LOD (MID / FAR tier) soldier skips the layers: no layer is applied and his pose is the plain locomotion,
##   * the base locomotion is untouched at a level look with no shot.
##   godot --headless --audio-driver Dummy --path game res://tests/infantry_additive_check.tscn
## Prints "infantry_additive_check: OK" or "FAILED"; exit code 0 / 1. A body that is not imported is skipped.
const PoseBlend := preload("res://engine/pose_blend.gd")
const WATCHDOG_SECONDS := 120.0
const STEP := 1.0 / 60.0
const LIMIT := deg_to_rad(80.0)
const MIN_TURN_DEG := 8.0
const TURN_TOLERANCE_DEG := 1.0
const HOLD_FRAMES := 120
## [armour id, body shape id ("" = the armour's own), a weapon name that recoils ("" = none in this game)].
const CASES := [
	["tribes:LIGHT", "", ""], ["tribes:MEDIUM", "", ""], ["tribes:HEAVY", "", ""],
	["tribes2:LIGHT", "", "SPINFUSOR"], ["tribes2:MEDIUM", "", "MORTAR"], ["tribes2:HEAVY", "", "PLASMA_RIFLE"],
	["tribes2:LIGHT", "tribes2:bioderm_light", "SPINFUSOR"], ["tribes2:MEDIUM", "tribes2:bioderm_medium", "SPINFUSOR"],
	["tribes2:HEAVY", "tribes2:bioderm_heavy", "SPINFUSOR"],
	["tribes:LIGHT", "tribes_aa:light_male", "PLASMA_GUN"], ["tribes:MEDIUM", "tribes_aa:medium_male", "PLASMA_GUN"],
	["tribes:HEAVY", "tribes_aa:heavy_male", "PLASMA_GUN"], ["tribes:LIGHT", "tribes_aa:light_female", "PLASMA_GUN"],
	["tribes:MEDIUM", "tribes_aa:medium_female", "PLASMA_GUN"],
	["tribes:LIGHT", "tribes_aa:light_bioderm", "PLASMA_GUN"], ["tribes:MEDIUM", "tribes_aa:medium_bioderm", "PLASMA_GUN"],
	["tribes:HEAVY", "tribes_aa:heavy_bioderm", "PLASMA_GUN"],
	["tribes:LIGHT", "tribes_v:tv_phoenixlight", ""],
]

var _failures := 0
var _world: Node3D


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _run() -> void:
	Assets.refresh()
	Packs.reload()
	_world = Node3D.new()
	add_child(_world)
	for c in CASES:
		var armor_id: String = c[0]
		var body: String = c[1]
		var shape_id := body if body != "" else str(InfantryCatalog.armor(armor_id).get("shape", ""))
		if InfantryCatalog.armor(armor_id).is_empty() or shape_id == "" or not InfantryCatalog.is_shape_installed(shape_id):
			print("skip  %s / %s (not imported)" % [armor_id, body])
			continue
		var s := _make_soldier(armor_id, body)
		var label := "%s / %s" % [armor_id, shape_id]
		_check_layers(s, label, shape_id, str(c[2]))
		_check_far_skips(s, label)
		s.queue_free()
		await get_tree().process_frame
	print("infantry_additive_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _make_soldier(armor_id: String, body: String) -> Infantry:
	var s := Infantry.new()
	s.armor_id = armor_id
	s.body_shape = body
	s.is_puppet = true
	s.net_id = 1
	_world.add_child(s)
	s.set_physics_process(false)
	return s


func _check_layers(s: Infantry, label: String, shape_id: String, recoil_weapon: String) -> void:
	var anim: InfantryAnimation = s._animation
	var spec := InfantryLayerSpec.make_spec(shape_id)
	_check(anim.has_layers() == not spec.is_empty() and anim.has_layers() == _spec_has_sequences(s, spec), "%s: layers exist exactly when the game has a spec and the shape the sequences" % label)
	if not anim.has_layers():
		return
	var layers := anim.get_layers()
	var w := _make_weapon("BLASTER")
	var level := _pose_at(s, 0.0, w)
	anim.update(Vector3.ZERO, false, false, STEP)
	var base := _snapshot(s)
	var up := _pose_at(s, LIMIT, w)
	var down := _pose_at(s, -LIMIT, w)
	var arm_names: Array = spec.arm.armed
	var arm_seq := _first_sequence(s, arm_names)
	_check(level != up and level != down and up != down, "%s: pitch up, level and down give three different poses" % label)
	_check_node_turn(s, spec, arm_seq, up, down, "%s: weapon arm" % label)
	_check_node_turn(s, spec, _first_sequence(s, spec.head.pitch), up, down, "%s: head" % label)
	_check(layers.make_layer_count() > 0, "%s: layers applied" % label)
	_check_unlayered_nodes_untouched(s, spec, base, up, label)
	_check_offsets_stay_small(s, spec, base, up, down, label)
	# holding one aim holds one pose
	var first := PackedFloat32Array()
	for i in HOLD_FRAMES:
		anim.update(Vector3.ZERO, false, false, 0.0)   # the base pose held still: only the layers could drift
		anim.apply_layers(0.5, 0.0, LIMIT, w, STEP)
		if i == 0:
			first = _snapshot(s)
	_check(_near_pose(_snapshot(s), first, 0.001), "%s: %d frames at one aim hold one pose" % [label, HOLD_FRAMES])
	_check_recoil(s, label, recoil_weapon, spec)
	w.free()


func _check_recoil(s: Infantry, label: String, weapon_name: String, spec: Dictionary) -> void:
	var anim: InfantryAnimation = s._animation
	var layers := anim.get_layers()
	if spec.recoil.seq.is_empty():
		_check(not layers.is_recoiling(), "%s: this game has no recoil sequence" % label)
		return
	if not (spec.recoil.weapons as Array).is_empty():   # a game whose weapons differ: the blaster does not recoil
		var quiet := _make_weapon("BLASTER")
		_run_frame(s, quiet, 0.0)
		_run_frame(s, quiet, 0.0)
		quiet.cooldown = 0.5
		_run_frame(s, quiet, 0.0)
		_check(not layers.is_recoiling(), "%s: a weapon without recoil does not recoil" % label)
		quiet.free()
	var w := _make_weapon(weapon_name)
	_run_frame(s, w, 0.0)
	_run_frame(s, w, 0.0)
	var rest := _snapshot(s)
	w.cooldown = 0.5
	var moved := false
	var started := false
	for i in 30:
		_run_frame(s, w, 0.0)
		started = started or layers.is_recoiling()
		moved = moved or not _near_pose(_snapshot(s), rest, 0.0005)
	_check(started, "%s: a shot of %s starts the recoil" % [label, weapon_name])
	_check(moved, "%s: the recoil moves bones" % label)
	for i in 40:
		_run_frame(s, w, 0.0)
	_check(not layers.is_recoiling(), "%s: the recoil ends" % label)
	var after := _snapshot(s)
	for ni in s.shape.nodes.size():
		if not _near_node(rest, after, ni):
			print("   node ", ni, " ", s.shape.nodes[ni].name, " differs")
	_check(_near_pose(after, rest, 0.0005), "%s: and the pose comes back" % label)
	w.free()


func _check_far_skips(s: Infantry, label: String) -> void:
	if not s._animation.has_layers():
		return
	var w := _make_weapon("BLASTER")
	s.weapons = [w]
	s.weapon_slot = 0
	s.pitch = 0.9
	var layers: InfantryAnimationLayers = s._animation.get_layers()
	layers.release()
	var passes := layers.passes
	s.far_lod = true
	s._animate(STEP, false)
	var far_pose := _snapshot(s)
	_check(layers.passes == passes, "%s: a FAR_LOD soldier applies no layer" % label)
	s.far_lod = false
	s._animate(STEP)
	_check(layers.passes == passes + 1 and layers.make_layer_count() > 0, "%s: a NEAR soldier applies them" % label)
	_check(not _near_pose(_snapshot(s), far_pose, 0.001), "%s: and the pose differs from the plain locomotion" % label)
	s.weapons = []
	w.free()


func _spec_has_sequences(s: Infantry, spec: Dictionary) -> bool:
	return not spec.is_empty() and (_first_sequence(s, spec.arm.armed) >= 0 or _first_sequence(s, spec.head.pitch) >= 0 or _first_sequence(s, spec.recoil.seq) >= 0)


func _first_sequence(s: Infantry, names: Array) -> int:
	return ShapeCycles.find_named(s.shape, names)


## The base locomotion is untouched: every bone no layer sequence keys is as the base pose had it, looking up.
func _check_unlayered_nodes_untouched(s: Infantry, spec: Dictionary, base: PackedFloat32Array, up: PackedFloat32Array, label: String) -> void:
	var layered := {}
	for names in [spec.arm.armed, spec.arm.unarmed, spec.head.pitch, spec.head.yaw, spec.recoil.seq]:
		var seq := _first_sequence(s, names)
		for ni in ShapeCycles.make_node_transforms(s.shape, seq, 0.5):
			layered[ni] = true
	var changed := 0
	for ni in s.shape.nodes.size():
		if not layered.has(ni) and not _near_node(base, up, ni):
			changed += 1
	_check(changed == 0, "%s: bones the layers do not key keep the base locomotion (%d changed)" % [label, changed])


## A layer adds a bone's offset delta, it never replaces the offset: no bone drifts further than its own rest offset (Aerial Assault stretches one by 0.8x).
## (Shape units are 1/256 m, offsets are tiny: a flipped or doubled offset is the failure this catches.)
func _check_offsets_stay_small(s: Infantry, spec: Dictionary, base: PackedFloat32Array, up: PackedFloat32Array, down: PackedFloat32Array, label: String) -> void:
	if spec.mode == "replace":
		return
	var worst := 0.0
	for ni in s.shape.nodes.size():
		var rest_len := PoseBlend.default_transform(s.shape, ni).origin.length()
		for snap in [up, down]:
			var drift := Vector3(snap[ni * 12 + 9] - base[ni * 12 + 9], snap[ni * 12 + 10] - base[ni * 12 + 10], snap[ni * 12 + 11] - base[ni * 12 + 11]).length()
			worst = maxf(worst, drift - rest_len)
	_check(worst <= 0.0, "%s: layers do not move a bone's offset past its own rest offset" % label)


func _near_node(a: PackedFloat32Array, b: PackedFloat32Array, ni: int) -> bool:
	for i in range(ni * 12, ni * 12 + 12):
		if absf(a[i] - b[i]) > 0.0005:
			return false
	return true


## The keyed node of `seq` that turns most between the up and the down look, as the sequences' own keys give it composed in layer
## order (arm, then head), against the turn measured on the posed bones.
func _check_node_turn(s: Infantry, spec: Dictionary, seq: int, up: PackedFloat32Array, down: PackedFloat32Array, what: String) -> void:
	if seq < 0:
		return
	var best_node := -1
	var best := 0.0
	for ni in ShapeCycles.make_node_transforms(s.shape, seq, 0.5):
		var turn := _turn_between(_expected_basis(s, spec, ni, true), _expected_basis(s, spec, ni, false))
		if turn > best:
			best = turn
			best_node = ni
	_check(best >= MIN_TURN_DEG, "%s: the sequence turns a bone %.0f degrees between up and down" % [what, best])
	if best_node < 0:
		return
	var measured := _turn_between(_basis_of(up, best_node), _basis_of(down, best_node))
	_check(absf(measured - best) <= TURN_TOLERANCE_DEG, "%s: bone %d turns %.1f degrees up to down (keys say %.1f)" % [what, best_node, measured, best])


## The rotation the layers give node `ni` at full look up / down, from a base of identity.
func _expected_basis(s: Infantry, spec: Dictionary, ni: int, looking_up: bool) -> Basis:
	var pos := float(spec.up_at) if looking_up else 1.0 - float(spec.up_at)
	var out := Basis()
	for seq in [_first_sequence(s, spec.arm.armed), _first_sequence(s, spec.head.pitch)]:
		var keyed := ShapeCycles.make_node_transforms(s.shape, seq, pos)
		if not keyed.has(ni):
			continue
		var rest := PoseBlend.default_transform(s.shape, ni)
		var key: Basis = keyed[ni].basis
		if spec.mode == "replace":
			out = key
		else:
			out = out * ((rest.basis.inverse() * key) if spec.reference == "rest" else key)
	return out


func _turn_between(a: Basis, b: Basis) -> float:
	return rad_to_deg(a.get_rotation_quaternion().angle_to(b.get_rotation_quaternion()))


func _make_weapon(weapon_name: String) -> Weapon:
	var w := Weapon.new()
	w.def = {"name": weapon_name}
	return w


## Poses the soldier standing, then looks `pitch` with `w` in hand: the bones as a flat array.
func _pose_at(s: Infantry, pitch: float, w: Weapon) -> PackedFloat32Array:
	s.weapons = [w]
	s.weapon_slot = 0
	s.pitch = pitch
	_run_frame(s, w, pitch)
	return _snapshot(s)


func _run_frame(s: Infantry, w: Weapon, pitch: float) -> void:
	s.weapons = [w]
	s.weapon_slot = 0
	s._animation.update(Vector3.ZERO, false, false, 0.0)   # the base pose held still
	s._animation.apply_layers(pitch, 0.0, LIMIT, w, STEP)


## Every bone's local basis (9 floats) and origin (3).
func _snapshot(s: Infantry) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for n in s.shape.nodes:
		var t := (n as Node3D).transform
		out.append_array([t.basis.x.x, t.basis.x.y, t.basis.x.z, t.basis.y.x, t.basis.y.y, t.basis.y.z, t.basis.z.x, t.basis.z.y, t.basis.z.z, t.origin.x, t.origin.y, t.origin.z])
	return out


func _basis_of(snap: PackedFloat32Array, node: int) -> Basis:
	var i := node * 12
	return Basis(Vector3(snap[i], snap[i + 1], snap[i + 2]), Vector3(snap[i + 3], snap[i + 4], snap[i + 5]), Vector3(snap[i + 6], snap[i + 7], snap[i + 8]))


func _near_pose(a: PackedFloat32Array, b: PackedFloat32Array, eps: float) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if absf(a[i] - b[i]) > eps:
			return false
	return true

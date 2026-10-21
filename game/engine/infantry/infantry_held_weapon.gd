class_name InfantryHeldWeapon
extends RefCounted
## The weapon in a soldier's hand, drawn twice (docs/formats/tribes_infantry.md section 4):
##   * the world model on the armour's hand node (Tribes "dummy hand" / Tribes 2 "mount0"): what other players
##     and the chase camera see; it shares the body's render layers, so the first-person camera hides it with
##     the body;
##   * the view model at a fixed offset from the eye: the first-person weapon. It is on VIEW_MODEL_LAYER (the
##     chase camera leaves that layer out) and only shown for the player who looks through this eye.
## Both models are animated as the originals' weapon images (InfantryWeaponAnimation: the draw, each shot and
## its reload, ambient and spin loops). Darkstar weapon shapes rest at the first key of their "activation" (draw)
## sequence, with the gun swung out behind the grip; after the draw they rest at its last key.

## Render layer bit of first-person view models (BattleCameras: the chase camera does not draw it).
const VIEW_MODEL_LAYER := 4
const READY_SEQUENCE := "activation"
const READY_PHASE := 1.0
## Tribes 2 weapons name their grip node; Tribes 1 weapons are gripped at the shape origin.
const GRIP_NODE := "mountpoint"

## Where the view model's grip sits relative to the eye (metres: right, down, forward).
var view_offset: Vector3
var view_shown := false
## The world model shows (false while the soldier pilots or guns a vehicle: the originals unmount his weapon).
var world_shown := true
var world_model: ShapeInstance
var view_model: ShapeInstance
var _animations: Array[InfantryWeaponAnimation] = []
var _hand: Node3D
var _rest_correction := Basis.IDENTITY
var _grip := Vector3.ZERO
var _world_scale := Vector3.ONE
var _last_cooldown := 0.0


func _init(p_view_offset: Vector3) -> void:
	view_offset = p_view_offset


## Replaces both models with the model of weapon `w` (nothing for null or a weapon without a model).
func build(w: Weapon, body: ShapeInstance, hand_node: int, eye: Node3D) -> void:
	clear()
	var shape_id := make_shape_id(w)
	if shape_id == "" or body == null or eye == null:
		return
	var palette := Packs.default_palette(str(w.def.get("pack", "tribes")))
	var body_layers := make_body_layers(body)
	world_model = make_ready_model(shape_id, palette)
	_hand = body.nodes[hand_node] if hand_node >= 0 and hand_node < body.nodes.size() else body
	_world_scale = world_model.scale / body.scale   # the hand node already carries the body's unit scale
	_grip = make_grip_offset(world_model)
	_rest_correction = HandMount.make_rest_correction(body, hand_node)
	_hand.add_child(world_model)
	apply_mount_pose()
	apply_layers(world_model, body_layers)
	world_model.visible = world_shown
	view_model = make_ready_model(shape_id, palette)
	view_model.position = view_offset - make_grip_offset(view_model) * view_model.scale
	view_model.visible = view_shown
	eye.add_child(view_model)
	apply_layers(view_model, VIEW_MODEL_LAYER)
	var roles: Dictionary = w.def.get("model", {}).get("animation", {})
	for m in [world_model, view_model]:
		var anim := InfantryWeaponAnimation.new(m, roles)
		anim.apply_draw()
		_animations.append(anim)
	_last_cooldown = w.cooldown


## The world model in the hand with the calibrated mount rotation (HandMount): dead, seated, or before the first aim.
func apply_mount_pose() -> void:
	_place_world_model(_rest_correction)


## The world model's muzzle along world basis `aim`, its grip still on the hand node (a living soldier).
func apply_aim(aim: Basis) -> void:
	if is_instance_valid(world_model) and is_instance_valid(_hand):
		_place_world_model(HandMount.make_aim_rotation(_hand, aim))


## Turns the world model by `rotation` (hand node frame) about its grip, which stays at the hand node's origin.
func _place_world_model(rotation: Basis) -> void:
	if not is_instance_valid(world_model):
		return
	world_model.basis = rotation * Basis.from_scale(_world_scale)
	world_model.position = rotation * (-_grip * _world_scale)


## One frame of weapon `w` in hand: a shot (its refire timer restarted) plays fire and reload; the loops run.
func update(w: Weapon, delta: float) -> void:
	if w == null or _animations.is_empty():
		return
	var fired := w.cooldown > _last_cooldown + 0.001
	_last_cooldown = w.cooldown
	var empty := w.ammo == 0 and w.ammo_max >= 0
	for anim in _animations:
		if fired:
			anim.apply_fired()
		anim.update(delta, w.trigger, empty)


## The weapon animations (world model first, then the view model; tests read them).
func make_animations() -> Array[InfantryWeaponAnimation]:
	return _animations.duplicate()


## Frees both models (also safe after their parents were freed).
func clear() -> void:
	for m in [world_model, view_model]:
		if not is_instance_valid(m):
			continue
		if m.get_parent():
			m.get_parent().remove_child(m)   # out of the body now, so its layers are not read as the body's
		m.queue_free()
	world_model = null
	view_model = null
	_animations.clear()


## Shows or hides the first-person view model (the local player's soldier only).
func apply_world_shown(on: bool) -> void:
	world_shown = on
	if is_instance_valid(world_model):
		world_model.visible = on


func apply_view_shown(on: bool) -> void:
	view_shown = on
	if is_instance_valid(view_model):
		view_model.visible = on


## The weapon's first mount shape ("" when it has none).
static func make_shape_id(w: Weapon) -> String:
	if w == null:
		return ""
	var shapes: Array = w.def.get("model", {}).get("mount_shapes", [])
	return str(shapes[0]) if not shapes.is_empty() else ""


## A weapon shape in its ready pose.
static func make_ready_model(shape_id: String, palette: String) -> ShapeInstance:
	var model := ShapeInstance.new()
	model.build(Assets.shape(shape_id), 0, palette)
	var ready := find_sequence(model, READY_SEQUENCE)
	if ready >= 0:
		ShapeCycles.pose(model, ready, READY_PHASE, false)
	return model


## Index of the Darkstar sequence called `seq_name` (any case), -1 when missing.
static func find_sequence(model: ShapeInstance, seq_name: String) -> int:
	return ShapeCycles.find_named(model, [seq_name])


## The way a weapon model points: its shape's -Z axis in world space (the grip node and the shape agree on it).
static func make_forward(model: Node3D) -> Vector3:
	return (-model.global_basis.z).normalized()


## The grip node's position in the model's own (unscaled) space; zero when the shape has none.
static func make_grip_offset(model: ShapeInstance) -> Vector3:
	var node_list: Array = model.shape.get("nodes", [])
	for i in node_list.size():
		if str(node_list[i].get("name", "")).to_lower() == GRIP_NODE:
			var n: Node3D = model.nodes[i]
			var xf := Transform3D()
			while n != null and n != model:
				xf = n.transform * xf
				n = n.get_parent() as Node3D
			return xf.origin
	return Vector3.ZERO


## The render layers the body's meshes are on now (BattleCameras moves the player's own body to its own layer).
static func make_body_layers(body: ShapeInstance) -> int:
	var meshes := body.find_children("*", "MeshInstance3D", true, false)
	return (meshes[0] as MeshInstance3D).layers if not meshes.is_empty() else 1


static func apply_layers(model: Node3D, layers: int) -> void:
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).layers = layers

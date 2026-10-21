class_name LobbyArmament
extends RefCounted
## The weapons a lobby carousel model carries: the soldier's primary in his hand and the vehicle's weapons on its hardpoints.
## It uses the same mounts as the battle (HandMount, InfantryHeldWeapon's grip rules, HercModel's hardpoint frames).

const STAND_SEQUENCE := "root"
const STAND_PHASE := 0.0


## The weapon a soldier of armour `armor_id` holds when the match starts: the first of the weapons he spawns with.
static func make_held_weapon(entry: Dictionary, armor_id: String) -> String:
	var spawn := SpawnLoadout.make_for(entry, armor_id)
	return str(spawn[0]) if not spawn.is_empty() else ""


## Puts the soldier's body in its stand pose, so the hand node sits where the hand mount was calibrated.
static func apply_stand_pose(body: ShapeInstance) -> void:
	ShapeCycles.pose(body, ShapeCycles.find_named(body, [STAND_SEQUENCE]), STAND_PHASE, false)


## Puts weapon `weapon_id` in the hand of `body` (a built soldier; `armor_id` names the armour whose hand node it uses).
static func apply_held_weapon(body: ShapeInstance, armor_id: String, weapon_id: String) -> void:
	var shape_id := _make_mount_shape(Packs.weapon(weapon_id))
	var hand_node := make_hand_node(armor_id, str(body.shape.get("id", "")))
	if shape_id == "" or hand_node < 0 or hand_node >= body.nodes.size():
		return
	var model := InfantryHeldWeapon.make_ready_model(shape_id, Packs.default_palette(str(Packs.weapon(weapon_id).get("pack", "tribes"))))
	var hand: Node3D = body.nodes[hand_node]
	hand.add_child(model)
	var scale_in_hand := model.scale / body.scale   # the hand node already carries the body's unit scale
	var grip := InfantryHeldWeapon.make_grip_offset(model)
	var rotation := HandMount.make_rest_correction(body, hand_node)
	model.basis = rotation * Basis.from_scale(scale_in_hand)
	model.position = rotation * (-grip * scale_in_hand)


## The armour's hand node in body shape `body_shape_id` (found by name when the body is not the armour's own); -1 when none.
static func make_hand_node(armor_id: String, body_shape_id: String) -> int:
	var armor := InfantryCatalog.armor(armor_id)
	var hand := int(armor.get("hand_node", -1))
	var own_id := str(armor.get("shape", ""))
	if body_shape_id == "" or body_shape_id == own_id or hand < 0:
		return hand
	var own: Array = Assets.shape(own_id).get("nodes", [])
	var wanted := Infantry.make_node_stem(str(own[hand].get("name", ""))) if hand < own.size() else ""
	var nodes: Array = Assets.shape(body_shape_id).get("nodes", [])
	for i in nodes.size():
		if Infantry.make_node_stem(str(nodes[i].get("name", ""))) == wanted:
			return i
	for i in nodes.size():
		if str(nodes[i].get("name", "")) == InfantryCatalog.AA_HAND_NODE:
			return i
	return -1


## Builds the hardpoint frames of `vehicle` (a built ShapeInstance of vehicle def `vdef`) and puts the weapon of each hardpoint
## of `loadout` (weapon ids in gun order, "" = empty) on it, as the hangar shows them.
static func apply_vehicle_weapons(vehicle: ShapeInstance, vdef: Dictionary, loadout: Array) -> void:
	var frames := HercModel.build_mounts(vdef, vehicle)
	HercAnimator.new(vdef, vehicle).apply_stand()
	var mounts := HercModel.mount_nodes(vdef, vehicle, frames)
	HercModel.show_baked_pods(vdef, vehicle)
	var guns: Array = vdef.get("guns", [])
	var category := str(vdef.get("category", "herc"))
	for i in mini(loadout.size(), guns.size()):
		var weapon := Packs.weapon(str(loadout[i]) if loadout[i] != null else "")
		if weapon.is_empty() or str(weapon.get("category", "herc")) != category:
			continue   # weapon families never mix
		var pod := HercModel.weapon_model(vdef, i, weapon, vehicle.palette_name)
		if pod != null:
			HercModel.attach_weapon_model(mounts[i % mounts.size()], pod, vdef)


static func _make_mount_shape(weapon: Dictionary) -> String:
	var shapes: Array = weapon.get("model", {}).get("mount_shapes", [])
	return str(shapes[0]) if not shapes.is_empty() else ""

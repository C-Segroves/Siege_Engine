extends Node
## The weapon in a soldier's hands (InfantryHeldWeapon, HandMount): for every installed infantry game, armour and
## body (Tribes 1, Tribes 2 with the Bioderms, Aerial Assault, Vengeance) and several weapons each:
##   * the grip sits on the hand node, within GRIP_LIMIT_M;
##   * the third-person muzzle points along the soldier's aim within ANGLE_LIMIT_DEG, level and pitched up / down;
##   * in the root pose with the calibrated mount alone (dead, seated) it points along the body's forward;
##   * the first-person view model points along the eye's forward, with its grip at the view offset.
##   godot --headless --audio-driver Dummy --path game res://tests/held_weapon_check.tscn

const ANGLE_LIMIT_DEG := 3.0
const GRIP_LIMIT_M := 0.03
const WEAPONS_PER_BODY := 3
const PITCHES := [0.0, 0.6, -0.6]
const YAW := 0.9
const WATCHDOG_SECONDS := 240.0

var _failures := 0
var _checked := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_failures += 1
		print("FAIL  ", what)


func _run() -> void:
	for pack in InfantryCatalog.make_infantry_packs():
		for armor in InfantryCatalog.armors_of(str(pack.pack)):
			await _check_armor(armor)
	_expect(_checked > 0, "some body was checked")
	print("held_weapon_check: %s (%d checks, %d failures)" % ["OK" if _failures == 0 else "FAILED", _checked, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _check_armor(armor: Dictionary) -> void:
	var bodies := InfantryCatalog.make_bodies(str(armor.id))
	for i in bodies.size():
		var soldier := Infantry.new()
		soldier.armor_id = str(armor.id)
		soldier.body_shape = "" if i == 0 else str(bodies[i].id)
		soldier.net_id = 1
		add_child(soldier)
		soldier.set_physics_process(false)
		for loadout in _make_loadouts(armor, str(bodies[i].id)):
			soldier.equip(loadout)
			for slot in soldier.weapons.size():
				soldier.apply_weapon_slot(slot)
				_check_weapon(soldier, "%s / %s / %s" % [armor.id, bodies[i].id, soldier.weapons[slot].weapon_id])
		soldier.queue_free()
		await get_tree().process_frame


## The loadouts to check on a body: the armour's first weapons, and for an Aerial Assault / Vengeance body all the weapons of its
## game (infantry_rules.json) in groups of the armour's weapon slots, so every model of the two games is held once.
func _make_loadouts(armor: Dictionary, body_id: String) -> Array:
	var rules := InfantryCatalog.make_pack_rules(body_id.get_slice(":", 0), str(armor.get("size", "light")).to_upper())
	if rules.is_empty():
		return [(armor.get("weapons", []) as Array).slice(0, WEAPONS_PER_BODY)]
	var out := []
	var all: Array = rules.weapons
	var slots := int(armor.get("max_weapons", WEAPONS_PER_BODY))
	for first in range(0, all.size(), slots):
		out.append(all.slice(first, first + slots))
	return out


func _check_weapon(soldier: Infantry, label: String) -> void:
	var held := soldier.held
	var hand: Node3D = soldier.shape.nodes[soldier.make_hand_node()]
	soldier.rotation.y = YAW
	soldier.shape.reset_pose()
	ShapeCycles.pose(soldier.shape, ShapeCycles.find_named(soldier.shape, [HandMount.ROOT_SEQUENCE]), HandMount.ROOT_PHASE, false)
	held.apply_mount_pose()
	_expect_along(InfantryHeldWeapon.make_forward(held.world_model), -soldier.global_basis.z, "%s: mount pose along the body" % label)
	for pitch in PITCHES:
		soldier.pitch = pitch
		soldier._animate(0.016)
		var aim := -soldier.eye.global_basis.z
		var grip := held.world_model.global_transform * InfantryHeldWeapon.make_grip_offset(held.world_model)
		_expect(grip.distance_to(hand.global_position) <= GRIP_LIMIT_M,
			"%s: grip %.3f m from the hand (pitch %.1f)" % [label, grip.distance_to(hand.global_position), pitch])
		_expect_along(InfantryHeldWeapon.make_forward(held.world_model), aim, "%s: third-person muzzle, pitch %.1f" % [label, pitch])
		_expect_along(InfantryHeldWeapon.make_forward(held.view_model), aim, "%s: first-person muzzle, pitch %.1f" % [label, pitch])
	var view_grip := held.view_model.global_transform * InfantryHeldWeapon.make_grip_offset(held.view_model)
	var want := soldier.eye.global_transform * held.view_offset
	_expect(view_grip.distance_to(want) <= GRIP_LIMIT_M, "%s: view model grip at the view offset" % label)


func _expect_along(forward: Vector3, aim: Vector3, what: String) -> void:
	var degrees := rad_to_deg(forward.angle_to(aim))
	_expect(degrees <= ANGLE_LIMIT_DEG, "%s (%.1f deg off the aim)" % [what, degrees])

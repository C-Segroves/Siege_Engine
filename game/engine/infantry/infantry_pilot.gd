class_name InfantryPilot
extends PlayerPilot
## The local player's controls on foot (docs/CODING_STANDARDS.md section 2; Tribes 1 default keymap,
## config/config.cs): the same actions as a Herc where they mean the same thing.
##   throttle_up / throttle_down   run forward / back (W / S)
##   turn_left / turn_right        strafe (A / D)
##   mouse, right stick            look (body yaw and pitch)
##   ascend                        jump (Space; held on the ground: keep sliding - skiing)
##   jet                           jetpack (mouse right, the original IDACTION_JET)
##   fire_group_1                  fire the weapon in hand
##   weapon_next                   next carried weapon (Q, the original nextWeapon)
##   torso_center                  level the view
## vehicle_enter_exit, seat_next and the jump out of a Tribes vehicle are handled by the OccupancyDirector;
## grenade_throw, mine_drop, pack_use and repair_kit_use by the InfantryGearDirector.

var soldier: Infantry


## The pilot for a soldier on foot.
static func make_for_soldier(s: Infantry) -> InfantryPilot:
	var p := InfantryPilot.new()
	p.herc = s
	p.soldier = s
	p.aim_yaw = s.rotation.y
	return p


func _apply_command(event: InputEvent) -> void:
	if event.is_action_pressed("weapon_next"):
		soldier.apply_weapon_slot(soldier.make_next_slot())
	else:
		super._apply_command(event)


func _apply_drive(delta: float) -> void:
	_apply_aim(SiegeInput.make_stick_look(delta))
	soldier.throttle = SiegeInput.make_throttle_axis()
	soldier.turn = SiegeInput.make_turn_axis()
	soldier.torso_target = aim_yaw
	soldier.pitch_target = aim_pitch
	soldier.jump_input = Input.is_action_pressed("ascend")
	soldier.jet_input = _may_use_mouse_buttons() and Input.is_action_pressed("jet")


## Looks round: yaw is unlimited on foot (within the view arc in an armed passenger seat), pitch within the
## armour's look limits.
func _apply_aim(look: Vector2) -> void:
	if look == Vector2.ZERO:
		return
	aim_yaw = soldier.make_allowed_yaw(wrapf(aim_yaw - look.x, -PI, PI))   # an armed seat's arc
	aim_pitch = clampf(aim_pitch - look.y, soldier.pitch_min, soldier.pitch_max)


func _center_aim() -> void:
	aim_pitch = 0.0


## Only the weapon in hand fires (Tribes carries one weapon at a time).
func _apply_triggers() -> void:
	var pulled := _autofire or (_may_use_mouse_buttons() and Input.is_action_pressed("fire_group_1"))
	var in_hand := soldier.current_weapon()
	for w in soldier.weapons:
		w.trigger = pulled and w == in_hand


func _may_use_mouse_buttons() -> bool:
	return _is_mouse_captured() or SiegeInput.is_gamepad_active()

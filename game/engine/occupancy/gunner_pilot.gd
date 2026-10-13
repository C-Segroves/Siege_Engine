class_name GunnerPilot
extends PlayerPilot
## The local player's controls in a gunner seat (TurretCrew; tribes_vehicles.md section 6): mouse / right stick
## aim the turret within its arc, fire_group_1 / fire_group_2 fire the turret weapons (Thundersword: fusion
## guns / bombs, Beowulf: chaingun / mortar, as BomberTurret / AssaultPlasmaTurret::onTrigger switch them).
## Driving is the pilot's: throttle and turn do nothing here.
## The aim goes to the vehicle's TurretCrew on the host; on a client it rides the vehicle's control fields,
## which BattleNetSync sends to the host (OccupancyDirector.apply_crew_controls).

var crew: TurretCrew
var _pitch_range := Vector2.ZERO


## The pilot for the gunner seat of `vehicle`.
static func make_for_gunner(vehicle: Herc) -> GunnerPilot:
	var p := GunnerPilot.new()
	p.herc = vehicle
	p.crew = TurretCrew.of(vehicle)
	p._pitch_range = VehicleSeats.make_gunner_pitch_range(vehicle)
	p.aim_yaw = p.crew.torso_target
	p.aim_pitch = clampf(p.crew.pitch_target, p._pitch_range.x, p._pitch_range.y)
	return p


## Targeting and the view work; the throttle belongs to the pilot.
func _apply_command(event: InputEvent) -> void:
	if not event.is_action_pressed("throttle_stop"):
		super._apply_command(event)


func _apply_drive(delta: float) -> void:
	_apply_aim(SiegeInput.make_stick_look(delta))
	crew.torso_target = aim_yaw
	crew.pitch_target = aim_pitch
	herc.torso_target = aim_yaw
	herc.pitch_target = aim_pitch


## A flyer's belly turret turns all the way round; a tank turret within the vehicle's torso limit.
func _apply_aim(look: Vector2) -> void:
	if look == Vector2.ZERO:
		return
	var limit := PI if herc is Flyer else herc.torso_limit
	aim_yaw = make_turned_yaw(aim_yaw - look.x, limit)
	aim_pitch = clampf(aim_pitch - look.y, _pitch_range.x, _pitch_range.y)


func _apply_triggers() -> void:
	var may_fire := _is_mouse_captured() or SiegeInput.is_gamepad_active()
	var held := []
	for action in FIRE_GROUP_ACTIONS:
		held.append(_autofire or (may_fire and Input.is_action_pressed(action)))
	crew.apply_fire_groups(held[0], held[1])
	HercSnapshots.apply_trigger_bits(herc, crew.trigger_bits)

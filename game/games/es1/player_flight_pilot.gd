class_name PlayerFlightPilot
extends PlayerPilot
## The local player's flight controls for a Flyer (docs/formats/flight_model.md §3), through the
## SiegeInput actions; firing, targeting and the view work as for a Herc:
##   throttle_up / throttle_down   throttle (idle .. full; reverse for hover craft), throttle_stop idle
##   turn_left / turn_right        bank (Earthsiege 2 jets: coordinated turn) / steer (hover craft)
##   mouse, right stick            nose: x = rudder / yaw, y = pitch (a spring-centred virtual stick)
##   ascend / descend              nose up / down (jets) or lift (hover craft)
##   torso_center                  centre the stick

## Mouse look (radians, SiegeInput.make_mouse_look) that gives full stick deflection.
const MOUSE_FULL_DEFLECTION := 0.12
## The mouse stick springs back to centre at this rate (1/s).
const MOUSE_STICK_RECENTER := 3.0

var _mouse_stick := Vector2.ZERO   # x = right, y = down (screen convention)


func _apply_drive(delta: float) -> void:
	var fl := herc as Flyer
	_mouse_stick = _mouse_stick.move_toward(Vector2.ZERO, MOUSE_STICK_RECENTER * delta)
	var stick := (_mouse_stick + SiegeInput.make_aim_axes()).clampf(-1.0, 1.0)
	var low := -1.0 if fl.flight is HoverFlightModel else 0.0
	fl.throttle = clampf(fl.throttle + SiegeInput.make_throttle_axis() * THROTTLE_RATE * delta, low, 1.0)
	fl.lift_input = SiegeInput.make_lift_axis()
	if herc.missile_steering.is_steering():
		_apply_missile_stick(delta)   # the stick flies the EO missile; the flyer holds its course
		fl.turn = 0.0
		fl.yaw_input = 0.0
		fl.pitch_input = 0.0
		return
	fl.turn = SiegeInput.make_turn_axis()
	fl.yaw_input = stick.x
	fl.pitch_input = -stick.y


## Mouse motion deflects the virtual stick.
func _apply_aim(look: Vector2) -> void:
	_mouse_stick = (_mouse_stick + look / MOUSE_FULL_DEFLECTION).clampf(-1.0, 1.0)


func _center_aim() -> void:
	_mouse_stick = Vector2.ZERO

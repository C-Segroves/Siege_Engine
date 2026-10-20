class_name HoverFlightModel
extends FlightModel
## Tribes-style flier (Scout, LAPC, HAPC; FlierData in scripts/vehicle.cs): a VTOL craft that
## hovers when idle. Datablock fields used: maxSpeed / minSpeed (reverse), accel, lift, maxAlt
## (hard ceiling above the ground), maxVertical (climb / sink rate), maxBank / maxPitch (visual
## attitude). The Darkstar flier physics code is not decoded, so the laws below are approximations
## (docs/formats/flight_model.md §2):
##   - throttle sets the forward speed (reverse down to minSpeed), reached at `accel`;
##   - turn and rudder input yaw the craft at `turn_rate`, banking it up to maxBank;
##   - the nose pitches up to maxPitch with the stick and converts forward speed into climb;
##   - ascend / descend command up to maxVertical, reached at the lift acceleration;
##   - near the ground a cushion holds it at `hover_height`; above maxAlt it sinks back.

## Attitude change rate towards the commanded bank / pitch (rad/s).
const ATTITUDE_RATE := 1.5
## Spring of the ground cushion and of the altitude limit (1/s: m/s per metre of error).
const CUSHION_SPRING := 2.0
const ALTITUDE_SPRING := 1.0
func _step_air(c: FlightControls, agl: float, delta: float) -> void:
	_apply_speed(c, delta)
	var turn := clampf(c.roll + c.yaw, -1.0, 1.0)
	heading -= turn * float(params.turn_rate) * delta
	bank = move_toward(bank, turn * float(params.max_bank), ATTITUDE_RATE * delta)
	pitch = move_toward(pitch, c.pitch * float(params.max_pitch), ATTITUDE_RATE * delta)
	var climb := move_toward(velocity.y, _make_climb_target(c, agl), float(params.lift_accel) * delta)
	velocity = make_body_basis() * Vector3.FORWARD * speed * cos(pitch) + Vector3.UP * climb


func _apply_speed(c: FlightControls, delta: float) -> void:
	var target := c.throttle * float(params.max_speed) if c.throttle >= 0.0 else -c.throttle * float(params.min_speed)
	speed = move_toward(speed, target, float(params.accel) * delta)


## Commanded vertical speed: lift input plus the nose's share of the forward speed, held up by
## the ground cushion unless descending and capped by the altitude limit.
func _make_climb_target(c: FlightControls, agl: float) -> float:
	var max_vertical := float(params.max_vertical)
	var target := clampf(c.lift * max_vertical + speed * sin(pitch), -max_vertical, max_vertical)
	var hover_height := float(params.hover_height)
	if c.lift >= 0.0 and agl < hover_height:
		target = maxf(target, (hover_height - agl) * CUSHION_SPRING)
	return minf(target, (float(params.max_alt) - agl) * ALTITUDE_SPRING)


## On the ground until the pilot lifts or throttles; then the cushion raises it.
func _step_landed(c: FlightControls, delta: float) -> void:
	speed = move_toward(speed, 0.0, float(params.accel) * delta)
	heading -= clampf(c.roll + c.yaw, -1.0, 1.0) * float(params.turn_rate) * delta
	velocity = Vector3.ZERO
	if c.lift > 0.0 or (c.lift == 0.0 and absf(c.throttle) > 0.0):
		landed = false
		velocity = Vector3.UP * minf(float(params.max_vertical), float(params.hover_height) * CUSHION_SPRING)


func make_ceiling() -> float:
	return float(params.max_alt)


func make_climb_scale() -> float:
	return float(params.max_vertical)


func make_climb_accel() -> float:
	return float(params.lift_accel)


func make_vertical_rate() -> float:
	return float(params.max_vertical)


## Turns on the turn stick (banking up to maxBank), pitches the nose and lifts for the part of the climb the nose does not make.
func make_controls(c: FlightCommand) -> FlightControls:
	var nose := clampf(c.pitch / float(params.max_pitch), -1.0, 1.0)
	var lift := clampf((c.climb - speed * sin(pitch)) / float(params.max_vertical), -1.0, 1.0)
	return FlightControls.make(c.throttle, c.turn, Vector2(0.0, nose), lift)

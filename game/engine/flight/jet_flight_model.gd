class_name JetFlightModel
extends FlightModel
## Earthsiege 2 flight model (Razor, Skimmer): DBSIM.EXE 1.0 0x466a54, parameters from the FM file
## (FlightPresets.decode_fm). Original behaviour per 125 ms frame, scaled by the frame time:
##   - throttle sets a target speed between the minimum and maximum speed; nose up bleeds speed,
##     nose down gains it (0x466b0f..0x466ba4); the speed approaches it by `speed_accel`;
##   - pitch, roll and rudder rates follow FlightModel.make_rate; released roll levels the wings
##     (rate demand = -bank >> shift); the heading turns by bank >> turn shift (coordinated turn);
##   - the ceiling above the ground grows linearly with speed; above it the nose is forced down
##     (0x466d0b, 0x466e0a);
##   - sideslip and vertical drift decay to `slip_keep` per frame (0x466c26), so the craft flies
##     where the nose points; there is no gravity term.
## Remake additions (approximations): bank and pitch limits, taxiing, take-off and landing.

## Hard ceiling: no further climb this far above the soft (original) ceiling. The original only
## forces the nose down, which lets slow-pitching craft overshoot small ceilings a long way.
const HARD_CEILING_FACTOR := 1.25
## Bank / pitch limits (the original has none; a keyboard pilot could roll inverted).
const MAX_BANK := deg_to_rad(75.0)
const MAX_PITCH := deg_to_rad(60.0)
## Ground: braking (fraction of the maximum speed per second) and nose-wheel turn rate (rad/s).
const GROUND_BRAKE := 0.3
## Landing flare: below this height, with the stick centred, a steeper nose-down attitude eases to
## the glide angle at this fraction per frame (the original never lands; ES2 pitch does not
## self-level).
const FLARE_HEIGHT := 25.0
const FLARE_LEVEL := 0.25
const GLIDE_PITCH := deg_to_rad(-6.0)
const GROUND_TURN_RATE := 0.8
## Autopilot (FlightPilot): the stick per rad of attitude error, and the share of the turn demand that goes to the
## rudder (the rest of the turn is the bank's).
const AUTO_STICK_PER_RAD := 4.0
const AUTO_RUDDER_SHARE := 0.5

var pitch_rate := 0.0   # rad per frame
var roll_rate := 0.0
var yaw_rate := 0.0     # + = nose right


func _clear_rates() -> void:
	pitch_rate = 0.0
	roll_rate = 0.0
	yaw_rate = 0.0


func _frames(delta: float) -> float:
	return delta * float(params.frames_per_second)


# ------------------------------------------------------------------ air

func _step_air(c: FlightControls, agl: float, delta: float) -> void:
	var frames := _frames(delta)
	_apply_speed(c, frames)
	_apply_rates(c, agl, frames)
	bank = clampf(bank + roll_rate * frames, -MAX_BANK, MAX_BANK)
	var max_pitch := float(params.get("max_pitch", MAX_PITCH))
	pitch = clampf(pitch + pitch_rate * frames, -max_pitch, max_pitch)
	heading -= (bank * float(params.turn_per_bank) + yaw_rate) * frames
	_apply_air_velocity(frames)
	if agl > make_ceiling() * HARD_CEILING_FACTOR:
		velocity.y = minf(velocity.y, 0.0)


func _apply_speed(c: FlightControls, frames: float) -> void:
	var target := lerpf(params.min_speed, params.max_speed, clampf(c.throttle, 0.0, 1.0))
	target -= pitch * (float(params.climb_speed_loss) if pitch > 0.0 else float(params.dive_speed_gain))
	speed = maxf(0.0, move_toward(speed, target, float(params.speed_accel) * frames))


func _apply_rates(c: FlightControls, agl: float, frames: float) -> void:
	var damping: float = params.rate_damping
	var nose_input := clampf(c.pitch + c.lift, -1.0, 1.0)
	var pitch_demand: float = nose_input * params.pitch_rate if nose_input != 0.0 else -pitch * float(params.pitch_level)
	if nose_input == 0.0 and pitch < GLIDE_PITCH and agl < FLARE_HEIGHT:
		pitch_demand = (GLIDE_PITCH - pitch) * FLARE_LEVEL
	var excess := agl - make_ceiling()
	if excess > 0.0:
		pitch_demand = minf(pitch_demand, -excess * float(params.ceiling_push))
	pitch_rate = make_rate(pitch_rate, pitch_demand, Vector3(params.pitch_accel, damping, params.pitch_rate), frames)
	var roll_demand: float = c.roll * params.roll_rate if c.roll != 0.0 else -bank * float(params.roll_level)
	roll_rate = make_rate(roll_rate, roll_demand, Vector3(params.roll_accel, damping, params.roll_rate), frames)
	yaw_rate = make_rate(yaw_rate, c.yaw * params.yaw_rate, Vector3(params.roll_accel, damping, params.yaw_rate), frames)


## Velocity along the nose plus the decaying sideslip / vertical drift.
func _apply_air_velocity(frames: float) -> void:
	var nose := make_nose_basis() * Vector3.FORWARD
	var drift := velocity - nose * velocity.dot(nose)
	velocity = nose * speed + drift * pow(float(params.slip_keep), frames)


## Original: ceiling = min ceiling + (speed - min speed) x slope (FM +0x0e, computed at load).
func make_ceiling() -> float:
	return float(params.ceiling_min) + (speed - float(params.min_speed)) * float(params.ceiling_slope)


# ------------------------------------------------------------------ ground

## Taxiing: throttle drives the wheels, turn / rudder steer, and above the minimum flying speed
## nose-up input rotates the craft into the air.
func _step_landed(c: FlightControls, delta: float) -> void:
	var target := clampf(c.throttle, 0.0, 1.0) * float(params.max_speed)
	var rate := float(params.speed_accel) * _frames(delta) if target > speed else GROUND_BRAKE * float(params.max_speed) * delta
	speed = move_toward(speed, target, rate)
	heading -= clampf(c.roll + c.yaw, -1.0, 1.0) * GROUND_TURN_RATE * delta
	var nose_input := clampf(c.pitch + c.lift, -1.0, 1.0)
	if nose_input > 0.0 and speed >= float(params.min_speed):
		landed = false
		pitch_rate = nose_input * float(params.pitch_rate)
		pitch = pitch_rate * _frames(delta)
	velocity = make_nose_basis() * Vector3.FORWARD * speed


# ------------------------------------------------------------------ autopilot

func make_idle_speed() -> float:
	return float(params.min_speed)


func make_flying_speed() -> float:
	return float(params.min_speed)


func make_climb_scale() -> float:
	return maxf(speed, float(params.min_speed))


## The flight path turns with the nose: pitch rate (rad/s) times speed.
func make_climb_accel() -> float:
	return float(params.pitch_rate) * float(params.frames_per_second) * maxf(speed, float(params.min_speed))


## Rolls to the wanted bank (the turn follows the bank), pitches to the wanted nose, rudder coordinated with the turn.
func make_controls(c: FlightCommand) -> FlightControls:
	var roll := clampf((c.bank - bank) * AUTO_STICK_PER_RAD, -1.0, 1.0)
	var nose := clampf((c.pitch - pitch) * AUTO_STICK_PER_RAD, -1.0, 1.0)
	return FlightControls.make(c.throttle, roll, Vector2(c.turn * AUTO_RUDDER_SHARE, nose), 0.0)

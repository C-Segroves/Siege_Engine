class_name FlightModel
extends RefCounted
## Shared flight physics of every flying vehicle; the player and the AI fly the same model.
##
## Two styles (docs/formats/flight_model.md):
##   JetFlightModel    Earthsiege 2 flight model (FM files, DBSIM.EXE 0x466a54): banked turns, a
##                     minimum flying speed, a speed-dependent ceiling above the ground.
##   HoverFlightModel  Tribes FlierData (scripts/vehicle.cs): VTOL lift, hover, hard max altitude.
## The model owns speed and attitude and produces a world velocity; the vehicle moves its body by
## `velocity` and reads the attitude for its visuals and aim. It never touches nodes.

## Height above the ground (m) that counts as touching it.
const GROUND_CONTACT := 0.6
## Touchdowns sinking faster than this are hard landings (m/s). Approximation: the originals
## have no landing model (ES2 flyers never land, Tribes vehicles take ram damage).
const SAFE_SINK_RATE := 12.0

var params: Dictionary
var speed := 0.0               # m/s along the nose (negative = reverse, hover craft only)
var heading := 0.0             # rad, Godot yaw (rotation.y; + = turned left)
var pitch := 0.0               # rad, + = nose up
var bank := 0.0                # rad, + = right wing down
var velocity := Vector3.ZERO   # m/s, world
var landed := false
## Sink rate of the last hard landing (m/s), 0 when none; the vehicle reads and clears it.
var hard_landing := 0.0


## The model for a parameter set from FlightPresets.make_params().
static func create(p: Dictionary) -> FlightModel:
	if String(p.get("style", "")) == FlightPresets.STYLE_HOVER:
		return HoverFlightModel.new(p)
	return JetFlightModel.new(p)


func _init(p: Dictionary) -> void:
	params = p


## Advances one physics step. `agl` = height of the vehicle above the ground (m).
func step(c: FlightControls, agl: float, delta: float) -> void:
	if landed:
		_step_landed(c, delta)
	else:
		_step_air(c, agl, delta)
	_apply_ground_contact(agl)


## Puts the craft on the ground at rest.
func apply_landed_state() -> void:
	landed = true
	speed = 0.0
	pitch = 0.0
	bank = 0.0
	velocity = Vector3.ZERO
	_clear_rates()


## Puts the craft in level flight at `p_speed` (m/s).
func apply_flying_state(p_speed: float) -> void:
	landed = false
	speed = p_speed
	pitch = 0.0
	bank = 0.0
	velocity = make_nose_basis() * Vector3.FORWARD * p_speed
	_clear_rates()


# ------------------------------------------------------------------ queries

## Heading only (the vehicle body: networking and collision stay upright).
func make_body_basis() -> Basis:
	return Basis(Vector3.UP, heading)


## Heading and pitch: where the nose and the guns point.
func make_nose_basis() -> Basis:
	return make_body_basis() * Basis(Vector3.RIGHT, pitch)


## Pitch and bank relative to the body (the visual model's rotation).
static func make_attitude(p_pitch: float, p_bank: float) -> Basis:
	return Basis(Vector3.RIGHT, p_pitch) * Basis(Vector3.BACK, -p_bank)


## Altitude above the ground the craft may climb to (m) at its current speed.
func make_ceiling() -> float:
	return INF


## Stick inputs that steer towards a goal (the AI autopilot): `heading_error` rad (+ = goal to
## the left), `climb_error` m (+ = goal above), `throttle` 0..1.
func make_steering(_heading_error: float, _climb_error: float, throttle: float) -> FlightControls:
	return FlightControls.make(throttle, 0.0, Vector2.ZERO, 0.0)


# ------------------------------------------------------------------ subclass hooks

func _step_air(_c: FlightControls, _agl: float, _delta: float) -> void:
	pass


func _step_landed(_c: FlightControls, _delta: float) -> void:
	pass


func _clear_rates() -> void:
	pass


# ------------------------------------------------------------------ ground

func _apply_ground_contact(agl: float) -> void:
	if landed:
		velocity.y = 0.0
		return
	if agl > GROUND_CONTACT or velocity.y > 0.0:
		return
	var sink := -velocity.y
	hard_landing = sink if sink > SAFE_SINK_RATE else 0.0
	landed = true
	velocity.y = 0.0
	pitch = 0.0
	bank = 0.0
	_clear_rates()


## Original angular-rate law (DBSIM 0x466d5a..0x467381): each frame the rate gains the demand
## (clamped to the acceleration limit) and loses `damping` of itself, then is clamped to `limit`.
static func make_rate(rate: float, demand: float, limits: Vector3, frames: float) -> float:
	var accel := limits.x
	var damping := limits.y
	var limit := limits.z
	return clampf(rate + (clampf(demand, -accel, accel) - rate * damping) * frames, -limit, limit)

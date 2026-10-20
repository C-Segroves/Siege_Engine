class_name TransportFlight
extends FlyerAI
## The autopilot of an AI transport (docs/design/extraction.md section 2): Tribes HPC / LPC, Tribes 2 Havoc or a
## Starsiege dropship flies in at cruise height to its landing point, sets down, holds on the ground until the
## ExtractionDirector releases it (riders out at a drop-in, riders aboard at an exfil), then climbs away to its exit
## point and reports DONE. It flies through the shared FlightPilot (engine/flight: terrain look-ahead, banked turns, a descent
## down to the ground contact), the same physics the player flies; it never fires.

enum Phase { INBOUND, DESCEND, HOLD, DEPART, DONE, HOVER_DROP }

## Begins the descent within this horizontal distance of the landing point (m).
const DESCENT_RADIUS := 25.0
## Creeps towards the landing point at up to this throttle while it sinks.
const DESCENT_CREEP := 0.25
## Sink rate of a landing (m/s) for a craft with no lift of its own.
const MIN_SINK_RATE := 3.0
const CREEP_DISTANCE := 40.0
## Gives up waiting for the ground contact after this long (s) and holds where it is.
const DESCENT_TIMEOUT := 25.0
## The exit point counts as reached this close (m).
const EXIT_REACH := 60.0
## A delivery (hover_height > 0, call-ins: docs/design/lobby_loadout_economy.md section 9.5) stops over the landing point at
## this height above the ground and is "hovering" once it has held that spot for HOVER_SETTLE seconds (s) within
## HOVER_REACH (m) horizontally and HOVER_ALTITUDE_BAND (m) vertically; it gives up waiting after HOVER_TIMEOUT (s).
const HOVER_REACH := 8.0
## A delivery creeps to its spot at HOVER_SPEED_PER_M metres per second per metre of distance (at most HOVER_MAX_SPEED),
## and only once its nose is within HOVER_TURN_FIRST radians of the spot (else it turns first).
const HOVER_SPEED_PER_M := 0.4
const HOVER_MAX_SPEED := 10.0
const HOVER_TURN_FIRST := 1.0
## A delivery slows for its spot so it can stop there: its speed is at most sqrt(2 * APPROACH_BRAKE * distance) (m/s^2, a
## cautious share of what a hover transport can shed).
const APPROACH_BRAKE := 4.0
const HOVER_ALTITUDE_BAND := 2.0
const HOVER_SETTLE := 1.5
const HOVER_TIMEOUT := 25.0

var phase := Phase.INBOUND
var landing := Vector3.ZERO
var exit_point := Vector3.ZERO
var cruise_height := 45.0
## Height above the ground a delivery holds (m); 0 = a landing transport (drop-in, exfil).
var hover_height := 0.0
var _phase_t := 0.0
var _hover_settled := 0.0


static func make(p_flyer: Flyer, p_landing: Vector3, p_exit: Vector3, height: float) -> TransportFlight:
	var t := TransportFlight.new(p_flyer)
	t.landing = p_landing
	t.exit_point = p_exit
	t.cruise_height = height
	return t


func is_holding() -> bool:
	return phase == Phase.HOLD


func is_done() -> bool:
	return phase == Phase.DONE


## True once a delivery has held its hover spot (or waited long enough): the load may be released.
func is_hovering() -> bool:
	if phase != Phase.HOVER_DROP:
		return false
	return _hover_settled >= HOVER_SETTLE or (_phase_t >= HOVER_TIMEOUT and _flat_to(landing).length() < DESCENT_RADIUS)


## Leaves the ground for the exit point.
func depart() -> void:
	if phase in [Phase.INBOUND, Phase.DESCEND, Phase.HOLD, Phase.HOVER_DROP]:
		_enter(Phase.DEPART)


func update(delta: float) -> void:
	_phase_t += delta
	flyer.target = null
	for w in flyer.weapons:
		w.trigger = false
	match phase:
		Phase.INBOUND:
			_fly_inbound(delta)
		Phase.DESCEND:
			_descend(delta)
		Phase.HOVER_DROP:
			_hover_over_landing(delta)
		Phase.HOLD:
			flyer.apply_controls(FlightControls.make(0.0, 0.0, Vector2.ZERO, 0.0))
		Phase.DEPART:
			_fly_out(delta)
		Phase.DONE:
			flyer.apply_controls(FlightControls.make(0.0, 0.0, Vector2.ZERO, 0.0))


func _enter(p: Phase) -> void:
	phase = p
	_phase_t = 0.0
	_hover_settled = 0.0


func _fly_inbound(delta: float) -> void:
	var flat := _flat_to(landing)
	var speed := flyer.cruise if hover_height <= 0.0 else minf(flyer.cruise, sqrt(2.0 * APPROACH_BRAKE * flat.length()))
	flyer.apply_flight(FlightGoal.make_point(landing, cruise_height), speed, delta)
	if flat.length() < DESCENT_RADIUS:
		_enter(Phase.HOVER_DROP if hover_height > 0.0 else Phase.DESCEND)


## Sinks over the landing point (the pilot flies it down to the ground contact), creeping towards it.
func _descend(delta: float) -> void:
	var throttle := clampf(_flat_to(landing).length() / CREEP_DISTANCE, 0.0, DESCENT_CREEP)
	var goal := FlightGoal.make_descent(landing, maxf(flyer.flight.make_vertical_rate(), MIN_SINK_RATE))
	flyer.apply_flight(goal, throttle * flyer.max_speed, delta)
	if flyer.flight.landed or _phase_t > DESCENT_TIMEOUT:
		_enter(Phase.HOLD)


## A delivery holds its spot over the landing point at hover_height.
func _hover_over_landing(delta: float) -> void:
	var flat := _flat_to(landing)
	var turn_first := absf(flyer.pilot.make_heading_error(flyer.global_position, landing)) >= HOVER_TURN_FIRST
	var goal_speed := 0.0 if turn_first else clampf(flat.length() * HOVER_SPEED_PER_M, 0.0, HOVER_MAX_SPEED)
	var goal := FlightGoal.make_hover(landing, hover_height)
	flyer.apply_flight(goal, goal_speed, delta)
	var climb := hover_height - flyer.make_altitude()
	var settled := flat.length() < HOVER_REACH and absf(climb) < HOVER_ALTITUDE_BAND
	_hover_settled = _hover_settled + delta if settled else 0.0


func _fly_out(delta: float) -> void:
	var goal := FlightGoal.make_point(exit_point, cruise_height)
	goal.crosses_edge = true
	flyer.apply_flight(goal, flyer.flight.params.max_speed, delta)
	if _flat_to(exit_point).length() < EXIT_REACH:
		_enter(Phase.DONE)


func _flat_to(goal: Vector3) -> Vector3:
	var to := goal - flyer.global_position
	return Vector3(to.x, 0.0, to.z)

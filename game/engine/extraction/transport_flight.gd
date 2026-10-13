class_name TransportFlight
extends FlyerAI
## The autopilot of an AI transport (docs/design/extraction.md section 2): Tribes HPC / LPC, Tribes 2 Havoc or a
## Starsiege dropship flies in at cruise height to its landing point, sets down, holds on the ground until the
## ExtractionDirector releases it (riders out at a drop-in, riders aboard at an exfil), then climbs away to its exit
## point and reports DONE. It steers through the flyer's own FlightModel autopilot (make_steering), the same physics
## the player flies; it never fires.

enum Phase { INBOUND, DESCEND, HOLD, DEPART, DONE }

## Begins the descent within this horizontal distance of the landing point (m).
const DESCENT_RADIUS := 25.0
## Creeps towards the landing point at up to this throttle while it sinks.
const DESCENT_CREEP := 0.25
const CREEP_DISTANCE := 40.0
## Climb error asked for while sinking: below the ground, so the cushion does not hold it up (m).
const SINK_BELOW := 6.0
## Gives up waiting for the ground contact after this long (s) and holds where it is.
const DESCENT_TIMEOUT := 25.0
## The exit point counts as reached this close (m).
const EXIT_REACH := 60.0

var phase := Phase.INBOUND
var landing := Vector3.ZERO
var exit_point := Vector3.ZERO
var cruise_height := 45.0
var _phase_t := 0.0


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


## Leaves the ground for the exit point.
func depart() -> void:
	if phase in [Phase.INBOUND, Phase.DESCEND, Phase.HOLD]:
		_enter(Phase.DEPART)


func update(delta: float) -> void:
	_phase_t += delta
	flyer.target = null
	for w in flyer.weapons:
		w.trigger = false
	match phase:
		Phase.INBOUND:
			_fly_inbound()
		Phase.DESCEND:
			_descend()
		Phase.HOLD:
			flyer.apply_controls(FlightControls.make(0.0, 0.0, Vector2.ZERO, 0.0))
		Phase.DEPART:
			_fly_out()
		Phase.DONE:
			flyer.apply_controls(FlightControls.make(0.0, 0.0, Vector2.ZERO, 0.0))


func _enter(p: Phase) -> void:
	phase = p
	_phase_t = 0.0


func _fly_inbound() -> void:
	var flat := _flat_to(landing)
	_steer_to(landing, flyer.make_throttle_for(flyer.cruise))
	if flat.length() < DESCENT_RADIUS:
		_enter(Phase.DESCEND)


func _descend() -> void:
	var flat := _flat_to(landing)
	var throttle := clampf(flat.length() / CREEP_DISTANCE, 0.0, DESCENT_CREEP)
	var err := _make_heading_error(flat) if flat.length() > 2.0 else 0.0
	flyer.apply_controls(flyer.flight.make_steering(err, -(flyer.make_altitude() + SINK_BELOW), throttle))
	if flyer.flight.landed or _phase_t > DESCENT_TIMEOUT:
		_enter(Phase.HOLD)


func _fly_out() -> void:
	_steer_to(exit_point, 1.0)
	if _flat_to(exit_point).length() < EXIT_REACH:
		_enter(Phase.DONE)


## Heads for `goal` at cruise height above the ground with `throttle`.
func _steer_to(goal: Vector3, throttle: float) -> void:
	var climb := cruise_height - flyer.make_altitude()
	flyer.apply_controls(flyer.flight.make_steering(_make_heading_error(_flat_to(goal)), climb, throttle))


func _flat_to(goal: Vector3) -> Vector3:
	var to := goal - flyer.global_position
	return Vector3(to.x, 0.0, to.z)

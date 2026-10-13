class_name FlightControls
extends RefCounted
## One frame of pilot input for a FlightModel (player stick or AI autopilot), all -1..1:
##   throttle  0 = idle .. 1 = full (negative = reverse, hover craft only)
##   roll      + = bank right (turn keys / left stick)
##   yaw       + = nose right (mouse / right stick X; rudder)
##   pitch     + = nose up (mouse / right stick Y)
##   lift      + = ascend, - = descend (ascend / descend actions)
## Each model maps them onto its own controls (docs/formats/flight_model.md §3).

var throttle := 0.0
var roll := 0.0
var yaw := 0.0
var pitch := 0.0
var lift := 0.0


static func make(p_throttle: float, p_roll: float, stick: Vector2, p_lift: float) -> FlightControls:
	var c := FlightControls.new()
	c.throttle = clampf(p_throttle, -1.0, 1.0)
	c.roll = clampf(p_roll, -1.0, 1.0)
	c.yaw = clampf(stick.x, -1.0, 1.0)
	c.pitch = clampf(stick.y, -1.0, 1.0)
	c.lift = clampf(p_lift, -1.0, 1.0)
	return c

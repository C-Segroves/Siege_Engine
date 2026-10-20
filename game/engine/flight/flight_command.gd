class_name FlightCommand
extends RefCounted
## What a FlightPilot asks of a craft for one frame, in attitude terms; FlightModel.make_controls maps it
## onto that model's own sticks, so the same pilot flies a jet (banked turns) and a hover craft (VTOL).

## Wanted bank (rad, + = right wing down) and nose pitch (rad, + = up).
var bank := 0.0
var pitch := 0.0
## Turn demand -1..1 (+ = turn right): the rudder of a jet, the turn stick of a hover craft.
var turn := 0.0
## Wanted vertical speed (m/s, + = up).
var climb := 0.0
## Throttle 0..1.
var throttle := 0.0

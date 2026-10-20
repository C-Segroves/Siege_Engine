class_name CallinAirFlight
extends RefCounted
## One air call-in on its way (host): the request it answers, the line it flies and the aircraft that flies it. A runner keeps
## these by order id; they outlive the order while the aircraft is still leaving the map.

var order_id := 0
var request: CallinRequest
## The flat unit direction of the run, the designated point on the ground, where the aircraft appears and where it leaves.
var direction := Vector3.FORWARD
var point := Vector3.ZERO
var entry := Vector3.ZERO
var exit := Vector3.ZERO
var airframe_id := ""
## The aircraft's net id (-1 before it appears) and its autopilot.
var craft_id := -1
var pilot: FlyerAI = null
## peer -> how many danger warnings he got.
var warned := {}
## True once the order is over and only the aircraft's flight out remains; seconds left before it is taken out anyway.
var is_leaving := false
var leaving_left := 0.0

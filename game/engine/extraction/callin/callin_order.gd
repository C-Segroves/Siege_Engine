class_name CallinOrder
extends RefCounted
## One call-in on its way (host-owned; docs/design/lobby_loadout_economy.md section 9.5). The state machine
##   REQUESTED -> MARKED -> INBOUND -> DELIVERING -> ACTIVE -> EXPIRING -> DONE        (any state -> CANCELLED)
## is driven by CallinDirector; this record holds the facts and the timers, and its dictionary form is what the peers
## are told (`make_view`): the full form to the caller and his squad, the marker-only form (no owner) to peers nearby.

enum State { REQUESTED, MARKED, INBOUND, DELIVERING, ACTIVE, EXPIRING, DONE, CANCELLED }

const STATE_NAMES := ["requested", "marked", "inbound", "delivering", "active", "expiring", "done", "cancelled"]

var id := 0
var kind := ""
## The armour size of an armour drop ("" otherwise).
var variant := ""
var peer := 0
var team := 0
var cost := 0
## The landing zone: the floor point and the footprint radius.
var lz := Vector3.ZERO
var radius := 3.0
## The line a directional call-in flies (flat, normalised; the designated one, else the way the caller faced) and how the
## point was asked for ("laser" or "map", CallinRequest).
var direction := Vector3.FORWARD
var source := CallinRequest.SOURCE_LASER
var state := State.REQUESTED
## Seconds in the current state, and the seconds the order has lived.
var state_time := 0.0
var age := 0.0
## Seconds the current wait still lasts (the countdown the HUD shows); -1 when it has none.
var eta := -1.0
## Vehicle delivery: the vehicle's id ("es1:RAPTOR"), the transport (-1: a pod brings it) and the net ids it made.
var vehicle_id := ""
var transport_id := -1
var cargo_net_id := -1
## Pods: seconds the pod falls, and what it made (a crate id or a station name).
var fall_s := 0.0
var object_id := -1
## ACTIVE: seconds the object still lasts and the uses it still has.
var ttl_left := 0.0
var uses_left := 0
## Seconds of the marker countdown (MARKED), and of the transport's preparation.
var marker_s := 0.0
var revalidated := false
var flight_s := 0.0
## Vehicle delivery: the transport that flies it in ("" = a pod brings it) and how far out that transport starts.
var transport_vehicle := ""
var approach_m := 0.0
var cancel_reason := ""


func is_open() -> bool:
	return state != State.DONE and state != State.CANCELLED


## True while it is on its way (the "active orders" limit counts these).
func is_in_flight() -> bool:
	return state in [State.REQUESTED, State.MARKED, State.INBOUND, State.DELIVERING]


func apply_state(new_state: State) -> void:
	state = new_state
	state_time = 0.0


func apply_tick(delta: float) -> void:
	age += delta
	state_time += delta
	if eta > 0.0:
		eta = maxf(eta - delta, 0.0)


func get_state_name() -> String:
	return STATE_NAMES[state]


## The HUD line of an order, from its full view: "VEHICLE DELIVERY INBOUND 0:37".
static func make_hud_line(view: Dictionary) -> String:
	var state: int = int(view.get("state", 0))
	var phase := ""
	match state:
		State.REQUESTED, State.MARKED:
			phase = "MARKED"
		State.INBOUND:
			phase = "INBOUND"
		State.DELIVERING:
			phase = "ARRIVING"
		State.ACTIVE:
			phase = "ACTIVE"
		State.EXPIRING:
			phase = "EXPIRING"
	var seconds := -1.0
	if state in [State.REQUESTED, State.MARKED, State.INBOUND]:
		seconds = float(view.get("eta", -1.0))
	elif state in [State.ACTIVE, State.EXPIRING]:
		seconds = float(view.get("ttl", -1.0))
	var clock := " %d:%02d" % [int(seconds) / 60, int(seconds) % 60] if seconds >= 0.0 else ""
	return "%s %s%s" % [CallinRules.make_label(str(view.get("kind", ""))).to_upper(), phase, clock]


## The form the peers receive. `full` adds the owner and the countdown (the caller and his squad); the marker-only
## form is what a bystander within sight needs to draw the flare, the ring and the falling pod.
func make_view(full: bool) -> Dictionary:
	var v := {"id": id, "kind": kind, "state": int(state), "lz": lz, "radius": radius, "fall_s": fall_s,
		"fall_left": maxf(fall_s - state_time, 0.0) if state == State.INBOUND else fall_s}
	if full:
		v["peer"] = peer
		v["eta"] = eta
		v["ttl"] = ttl_left
		v["variant"] = variant
	return v

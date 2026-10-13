class_name VehicleOccupancy
extends Node
## Who sits in a vehicle (every Herc, tank and flyer of every pack): one entry per seat, seat 0 = the pilot.
## An entry is the peer id of the player in that seat, a bot id (InfantryBots, below AI_PILOT), AI_PILOT for
## the vehicle's own AI, or EMPTY.
## The component is the child node "Occupancy" of the vehicle, made on first use (VehicleOccupancy.of).
## The host decides every change (OccupancyDirector) and sends it to all peers; an empty vehicle has no
## brain: it stands where it was parked until a soldier boards it.

const NODE_NAME := "Occupancy"
const EMPTY := 0
const AI_PILOT := -1
const PILOT_SEAT := 0

## Peer id per seat (EMPTY / AI_PILOT / peer).
var seats: Array[int] = []


## The occupancy of `vehicle` (created with BoardingRules.make_seat_count seats when missing).
static func of(vehicle: Node) -> VehicleOccupancy:
	var o := vehicle.get_node_or_null(NODE_NAME) as VehicleOccupancy
	if o == null:
		o = VehicleOccupancy.new()
		o.name = NODE_NAME
		var def: Dictionary = vehicle.get("def") if vehicle.get("def") is Dictionary else {}
		o.seats.resize(BoardingRules.make_seat_count(def))
		o.seats.fill(EMPTY)
		vehicle.add_child(o)
	return o


func pilot() -> int:
	return seats[PILOT_SEAT] if not seats.is_empty() else EMPTY


func has_pilot() -> bool:
	return pilot() != EMPTY


func is_empty() -> bool:
	return seats.all(func(s: int) -> bool: return s == EMPTY)


func is_ai_piloted() -> bool:
	return pilot() == AI_PILOT


## The seat `peer` sits in, -1 when it is not aboard.
func seat_of(peer: int) -> int:
	return seats.find(peer) if peer != EMPTY else -1


## Players aboard (peer ids, pilot first).
func make_riders() -> Array[int]:
	var out: Array[int] = []
	for s in seats:
		if s > EMPTY:
			out.append(s)
	return out


func is_seat_free(seat: int) -> bool:
	return seat >= 0 and seat < seats.size() and seats[seat] == EMPTY


func apply_seat(seat: int, occupant: int) -> void:
	if seat < 0 or seat >= seats.size():
		push_error("VehicleOccupancy: seat %d of %d" % [seat, seats.size()])
		return
	seats[seat] = occupant


## Frees every seat `peer` holds.
func apply_leave(peer: int) -> void:
	for i in seats.size():
		if seats[i] == peer:
			seats[i] = EMPTY


## Replaces all seats (a state message from the host).
func apply_seats(new_seats: Array) -> void:
	for i in mini(seats.size(), new_seats.size()):
		seats[i] = int(new_seats[i])


## Everyone aboard but the vehicle's own AI: players and bots (ids), pilot first.
func make_occupants() -> Array[int]:
	var out: Array[int] = []
	for s in seats:
		if s != EMPTY and s != AI_PILOT:
			out.append(s)
	return out

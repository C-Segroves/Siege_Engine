class_name VehicleSeats
extends RefCounted
## What each seat of a vehicle does (gamedata vehicle_seats.json, InfantryGear; tribes_vehicles.md section 6):
##   pilot      seat 0: drives / flies; fires the vehicle's weapons unless the vehicle has a gunner seat
##              with someone in it;
##   gunner     works the turret weapons (Thundersword bombardier, Beowulf turreteer: TurretCrew);
##   armed      a passenger who fires his own hand weapons within the seat's view arc (T1 LPC / HPC
##              passengers keep their weapon, Vehicle::onCollision; T2 seats without a mountPose: Havoc
##              passengers, Thundersword tail gunner);
##   passenger  rides (T2 sitting seats).
## Vehicles without seat data (every non-Tribes vehicle) have one seat: the pilot's.

const PILOT := "pilot"
const GUNNER := "gunner"
const ARMED := "armed"
const PASSENGER := "passenger"


static func make_role(vehicle_id: String, seat: int) -> String:
	var seats := InfantryGear.seats_of(vehicle_id)
	if seat >= 0 and seat < seats.size():
		return str(seats[seat].get("role", PASSENGER))
	return PILOT if seat == VehicleOccupancy.PILOT_SEAT else PASSENGER


## The gunner seat of `vehicle_id`, -1 when it has none.
static func make_gunner_seat(vehicle_id: String) -> int:
	var seats := InfantryGear.seats_of(vehicle_id)
	for i in seats.size():
		if str(seats[i].get("role", "")) == GUNNER:
			return i
	return -1


## The name of the seat's node in the vehicle shape ("" when unknown).
static func make_node_name(vehicle_id: String, seat: int) -> String:
	var seats := InfantryGear.seats_of(vehicle_id)
	return str(seats[seat].get("node", "")) if seat >= 0 and seat < seats.size() else ""


## The gunner's pitch range (radians: x = lowest, y = highest) from the turret's thetaMin / thetaMax; the
## vehicle's own pitch limits when the seat data has none.
static func make_gunner_pitch_range(vehicle: Herc) -> Vector2:
	var seat := make_gunner_seat(vehicle.vehicle_id)
	var seats := InfantryGear.seats_of(vehicle.vehicle_id)
	if seat < 0 or not seats[seat].has("pitch_min_deg"):
		return Vector2(vehicle.pitch_min, vehicle.pitch_max)
	return Vector2(deg_to_rad(float(seats[seat].pitch_min_deg)), deg_to_rad(float(seats[seat].pitch_max_deg)))

class_name BoardingRules
extends RefCounted
## Who may board which vehicle and where (docs/formats/tribes_vehicles.md section 6).
##
## HATCH (every non-Tribes vehicle: Earthsiege, Battledrome, Earthsiege 2 and Starsiege Hercs, tanks and
## flyers): one seat. A soldier in LIGHT armour boards an EMPTY vehicle with the vehicle_enter_exit action
## when he stands within HATCH_REACH of its hull at foot level. Remake rule (the originals have no infantry).
## TRIBES (Tribes 1, scripts/vehicle.cs Vehicle::onCollision): boarding by touching the hull. Light armour
## takes the pilot seat when it is free; anyone else (or a light armour when the pilot seat is taken) takes a
## passenger seat (Vehicle::findEmptySeat: LPC 2, HPC 4, Scout none) - a Scout with no pilot answers
## "You must be in Light Armor to pilot the vehicles." No team test: an enemy vehicle may be taken.
## TRIBES2 (Tribes 2, scripts/player.cs Armor::onCollision + vehicles/vehicle.cs findEmptySeat): boarding by
## touching. Light and medium armour may take any seat; a lightOnly vehicle (Wildcat) takes only light armour
## as pilot; heavy armour only seats without a mountPose ("sitting"): never a pilot. noEnemyControl (the
## Jericho) refuses the other team. Of the allowed free seats the remake takes the lowest (the original takes
## the seat node nearest the soldier, which needs the seat node positions).
## Every family: the vehicle must be alive and the soldier alive and on foot.
## Moving to another seat (seat_next, a remake addition: neither game's scripts have a seat change) follows the
## same seat rules (is_seat_allowed).

enum Family { HATCH, TRIBES, TRIBES2 }

## Reach of the hatch: metres from the hull (the vehicle's collision capsule) to the soldier, at foot level.
const HATCH_REACH := 3.0
## Height band of the hatch reach: from this far below the vehicle's base ...
const HATCH_BELOW := 1.0
## ... to the top of the hull, at least this high (a low tank).
const HATCH_MIN_HEIGHT := 3.0
## A soldier "touches" a Tribes vehicle within this margin of its hull footprint (move_and_slide keeps him
## just outside the collision shape).
const TOUCH_MARGIN := 0.75

const REASON_LIGHT_ARMOR := "Light armor required"
const REASON_T1_LIGHT_ARMOR := "You must be in Light Armor to pilot the vehicles."
const REASON_T2_LIGHT_ONLY := "Only Scout Armors can pilot this vehicle."
const REASON_T2_POSITION := "Only Scout or Assault Armors can use that position."
const REASON_OCCUPIED := "Vehicle occupied"
const REASON_FULL := "No free seat"
const REASON_ENEMY := "Enemy vehicle: no access"
const REASON_DESTROYED := "Vehicle destroyed"
const REASON_OUT_OF_REACH := "Out of reach"


static func family(vdef: Dictionary) -> Family:
	match str(vdef.get("crew", {}).get("rules", "")):
		"tribes":
			return Family.TRIBES
		"tribes2":
			return Family.TRIBES2
	return Family.HATCH


## Tribes vehicles are boarded by touching them; the others through the hatch with vehicle_enter_exit.
static func is_boarded_by_touch(vdef: Dictionary) -> bool:
	return family(vdef) != Family.HATCH


static func make_seat_count(vdef: Dictionary) -> int:
	return maxi(1, int(vdef.get("crew", {}).get("seats", 1))) if family(vdef) != Family.HATCH else 1


## {ok, seat, reason}: may `soldier` board `vehicle` (its occupancy `occ`) now, and in which seat.
static func make_check(soldier: Infantry, vehicle: Herc, occ: VehicleOccupancy) -> Dictionary:
	if not vehicle.alive:
		return refuse(REASON_DESTROYED)
	if not soldier.alive or soldier.stowed:
		return refuse(REASON_OUT_OF_REACH)
	var near := is_within_hatch_reach(soldier, vehicle) if family(vehicle.def) == Family.HATCH else is_touching(soldier, vehicle)
	if not near:
		return refuse(REASON_OUT_OF_REACH)
	return make_seat_choice(soldier, vehicle, occ)


## {ok, seat, reason}: the seat `soldier` would get in `vehicle` were he within reach (bots choose vehicles by it).
static func make_seat_choice(soldier: Infantry, vehicle: Herc, occ: VehicleOccupancy) -> Dictionary:
	if not vehicle.alive:
		return refuse(REASON_DESTROYED)
	match family(vehicle.def):
		Family.TRIBES:
			return _make_tribes_check(soldier, vehicle, occ)
		Family.TRIBES2:
			return _make_tribes2_check(soldier, vehicle, occ)
	return _make_hatch_check(soldier, vehicle, occ)


## True when `soldier`'s armour may sit in `seat` of `vehicle` (the seat rules without reach or occupancy).
static func is_seat_allowed(soldier: Infantry, vehicle: Herc, seat: int) -> bool:
	match family(vehicle.def):
		Family.TRIBES:
			return seat != VehicleOccupancy.PILOT_SEAT or is_light(soldier)
		Family.TRIBES2:
			var crew: Dictionary = vehicle.def.get("crew", {})
			var size := str(soldier.armor.get("size", ""))
			if bool(crew.get("no_enemy_control", false)) and soldier.team != vehicle.team:
				return false
			if seat == VehicleOccupancy.PILOT_SEAT and bool(crew.get("light_only", false)) and size != "light":
				return false
			return not (size == "heavy" and _sitting_seats(crew).has(seat))
	return seat == VehicleOccupancy.PILOT_SEAT and is_light(soldier)


static func _sitting_seats(crew: Dictionary) -> Array:
	return (crew.get("sitting", []) as Array).map(func(seat) -> int: return int(seat))   # JSON numbers are floats


static func refuse(reason: String) -> Dictionary:
	return {"ok": false, "seat": -1, "reason": reason}


static func accept(seat: int) -> Dictionary:
	return {"ok": true, "seat": seat, "reason": ""}


static func is_light(soldier: Infantry) -> bool:
	return str(soldier.armor.get("size", "")) == "light"


static func _make_hatch_check(soldier: Infantry, _vehicle: Herc, occ: VehicleOccupancy) -> Dictionary:
	if not occ.is_empty():
		return refuse(REASON_OCCUPIED)
	if not is_light(soldier):
		return refuse(REASON_LIGHT_ARMOR)
	return accept(VehicleOccupancy.PILOT_SEAT)


static func _make_tribes_check(soldier: Infantry, _vehicle: Herc, occ: VehicleOccupancy) -> Dictionary:
	if is_light(soldier) and occ.is_seat_free(VehicleOccupancy.PILOT_SEAT):
		return accept(VehicleOccupancy.PILOT_SEAT)
	for seat in range(1, occ.seats.size()):
		if occ.is_seat_free(seat):
			return accept(seat)
	if occ.is_seat_free(VehicleOccupancy.PILOT_SEAT):
		return refuse(REASON_T1_LIGHT_ARMOR)
	return refuse(REASON_FULL)


static func _make_tribes2_check(soldier: Infantry, vehicle: Herc, occ: VehicleOccupancy) -> Dictionary:
	var crew: Dictionary = vehicle.def.get("crew", {})
	if bool(crew.get("no_enemy_control", false)) and soldier.team != vehicle.team:
		return refuse(REASON_ENEMY)
	var size := str(soldier.armor.get("size", ""))
	var sitting := _sitting_seats(crew)
	var light_only_refused := false
	for seat in occ.seats.size():
		if not occ.is_seat_free(seat):
			continue
		if seat == VehicleOccupancy.PILOT_SEAT and bool(crew.get("light_only", false)) and size != "light":
			light_only_refused = true
			continue
		if size == "heavy" and sitting.has(seat):
			continue
		return accept(seat)
	if light_only_refused:
		return refuse(REASON_T2_LIGHT_ONLY)
	var any_free := range(occ.seats.size()).any(func(seat: int) -> bool: return occ.is_seat_free(seat))
	return refuse(REASON_T2_POSITION if any_free else REASON_FULL)


## Within HATCH_REACH of the hull, at foot level.
static func is_within_hatch_reach(soldier: Node3D, vehicle: Herc) -> bool:
	var rel := soldier.global_position - vehicle.global_position
	var top := maxf(make_hull_height(vehicle), HATCH_MIN_HEIGHT)
	if rel.y < -HATCH_BELOW or rel.y > top:
		return false
	return Vector2(rel.x, rel.z).length() - make_hull_radius(vehicle) <= HATCH_REACH


## Touching the hull footprint (Tribes vehicles: Vehicle::onCollision / Armor::onCollision).
static func is_touching(soldier: Node3D, vehicle: Herc) -> bool:
	return make_touch_gap(soldier, vehicle) <= 0.0


## Metres `soldier` stands beyond touching `vehicle` (<= 0: touching; INF: above or below the hull's band).
static func make_touch_gap(soldier: Node3D, vehicle: Herc) -> float:
	var rel := soldier.global_position - vehicle.global_position
	var top := maxf(make_hull_height(vehicle), HATCH_MIN_HEIGHT)
	if rel.y < -HATCH_BELOW or rel.y > top:
		return INF
	return Vector2(rel.x, rel.z).length() - make_hull_radius(vehicle) - TOUCH_MARGIN


## Horizontal radius of the hull: the collision capsule, or half the catalog length / width when the
## vehicle is longer than its capsule (flyers, tanks).
static func make_hull_radius(vehicle: Herc) -> float:
	var r := 0.0
	var cap := _capsule_of(vehicle)
	if cap:
		r = cap.radius
	var def := vehicle.def
	return maxf(r, 0.5 * maxf(float(def.get("length_m", 0.0)), float(def.get("width_m", 0.0))))


static func make_hull_height(vehicle: Herc) -> float:
	var cap := _capsule_of(vehicle)
	return cap.height if cap else float(vehicle.def.get("height_m", HATCH_MIN_HEIGHT))


static func _capsule_of(vehicle: Node) -> CapsuleShape3D:
	for c in vehicle.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
			return (c as CollisionShape3D).shape as CapsuleShape3D
	return null

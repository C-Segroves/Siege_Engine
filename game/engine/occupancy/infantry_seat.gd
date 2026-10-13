class_name InfantrySeat
extends RefCounted
## The seat a soldier rides in (VehicleSeats role) and, for an armed passenger, his view arc: centred on the
## outward direction of the seat (side seats look out of their side, seats on the centre line away from the
## pilot), ARC_HALF either way. The arcs are engine-side in both games; the remake's arc is a half-space.
## Where the rider shows (vehicle_seats.json, tools/export_tribes_gear.py): the Tribes games draw him on the
## seat node in the seat's pose (T1 FlierData visibleDriver / driverPose and the passenger animData slot; T2
## Armor::onMount: the mount node, mountPose[node] else "root"); the pilot and gunner put their weapon away.
## Vehicles without seat data (the Herc games) never show a pilot.

## Half the view arc of an armed passenger seat (remake value: the open side of the seat).
const ARC_HALF := deg_to_rad(90.0)
## A seat this far (m) or more off the centre line faces its side.
const SIDE_SEAT_OFFSET := 1.0
## The rider's eye this high (m) above the seat node.

var vehicle: Herc
var seat := -1
var role := VehicleSeats.PASSENGER
var node: Node3D
## Yaw of the arc's centre in the vehicle's frame (radians, 0 = the vehicle's forward).
var facing := 0.0
## The rider is drawn on the seat node.
var shown := false
## Sequence names of the seat's pose, the first the rider's body has wins.
var pose: Array = []
## The rider's weapon shows in his hand.
var weapon_shown := true


static func make(p_vehicle: Herc, p_seat: int) -> InfantrySeat:
	var s := InfantrySeat.new()
	s.vehicle = p_vehicle
	s.seat = p_seat
	s.role = VehicleSeats.make_role(p_vehicle.vehicle_id, p_seat)
	s.node = find_node(p_vehicle, VehicleSeats.make_node_name(p_vehicle.vehicle_id, p_seat))
	s.facing = s._make_facing()
	var data := _seat_data(p_vehicle.vehicle_id, p_seat)
	s.shown = bool(data.get("shown", false)) and is_instance_valid(s.node)
	s.pose = data.get("pose", []) if data.get("pose") is Array else []
	s.weapon_shown = bool(data.get("weapon_shown", true))
	return s


static func _seat_data(vehicle_id: String, p_seat: int) -> Dictionary:
	var seats := InfantryGear.seats_of(vehicle_id)
	return seats[p_seat] if p_seat >= 0 and p_seat < seats.size() and seats[p_seat] is Dictionary else {}


func is_armed() -> bool:
	return role == VehicleSeats.ARMED


## The shape node called `node_name` of `vehicle` (null when missing).
static func find_node(v: Herc, node_name: String) -> Node3D:
	if v.shape == null or node_name == "":
		return null
	var list: Array = v.shape.shape.get("nodes", [])
	for i in mini(list.size(), v.shape.nodes.size()):
		if str(list[i].get("name", "")).to_lower() == node_name.to_lower():
			return v.shape.nodes[i]
	return null


## Where the rider stands or sits (world): on the seat node, turned like it (the originals mount the player at the
## node's transform). An armed passenger stays upright and turns to his look (`yaw`, already inside the arc).
func make_rider_transform(yaw: float) -> Transform3D:
	var at := node.global_transform if is_instance_valid(node) else vehicle.global_transform
	if is_armed():
		return Transform3D(Basis(Vector3.UP, yaw), at.origin)
	return Transform3D(at.basis.orthonormalized(), at.origin)


## World yaw of the arc's centre.
func make_center_yaw() -> float:
	return vehicle.global_rotation.y + facing


## A seated soldier's frame: an armed passenger looks (and fires) within his seat's arc; anyone else holds fire.
static func apply_rider(s: Infantry) -> void:
	var seat := s.seat
	if seat == null or not seat.is_armed() or not is_instance_valid(seat.vehicle):
		for w in s.weapons:
			w.trigger = false
		return
	s.rotation.y = seat.make_clamped_yaw(s.torso_target)
	s.pitch = clampf(s.pitch_target, s.pitch_min, s.pitch_max)
	if s.eye:
		s.eye.rotation.x = s.pitch


## `yaw` (world) brought inside the seat's arc.
func make_clamped_yaw(yaw: float) -> float:
	var centre := make_center_yaw()
	return centre + clampf(wrapf(yaw - centre, -PI, PI), -ARC_HALF, ARC_HALF)


func _make_facing() -> float:
	if not is_instance_valid(node):
		return 0.0
	var inv := vehicle.global_transform.affine_inverse()
	var local := inv * node.global_position
	var dir := Vector3(signf(local.x), 0.0, 0.0)
	if absf(local.x) < SIDE_SEAT_OFFSET:
		var pilot := find_node(vehicle, VehicleSeats.make_node_name(vehicle.vehicle_id, VehicleOccupancy.PILOT_SEAT))
		var from := inv * pilot.global_position if is_instance_valid(pilot) else Vector3.ZERO
		dir = Vector3(0.0, 0.0, signf(local.z - from.z) if local.z != from.z else 1.0)
	return atan2(-dir.x, -dir.z)

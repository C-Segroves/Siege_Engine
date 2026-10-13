class_name TurretCrew
extends Node
## The gunner seat of a vehicle (VehicleSeats.GUNNER: the Thundersword's bombardier, the Beowulf's turreteer;
## BomberFlyer / AssaultVehicle::playerMounted give that seat the turret, tribes_vehicles.md section 2).
## While someone sits there, his aim and triggers work the vehicle's weapons and turret; the pilot keeps
## driving or flying. Nobody there: the pilot fires them (the remake's pilot-fires fallback).
## Host side: it runs before every other physics node (priority), so the gunner's controls win over the pilot's
## whichever way they arrived (local pilot, client input, AI pilot).
## Child "TurretCrew" of the vehicle, made on first use.

const NODE_NAME := "TurretCrew"
const RUN_FIRST := -100

## Who sits in the gunner seat: a peer, a bot id, or VehicleOccupancy.EMPTY.
var gunner := VehicleOccupancy.EMPTY
## The gunner's controls: turret yaw relative to the chassis, pitch, trigger bits (HercSnapshots: one per
## weapon).
var torso_target := 0.0
var pitch_target := 0.0
var trigger_bits := 0


static func of(vehicle: Node) -> TurretCrew:
	var c := vehicle.get_node_or_null(NODE_NAME) as TurretCrew
	if c == null:
		c = TurretCrew.new()
		c.name = NODE_NAME
		c.process_physics_priority = RUN_FIRST
		vehicle.add_child(c)
	return c


## The crew of `vehicle` if it has a gunner seat (null otherwise; nothing is made).
static func find(vehicle: Node) -> TurretCrew:
	return vehicle.get_node_or_null(NODE_NAME) as TurretCrew


func is_manned() -> bool:
	return gunner != VehicleOccupancy.EMPTY


## Gunner input from a control message (BattleNetSync.make_controls of the gunner's machine).
func apply_controls(c: Dictionary) -> void:
	torso_target = float(c.get("torso", 0.0))
	pitch_target = float(c.get("pitch", 0.0))
	trigger_bits = int(c.get("triggers", 0))


## Fire groups 1 / 2 held (a local gunner or a bot) as trigger bits of the vehicle's weapons.
func apply_fire_groups(group_1: bool, group_2: bool) -> void:
	trigger_bits = 0
	var v := get_parent() as Herc
	for i in v.weapons.size():
		if (group_2 if v.weapons[i].group == 1 else group_1):
			trigger_bits |= 1 << i


func apply_idle() -> void:
	trigger_bits = 0


func _physics_process(_delta: float) -> void:
	var v := get_parent() as Herc
	if not is_manned() or v == null or v.is_puppet or not v.alive:
		return
	v.torso_target = torso_target
	v.pitch_target = pitch_target
	HercSnapshots.apply_trigger_bits(v, trigger_bits)


## The gunner's aim in the world: the chassis yaw plus his turret yaw, then his pitch (a flyer's belly turret
## aims this way instead of along the nose).
func make_aim_basis() -> Basis:
	var v := get_parent() as Herc
	return Basis(Vector3.UP, v.global_rotation.y + torso_target) * Basis(Vector3.RIGHT, pitch_target)

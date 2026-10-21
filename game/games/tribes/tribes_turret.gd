class_name TribesTurret
extends TribesBaseObject
## A Tribes base turret (plasma, rocket / missile, mortar, ELF, indoor, AA, sentry ...; docs/TRIBES_BASE_EQUIPMENT.md).
## Its spec "turret" block (tools/export_tribes_base.py, from the game's TurretData and barrel datablocks):
##   weapon       the catalog gun (TribesTurretGun: the projectile datablock it fires)
##   range        Tribes 1 range (else gunRange), Tribes 2 the barrel's attackRadius (metres)
##   refire       Tribes 1 reloadDelay, Tribes 2 the barrel's fire / reload states (seconds; 0 = energy paced)
##   turn_rate    Tribes 1 speed, Tribes 2 degPerSecTheta (rad/s); pitch limits from thetaMin / thetaMax
##   activation   Tribes 2 activationMS / deactivateDelayMS: the barrel deploys before the first shot
##   energy       a shot needs min_energy and spends shot_energy of the energy pool (recharges while powered).
## While working (enabled and powered) it picks the nearest hostile vehicle or soldier (TeamRelations; not
## "dormant", not stowed) in range, in its arc and in sight (castLOS), turns toward it, deploys and fires with
## lead (shells on their ballistic arc). The host simulates; every peer shows the aim and deploy state through
## the shape's own sequences (TribesTurretRig), clients from the host's aim updates.

## Seconds between target searches and aim updates to the clients (Tribes 2 thinkTimeMS is 100 .. 200 ms).
const THINK_SECONDS := 0.2
## A server staggers the first search into this many slots of the period.
const THINK_SLOTS := 8
## A turret whose aim and deploy state did not change repeats its aim update only this often (in thinks): every update
## is a packet to every client, and an idle turret on a 64-player server was most of the turrets' cost.
const AIM_REPEAT_THINKS := 10
## Aim at a soldier's chest and a vehicle's middle, not their feet (metres above the origin).
const SOLDIER_AIM_HEIGHT := 1.0
const VEHICLE_AIM_HEIGHT := 2.0
## Muzzle height as a share of the shape's height (the barrel sits near the top).
const MUZZLE_HEIGHT_SHARE := 0.75
## A shot leaves the muzzle when it points within this angle of the aim (radians).
const AIM_TOLERANCE := 0.15
## Tribes 1 turrets deploy within their "power" sequence; the datablocks carry no activation time.
const T1_ACTIVATION_SECONDS := 0.0

var gun: TribesTurretGun
var engage_range := 0.0
var refire := 0.0
var turn_rate := 1.0
var pitch_min := -PI / 2.0
var pitch_max := PI / 2.0
var activation_seconds := 0.0
var deactivation_seconds := 0.0
var shot_energy := 0.0
var min_energy := 0.0
var target: Node3D
## Aim direction (world), turned toward the target at turn_rate.
var aim_dir := Vector3.FORWARD
## 0 folded .. 1 deployed (the activate sequence's phase).
var deployed := 0.0
## Shots fired so far (tests, diagnostics).
var shots_fired := 0
var rig: TribesTurretRig
var _cooldown := 0.0
var _think_t := 0.0
var _muzzle_height := 1.0
var _wants_deployed := false
var _sent_aim := Vector3.ZERO
var _sent_deployed := false
var _unsent_thinks := AIM_REPEAT_THINKS   # thinks since the last aim update went out (the first one always does)


func apply_spec(p_spec: Dictionary) -> void:
	super.apply_spec(p_spec)
	var t: Dictionary = p_spec.get("turret", {})
	gun = TribesTurretGun.make(str(t.get("weapon", "")))
	if not gun.is_valid():
		push_error("TribesTurret %s: unknown weapon %s" % [datablock, t.get("weapon", "")])
	engage_range = float(t.get("range", 0.0))
	refire = float(t.get("refire", 0.0)) if t.get("refire") != null else 0.0
	turn_rate = maxf(float(t.get("turn_rate", 1.0)), 0.01)
	pitch_min = float(t.get("pitch_min", -PI / 2.0))
	pitch_max = float(t.get("pitch_max", PI / 2.0))
	activation_seconds = float(t.get("activation_s", T1_ACTIVATION_SECONDS))
	deactivation_seconds = float(t.get("deactivate_s", 0.0))
	shot_energy = float(t.get("shot_energy", 0.0))
	min_energy = float(t.get("min_energy", 0.0))
	if is_inside_tree() and shape:
		aim_dir = -global_basis.z.normalized()
		_muzzle_height = make_body_size().y * MUZZLE_HEIGHT_SHARE
		if not ServerProfile.is_collision_only():   # the rig only poses the shape's meshes: nobody sees them on a server
			rig = TribesTurretRig.make(shape, str(t.get("barrel_shape", "")), str(t.get("barrel_mount", "")), palette)


func _ready() -> void:
	if ServerProfile.is_collision_only():   # spread the target searches of a base's turrets over the think period
		_think_t = THINK_SECONDS * float(get_instance_id() % THINK_SLOTS) / float(THINK_SLOTS)


func target_cleared() -> void:
	target = null


func is_armed() -> bool:
	return gun != null and gun.is_valid()


## World position shots leave from: up the turret's own up axis (a ceiling sentry hangs, so it is below).
func make_muzzle() -> Vector3:
	return global_position + global_basis.y.normalized() * _muzzle_height


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if multiplayer.is_server() and is_armed():
		_simulate(delta)
	_apply_deploy(delta)
	if rig and alive:
		var aim := make_local_aim()
		rig.apply(aim.x, aim.y, deployed, delta)


func _simulate(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	if not is_working():
		target = null
		_wants_deployed = false
		return
	_think_t -= delta
	if _think_t <= 0.0:
		_think_t = THINK_SECONDS
		target = find_target()
		_wants_deployed = target != null
		_send_aim()
	if target == null:
		return
	var want := gun.make_fire_direction(make_muzzle(), make_aim_point())
	if want == Vector3.ZERO:
		return
	_apply_turn(want, delta)
	if deployed >= 1.0 and _cooldown <= 0.0 and energy >= min_energy and aim_dir.angle_to(want) <= AIM_TOLERANCE:
		fire(want)


## Deploys toward _wants_deployed over the activation / deactivation time (instant when the data has none).
func _apply_deploy(delta: float) -> void:
	var goal := 1.0 if _wants_deployed and is_working() else 0.0
	var seconds := activation_seconds if goal > deployed else deactivation_seconds
	deployed = goal if seconds <= 0.0 else move_toward(deployed, goal, delta / seconds)


## The aim in the turret's own frame: Vector2(heading from its forward, counter-clockwise; elevation).
func make_local_aim() -> Vector2:
	var local := global_basis.orthonormalized().inverse() * aim_dir
	return Vector2(atan2(-local.x, -local.z), asin(clampf(local.y, -1.0, 1.0)))


func _send_aim() -> void:
	if not Net.is_online():
		return
	_unsent_thinks += 1
	if aim_dir == _sent_aim and _wants_deployed == _sent_deployed and _unsent_thinks < AIM_REPEAT_THINKS:
		return   # the clients already show this aim (a repeat now and then heals a lost packet)
	_unsent_thinks = 0
	_sent_aim = aim_dir
	_sent_deployed = _wants_deployed
	_receive_aim.rpc(aim_dir, _wants_deployed)


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_aim(dir: Vector3, wants_deployed: bool) -> void:
	aim_dir = dir.normalized()
	_wants_deployed = wants_deployed


## The nearest live hostile vehicle or soldier in range, in the turret's arc and in sight; null when none.
func find_target() -> Node3D:
	var muzzle := make_muzzle()
	return TurretTargeting.find_nearest(get_tree(), {"from": muzzle, "range": engage_range,
		"is_hostile": func(v: Node) -> bool: return TeamRelations.is_hostile(team, int(v.team)),
		"aim_point": _aim_height_point, "sensor": spec.get("sensor", {}),
		"accepts": func(v: Node3D, p: Vector3) -> bool: return is_in_arc(p - muzzle) and has_line_of_sight(v)})


## Alive, of a hostile team, not dormant (downed, a transport) and not inside a vehicle.
func is_valid_target(v: Node) -> bool:
	return TurretTargeting.is_targetable(v) and TeamRelations.is_hostile(team, int(v.team)) 		and not CloakRules.is_hidden_from_sensor(v, spec.get("sensor", {}), global_position.distance_to(v.global_position))


## True when world direction `dir` is within the turret's pitch limits (measured from its own base plane).
func is_in_arc(dir: Vector3) -> bool:
	var local := global_basis.orthonormalized().inverse() * dir.normalized()
	var pitch := asin(clampf(local.y, -1.0, 1.0))
	return pitch >= pitch_min and pitch <= pitch_max


## castLOS: nothing solid between the muzzle and the target.
func has_line_of_sight(v: Node3D) -> bool:
	var q := PhysicsRayQueryParameters3D.create(make_muzzle(), _aim_height_point(v), 0xFFFFFFFF, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.collider == v or (hit.collider is Node and v.is_ancestor_of(hit.collider))


func _aim_height_point(v: Node3D) -> Vector3:
	return v.global_position + Vector3.UP * (SOLDIER_AIM_HEIGHT if v is Infantry else VEHICLE_AIM_HEIGHT)


## Where to aim: the target's middle, led by its velocity over the shot's flight time.
func make_aim_point() -> Vector3:
	var p := _aim_height_point(target)
	var vel = target.get("velocity")
	if vel is Vector3:
		p += (vel as Vector3) * gun.make_flight_time(make_muzzle(), p)
	return p


func _apply_turn(want: Vector3, delta: float) -> void:
	var angle := aim_dir.angle_to(want)
	if angle <= 0.0001:
		return
	aim_dir = aim_dir.slerp(want, minf(1.0, turn_rate * delta / angle)).normalized()


## One shot along `dir` (host), paid from the energy; every peer plays the fire sequence.
func fire(dir: Vector3) -> void:
	_cooldown = refire
	energy = maxf(0.0, energy - minf(shot_energy, energy))
	shots_fired += 1
	gun.fire(self, make_muzzle(), dir, target)
	_play_fire()
	if Net.is_online():
		_play_fire.rpc()


@rpc("authority", "call_remote", "unreliable")
func _play_fire() -> void:
	if rig:
		rig.play_fire()

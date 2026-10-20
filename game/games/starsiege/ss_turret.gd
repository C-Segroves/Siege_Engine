class_name SSTurret
extends SSStructure
## A Starsiege mission turret (TRRT record + its datTurret.cs type): every check interval it picks the
## nearest hostile vehicle within its range, turns its head toward it at the type's turret speed and
## fires each weapon of the mission record whose hardpoint arc (pitch / yaw limits on the head) holds
## the target, at the weapon's own range, reload and ammunition (an empty gun is rearmed after the
## record's reload period). A target is kept until it leaves the activation distance plus the record's
## deactivation buffer. Hit points, fire and pre-damage come from the record (SSStructure); host only.
##
## Evidence: datTurret.cs turretBase(..., activateDist 500, turretVel 1.0, checkFreq 0.2, ...) and
## newHardPoint(..., X_rot_rnge = pitch, Z_rot_rnge = yaw); the .mis record (Turret::read, Starsiege.exe
## 0x443cc8) holds the weapon tags, rotational velocity, activation distance, deactivation buffer and
## reload/rearm period (tools/starsiege_mis.py read_turret).

const HEAD_NODE := "head0"
## datTurret.cs defaults (every type uses them): turretVel (rad/s), checkFreq (s), activateDist (m).
const DEFAULT_TURN_RATE := 1.0
const DEFAULT_CHECK_INTERVAL := 0.2
const DEFAULT_RANGE := 500.0
## Turret::read defaults when a record holds none (the shipped records: 9 or 60 s, 50..400 m).
const DEFAULT_REARM_PERIOD := 60.0
const DEFAULT_DEACTIVATE_BUFFER := 50.0
## Aim at the middle of a Herc rather than its feet.
const TARGET_AIM_HEIGHT := 4.0
## Muzzle height when the shape has no head node.
const FALLBACK_HEAD_HEIGHT := 6.0

var guns: Array[SSTurretGun] = []
var engage_range := DEFAULT_RANGE
var turn_rate := DEFAULT_TURN_RATE
var check_interval := DEFAULT_CHECK_INTERVAL
var rearm_period := DEFAULT_REARM_PERIOD
var deactivate_buffer := DEFAULT_DEACTIVATE_BUFFER
## Current target (guided projectiles of "sarh" type follow it, see Projectile._guide).
var target: Node3D
## Head rotation about the turret's up axis, relative to its placement (radians, counter-clockwise).
var head_yaw := 0.0
## Shots fired so far (tests, diagnostics).
var shots_fired := 0
var _head: Node3D
var _head_rest := Transform3D.IDENTITY
var _check_t := 0.0


## Builds a turret from its mission object `d` (exported turret fields); spec as SSStructure.build_body.
static func make_turret(parent: Node3D, spec: Dictionary, d: Dictionary) -> SSTurret:
	var t := SSTurret.new()
	t.build_body(parent, spec)
	t.apply_definition(d)
	return t


## Range, turn rate, check interval and guns from the exported mission object.
func apply_definition(d: Dictionary) -> void:
	var rng = d.get("turret_range")
	if rng == null or float(rng) <= 0.0:
		rng = d.get("activate_range")
	engage_range = float(rng) if rng != null and float(rng) > 0.0 else DEFAULT_RANGE
	turn_rate = _positive(d.get("turret_velocity"), _positive(d.get("turn_rate"), DEFAULT_TURN_RATE))
	check_interval = _positive(d.get("check_interval"), DEFAULT_CHECK_INTERVAL)
	var ai: Dictionary = d.get("turret_ai", {}) if d.get("turret_ai") is Dictionary else {}
	rearm_period = _positive(ai.get("reload_period"), DEFAULT_REARM_PERIOD)
	deactivate_buffer = maxf(float(ai.get("deactivate_buffer", DEFAULT_DEACTIVATE_BUFFER)), 0.0)
	var hps: Array = MissionRuntime._arr(d.get("hardpoints"))
	var weapons: Array = MissionRuntime._arr(d.get("turret_weapons"))
	for i in weapons.size():
		if weapons[i] == null:
			continue
		var hp: Dictionary = hps[i] if i < hps.size() else {}
		var g := SSTurretGun.make(self, String(weapons[i]), hp)
		if g:
			guns.append(g)
	_find_head()


static func _positive(v, fallback: float) -> float:
	return float(v) if v != null and float(v) > 0.0 else fallback


func _find_head() -> void:
	var nodes: Array = shape.shape.get("nodes", [])
	for i in nodes.size():
		if String(nodes[i].get("name", "")).to_lower() == HEAD_NODE and i < shape.nodes.size():
			_head = shape.nodes[i]
			_head_rest = _head.global_transform
			return


func is_armed() -> bool:
	return not guns.is_empty()


## World position of the head pivot.
func head_origin() -> Vector3:
	return _head_rest.origin if _head else global_position + global_basis.y * FALLBACK_HEAD_HEIGHT


## Orthonormal world basis of the head (placement yaw + head_yaw).
func head_basis() -> Basis:
	return global_basis.orthonormalized() * Basis(Vector3.UP, head_yaw)


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not alive or not is_armed() or not multiplayer.is_server():
		return
	for g in guns:
		g.apply_rearm(delta, rearm_period)
	_check_t -= delta
	if _check_t <= 0.0:
		_check_t = check_interval
		if not keeps_target():
			target = find_target()
	if target == null:
		return
	_apply_head_turn(delta)
	_fire_ready_guns()


## True while the current target is alive, hostile and within the activation distance plus the
## deactivation buffer.
func keeps_target() -> bool:
	if target == null or not is_instance_valid(target) or not target.alive:
		return false
	if not SSTeams.is_hostile(team, target.team) or target.has_meta("dormant"):
		return false
	var distance := global_position.distance_to(target.global_position)
	return distance <= engage_range + deactivate_buffer and not CloakRules.is_hidden_from_sensor(target, {}, distance)


## The nearest live vehicle of a hostile team within range; null when there is none.
func find_target() -> Node3D:
	return TurretTargeting.find_nearest(get_tree(), {"from": global_position, "range": engage_range,
		"is_hostile": func(v: Node) -> bool: return SSTeams.is_hostile(team, v.team)})


func _aim_point() -> Vector3:
	return target.global_position + Vector3.UP * TARGET_AIM_HEIGHT


func _apply_head_turn(delta: float) -> void:
	var local := global_basis.orthonormalized().inverse() * (_aim_point() - head_origin())
	var want := atan2(-local.x, -local.z)
	var step := wrapf(want - head_yaw, -PI, PI)
	head_yaw = wrapf(head_yaw + clampf(step, -turn_rate * delta, turn_rate * delta), -PI, PI)
	if _head:
		_head.global_transform = Transform3D(Basis(global_basis.y.normalized(), head_yaw) * _head_rest.basis,
			_head_rest.origin)


func _fire_ready_guns() -> void:
	var hb := head_basis()
	var aim := _aim_point()
	for g in guns:
		if not g.is_ready():
			continue
		var from := head_origin() + hb * g.offset
		var to_target := aim - from
		var dist := to_target.length()
		if dist > minf(g.weapon.weapon_range, engage_range) or dist < 0.01:
			continue
		var dir := to_target / dist
		if g.is_in_arc(hb, dir):
			g.fire(self, from, dir, target)
			shots_fired += 1

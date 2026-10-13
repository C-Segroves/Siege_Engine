class_name MineRunner
extends RefCounted
## A laid mine's behaviour, from its weapon's "projectile" block (no remake minimums: the game's numbers):
##   - it settles: falls (projectile gravity) or drops to hover_height above the ground (Battledrome 0x104b8);
##   - it arms after arm_delay;
##   - a static mine waits; a chasing mine (Battledrome "chase": BLOODHND / PITBULL, 0x1018c) runs at the nearest
##     enemy within detect_radius at its speed; a tracking mine (Starsiege newMine with a turn rate: the ARAC
##     Arachnitron spider mine) crawls at the launcher's target, else the nearest enemy within its weapon range,
##     accelerating from start_speed to its speed and turning at turn_rate_deg;
##   - it goes off when an enemy's centre is closer than `proximity` (Battledrome trigger distance, Earthsiege
##     proximity), or - "trigger": "contact" (Starsiege proximity 0) - when it touches the enemy's hull.
## Enemies: units whose team is hostile to the layer's (TeamRelations).

const VEHICLES := "vehicles"
const TRIGGER_CONTACT := "contact"
## Ray length below the mine when looking for the ground (m).
const GROUND_PROBE := 200.0
## Height the mine body sits above the ground when the data has no hover height (m).
const REST_HEIGHT := 0.3

var hover_height := REST_HEIGHT
var detect_radius := 0.0
var chase := false
var tracking := false
var contact_trigger := false
var start_speed := 0.0
var top_speed := 0.0
var accel := 0.0
var turn_rate := 0.0
var _speed := 0.0
var _heading := Vector3.ZERO
var _fall := 0.0


## Rules of weapon definition `d` (its "projectile" block).
static func make_for(d: Dictionary) -> MineRunner:
	var pr: Dictionary = d.get("projectile", {}) if d.get("projectile") is Dictionary else {}
	var m := MineRunner.new()
	m.hover_height = float(pr.get("hover_height", REST_HEIGHT))
	m.detect_radius = float(pr.get("detect_radius", 0.0))
	m.chase = bool(pr.get("chase", false))
	m.turn_rate = deg_to_rad(float(pr.get("turn_rate_deg", 0.0)))
	m.top_speed = float(pr.get("speed", 0.0))
	m.tracking = not m.chase and m.turn_rate > 0.0 and m.top_speed > 0.0
	m.start_speed = float(pr.get("start_speed", m.top_speed))
	m.accel = float(pr.get("accel", 0.0))
	m.contact_trigger = str(pr.get("trigger", "")) == TRIGGER_CONTACT
	m._speed = m.start_speed
	return m


## True when the mine moves after it settles.
func is_mobile() -> bool:
	return (chase or tracking) and top_speed > 0.0


## One tick of mine `p`; true when it must go off now.
func update(p: Projectile, delta: float) -> bool:
	var ground := _make_ground_height(p)
	if p._age <= p.arm_delay or not is_mobile():
		_apply_settle(p, ground, delta)
	else:
		_apply_hunt(p, ground, delta)
	return p._age > p.arm_delay and is_triggered(p)


## True when an enemy is within the trigger distance (or touching, for a contact trigger).
func is_triggered(p: Projectile) -> bool:
	for v in p.get_tree().get_nodes_in_group(VEHICLES):
		if v is Herc and v.alive and _is_enemy(p, v):
			var reach: float = (v as Herc).make_contact_radius() if contact_trigger else p.proximity
			if p.global_position.distance_to(v.global_position) < reach:
				return true
	return false


## The unit a mobile mine runs at, null when none is in reach.
func make_quarry(p: Projectile) -> Herc:
	if tracking and p.target is Herc and p.target.alive and _is_enemy(p, p.target):
		return p.target
	var reach := detect_radius if chase else p.max_range
	var best: Herc = null
	var best_d := reach
	for v in p.get_tree().get_nodes_in_group(VEHICLES):
		if v is Herc and v.alive and _is_enemy(p, v):
			var d := p.global_position.distance_to(v.global_position)
			if d < best_d:
				best_d = d
				best = v
	return best


func _apply_settle(p: Projectile, ground: float, delta: float) -> void:
	var rest := ground + hover_height
	if p.gravity > 0.0 and p.global_position.y > rest:
		_fall += p.gravity * delta
		p.global_position.y = maxf(rest, p.global_position.y - _fall * delta)
	else:
		p.global_position.y = rest
		_fall = 0.0


func _apply_hunt(p: Projectile, ground: float, delta: float) -> void:
	_apply_settle(p, ground, delta)
	var quarry := make_quarry(p)
	if quarry == null:
		return
	var to := quarry.global_position - p.global_position
	to.y = 0.0
	if to.length() < 0.01:
		return
	var want := to.normalized()
	if _heading == Vector3.ZERO or turn_rate <= 0.0:
		_heading = want
	else:
		_heading = _heading.slerp(want, clampf(turn_rate * delta / maxf(_heading.angle_to(want), 0.001), 0.0, 1.0)).normalized()
	_speed = minf(top_speed, _speed + accel * delta) if accel > 0.0 else top_speed
	p.global_position += _heading * minf(_speed * delta, to.length())


func _make_ground_height(p: Projectile) -> float:
	var at := p.global_position
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * hover_height, at + Vector3.DOWN * GROUND_PROBE, 1)
	var hit := p.get_world_3d().direct_space_state.intersect_ray(q)
	return float(hit.position.y) if not hit.is_empty() else at.y - hover_height


static func _is_enemy(p: Projectile, v: Node) -> bool:
	if v == p.shooter:
		return false
	if not is_instance_valid(p.shooter) or p.shooter.get("team") == null:
		return true
	return TeamRelations.is_hostile(int(p.shooter.get("team")), int(v.get("team")))

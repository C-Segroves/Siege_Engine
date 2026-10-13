class_name Projectile
extends Node3D
## Ray-stepped projectile driven by a weapon definition's "projectile" block (engine weapon schema):
## cannon shells, guided missiles (sarh/arh/arm/eo/heat), lobbed grenades/artillery (gravity),
## plasma balls, and dropped proximity mines. Its look, trail and impacts come from the weapon's fx data
## (FxProjectileLook, FxPlayer: docs/formats/weapon_fx.md).
## `visual_only` copies run on network clients for display; only the server's copy deals damage.

## Hit sound level relative to the weapon's fire sound.
const HIT_VOLUME_DB := -2.0
## Besides the vehicles, nodes of this group take splash damage (Tribes base equipment: a mortar beside a
## generator damages it, as Tribes radius damage hits every shape in range).
const SPLASH_TARGETS := "splash_targets"
## Guidance ECM cannot deflect: anti-radiation homes on the jammer, electro-optical sees it (ES1 DBSIM 0x6ffb,
## ES2 0x40a394; ES1 readme: ECM jams only SARH and ARH).
const ECM_IMMUNE_GUIDANCE := ["arm", "eo"]
## Muzzle exit (m of flight): until then the shot passes through its own shooter's collision shape, which is
## coarser than the model (a capsule's round top over a tank's turret, a pod on its edge). Only that first
## stretch: a shot that comes back later (a lobbed shell falling short, a missile turning) hits its shooter.
const SHOOTER_CLEARANCE := Herc.CAPSULE_MAX_RADIUS * 2.0
## A steered missile's nose stays within this of straight up / down.
const STEER_MAX_CLIMB := deg_to_rad(85.0)

## Emitted where the projectile hits something (not when it times out).
signal impacted(at: Vector3)

var shooter: Node3D
var direction := Vector3.FORWARD
var speed := 300.0
var gravity := 0.0
var lifetime := 0.0             # s (0 = derive from range)
var shield_damage := 400.0
var armor_damage := 400.0
var splash := 0.0               # fraction of damage applied in the splash radius
var splash_radius := 12.0
var effects := {}               # emp_shield_drain, elf_leech, disable_seconds
var max_range := 300.0
var color := Color(1, 0.9, 0.4)
var guidance := "none"          # none, sarh, arh, arm, eo, heat, wire
var turn_rate := 2.5            # rad/s for homing
var proximity := 0.0            # m: detonate when a hostile vehicle is this close (mines, flak)
var arm_delay := 0.0
var is_mine := false
## A laid mine's rules (MineRunner); null for every other projectile.
var mine: MineRunner = null
var weapon_def := {}             # the firing weapon's catalog definition (fx look, sounds)
var visual_only := false
var target: Node3D
## Share of its velocity a shell loses per second in water (Tribes 2 GrenadeProjectile: drag x 15, only in
## liquid; projectile "water_drag_per_s").
var water_drag := 0.0
var inherited_velocity := Vector3.ZERO   # share of the shooter's velocity (Tribes velInheritFactor)
## The pilot's MissileSteering when this is a player's EO missile: it flies by the pilot's stick, not by homing.
var steering: MissileSteering = null

var guided: bool:
	get:
		return guidance != "none"
var lobbed: bool:
	get:
		return gravity > 0.0

var _age := 0.0
var _travelled := 0.0
var _velocity := Vector3.ZERO


func _ready() -> void:
	add_to_group("projectiles")
	_velocity = direction * speed + inherited_velocity
	if lifetime <= 0.0:
		lifetime = (max_range / maxf(speed, 1.0)) * (1.6 if lobbed else 1.05) if not is_mine else INF
	add_child(FxProjectileLook.create(weapon_def, color, lifetime))


func _physics_process(delta: float) -> void:
	_age += delta
	if _age > lifetime:
		if is_mine or lobbed:
			_impact(global_position, null)
		else:
			queue_free()
		return
	if is_mine:
		if mine.update(self, delta):
			detonate()
		return
	if guided and _age > arm_delay * 0.5:
		_guide(delta)
	if lobbed:
		_velocity.y -= gravity * delta
	if water_drag > 0.0 and MapWater.is_in_water(get_tree(), global_position):
		_velocity -= _velocity * minf(water_drag * delta, 1.0)
	var step := _velocity * delta
	var ex := []
	if is_instance_valid(shooter) and shooter is CollisionObject3D and _travelled < SHOOTER_CLEARANCE:
		ex.append((shooter as CollisionObject3D).get_rid())
	var q := PhysicsRayQueryParameters3D.create(global_position, global_position + step, 0xFFFFFFFF, ex)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		_impact(hit.position, hit.collider)
		return
	if proximity > 0.0 and _age > arm_delay and _hostile_within(proximity):
		_impact(global_position, null)
		return
	global_position += step
	if step.length() > 0.001:
		look_at(global_position + step, Vector3.UP if absf(step.normalized().y) < 0.99 else Vector3.RIGHT)
	_travelled += step.length()


func _guide(delta: float) -> void:
	if steering != null:
		if steering.is_steering_missile(self):
			apply_steer(steering.stick, delta)
		return
	var t := target
	match guidance:
		"arh", "heat", "arm":
			# active homing: reacquire the nearest hostile ahead if the target is lost
			if not _valid_target(t):
				t = _nearest_hostile_ahead(0.6)
				target = t
		"sarh", "eo", "wire":
			# semi-active / optical / wire: follows the shooter's current target only
			if is_instance_valid(shooter) and "target" in shooter:
				t = shooter.target
	if not _valid_target(t):
		return
	var want := (t.global_position + Vector3.UP * 4.0 - global_position).normalized()
	# ECM deflects radar/optical homing (not ARM); a targeting pod on the shooter counters it
	if t.has_meta("ecm_jam_deg") and not ECM_IMMUNE_GUIDANCE.has(guidance) and not (is_instance_valid(shooter) and shooter.has_meta("eccm")):
		var jam := deg_to_rad(float(t.get_meta("ecm_jam_deg")))
		want = (Basis(Vector3.UP, jam) * want).normalized()
	var dir := _velocity.normalized().slerp(want, clampf(turn_rate * delta, 0.0, 1.0)).normalized()
	_velocity = dir * speed


## Turns the flight by stick `stick` (x right, y nose down, -1..1) at up to turn_rate (ES1 0x70dc: yaw and pitch
## change by 0x500 x stick / 256 per frame).
func apply_steer(stick: Vector2, delta: float) -> void:
	var step := turn_rate * delta
	var dir := _velocity.normalized()
	var yawed := Basis(Vector3.UP, -clampf(stick.x, -1.0, 1.0) * step) * dir
	var right := yawed.cross(Vector3.UP)
	if right.length() > 0.001:
		var pitched := Basis(right.normalized(), -clampf(stick.y, -1.0, 1.0) * step) * yawed
		if absf(pitched.y) <= sin(STEER_MAX_CLIMB):
			yawed = pitched
	_velocity = yawed.normalized() * speed


## Lets the missile fly on straight, unguided (an EO missile whose pilot let go of the trigger: ES1 0x717e).
func drop_guidance() -> void:
	guidance = "none"


## Current flight direction (unit vector).
func make_heading() -> Vector3:
	return _velocity.normalized() if _velocity.length() > 0.001 else direction


func _valid_target(t) -> bool:
	return is_instance_valid(t) and (not ("alive" in t) or t.alive)


func _nearest_hostile_ahead(min_dot: float) -> Node3D:
	var best: Node3D = null
	var bd := max_range
	var fwd := _velocity.normalized()
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v == shooter or not v.alive or (is_instance_valid(shooter) and v.team == shooter.team):
			continue
		var to: Vector3 = v.global_position - global_position
		var d := to.length()
		if d < bd and fwd.dot(to / maxf(d, 0.01)) > min_dot:
			bd = d
			best = v
	return best


func _hostile_within(r: float) -> bool:
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v == shooter or not v.alive:
			continue
		if is_instance_valid(shooter) and v.team == shooter.team:
			continue
		if v.global_position.distance_to(global_position) < r + 3.0:
			return true
	return false


## Sets the projectile off where it is (a mine's trigger, a shot mine: MineBody).
func detonate() -> void:
	if is_queued_for_deletion():
		return
	_impact(global_position, null)


func _impact(pos: Vector3, collider: Object) -> void:
	impacted.emit(pos)
	_play_impact(pos, collider)
	if not visual_only:
		if collider and collider.has_method("apply_hit"):
			DamageModel.apply_weapon_hit(collider, DamageModel.make_hit(shield_damage, armor_damage, shooter, pos, weapon_def))
			Weapon.apply_effects(collider, effects, shooter)
		if splash > 0.0 and DamageModel.splashes_nearby_units(weapon_def):
			Blast.apply_to_units(get_tree(), {"pos": pos, "radius": splash_radius, "shield": shield_damage * splash,
				"armor": armor_damage * splash, "attacker": shooter, "weapon": weapon_def, "skip": collider,
				"extra_group": SPLASH_TARGETS})
	queue_free()


## The weapon's impact effect for the surface hit (before the damage changes the target's shield);
## the weapon's hit sound when the effect has none of its own.
func _play_impact(pos: Vector3, collider: Object) -> void:
	var surface := FxSurface.of(collider, pos, shield_damage)
	var normal := -_velocity.normalized() if _velocity.length() > 0.001 else Vector3.UP
	if Effects.fx.play_impact(get_parent(), weapon_def, surface, pos, normal):
		return
	var hit = weapon_def.get("sounds", {}).get("hit")
	if hit is String and hit != "":
		Sfx.play_at(hit, pos, HIT_VOLUME_DB)

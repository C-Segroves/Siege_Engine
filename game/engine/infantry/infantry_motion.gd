class_name InfantryMotion
extends RefCounted
## A soldier's running and jetting (Tribes PlayerData movement; docs/formats/tribes_infantry.md section 2), on
## the soldier's controls and armour: Infantry._drive calls it each physics frame.


## Wanted movement in the world (x/z, length 0..1) from the forward and strafe inputs.
static func make_wish_direction(s: Infantry) -> Vector3:
	var local := Vector3(clampf(s.turn, -1.0, 1.0), 0.0, -clampf(s.throttle, -1.0, 1.0))
	if local.length() > 1.0:
		local = local.normalized()
	return Basis(Vector3.UP, s.rotation.y) * local


## Ground running: the horizontal velocity approaches the wanted one at groundForce / mass, with the
## armour's forward, backward and side speed limits.
static func apply_ground_movement(s: Infantry, wish: Vector3, delta: float) -> void:
	var target := wish * make_ground_speed_limit(s, wish)
	var horizontal := Vector3(s.velocity.x, 0.0, s.velocity.z).move_toward(target, s.accel * delta)
	s.velocity.x = horizontal.x
	s.velocity.z = horizontal.z


## Top ground speed in direction `wish` (maxForwardSpeed / maxBackwardSpeed / maxSideSpeed).
static func make_ground_speed_limit(s: Infantry, wish: Vector3) -> float:
	if wish.length() < 0.01:
		return 0.0
	var local := Basis(Vector3.UP, s.rotation.y).inverse() * wish.normalized()
	var along := float(s.armor.get("max_forward_speed", 11.0)) if local.z <= 0.0 else float(s.armor.get("max_backward_speed", 10.0))
	var side := float(s.armor.get("max_side_speed", 10.0))
	return Vector2(local.x * side, local.z * along).length()


## The jetpack: jetForce / mass of thrust straight up (net of gravity: 26.2 - 20 = 6.2 m/s^2 for the Tribes 1 light
## armour, so it must never be split with the sideways push), plus a horizontal push along the movement input of
## maxJetSideForceFactor of it (none beyond maxJetForwardVelocity); spends jetEnergyDrain.
static func apply_jet(s: Infantry, wish: Vector3, delta: float) -> void:
	s.capacitor = maxf(0.0, s.capacitor - float(s.armor.get("jet_energy_per_s", 25.0)) * delta)
	var thrust := float(s.armor.get("jet_accel", 26.2))
	var side := float(s.armor.get("jet_side_factor", 0.8)) * minf(wish.length(), 1.0)
	var dir := wish.normalized() if wish.length() > 0.01 else Vector3.ZERO
	if Vector3(s.velocity.x, 0.0, s.velocity.z).dot(dir) >= float(s.armor.get("max_jet_forward_speed", 22.0)):
		side = 0.0
	s.velocity += dir * thrust * side * delta
	s.velocity.y += thrust * delta


## Falling (or flying) into something faster than the armour's fall_min_speed hurts, of the armour's fall damage
## type; the impact speed is along the surface normal (`before` = the velocity before the move):
##   Tribes 2  impact x fall_damage_per_mps (Armor::onImpact: vecLen x speedDamageScale above minImpactSpeed)
##   Tribes 1  (impact - fall_min_speed) x fall_damage_per_mps ("fall_damage_above_min"; tribes.exe 0x4162d2:
##             (speed - minDamageSpeed) x damageScale)
static func apply_fall_damage(s: Infantry, before: Vector3) -> void:
	if before.length() <= float(s.armor.get("fall_min_speed", INF)):
		return   # the impact along a surface normal is never more than the speed: no slide collision is read
	var impact := 0.0
	for i in s.get_slide_collision_count():
		impact = maxf(impact, -before.dot(s.get_slide_collision(i).get_normal()))
	apply_impact_damage(s, impact)


## Damage of a fall that struck along a surface normal at `impact` m/s (the armour's fall rule).
static func apply_impact_damage(s: Infantry, impact: float) -> void:
	var dmg := make_fall_damage(s.armor, impact)
	if dmg <= 0.0:
		return
	KillText.apply_cause(s, KillText.CAUSE_FALL)   # the kill message says how (KillText)
	DamageTypes.apply_typed_hit(s, [0.0, dmg, null, s.global_position], str(s.armor.get("fall_damage_type", "")))
	KillText.apply_cause(s, "")


## Damage of an impact at `impact` m/s along the surface normal for `armor` (0 at or below its fall_min_speed).
static func make_fall_damage(armor: Dictionary, impact: float) -> float:
	var least := float(armor.get("fall_min_speed", INF))
	if impact <= least:
		return 0.0
	var counted := impact - least if bool(armor.get("fall_damage_above_min", false)) else impact
	return counted * float(armor.get("fall_damage_per_mps", 0.0))

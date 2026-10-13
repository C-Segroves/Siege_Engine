class_name WeaponShot
extends RefCounted
## One shot of a catalog weapon (docs/formats/weapon_schema.md), the same for every shooter: a vehicle's
## Weapon, a Starsiege or Tribes base turret, a Battledrome arena turret. Instant beams ray-cast, show the beam
## and its impact (FxSurface), and land a typed hit (DamageTypes) with the weapon's effects; projectiles are
## built by Weapon.make_projectile and announced to every peer. The shooter is the hit's attacker and is never
## hit by its own beam.
##
## shot: {shooter: Node3D (CollisionObject3D), def: weapon definition, from: Vector3, dir: Vector3 (unit),
##        target: Node3D or null (projectiles), scale: damage factor (beams; default 1)}


## Fires an instant beam; returns the ray hit ({} when it hit nothing).
static func fire_beam(shot: Dictionary) -> Dictionary:
	var shooter: Node3D = shot.shooter
	var d: Dictionary = shot.def
	var from: Vector3 = shot.from
	var reach := float(d.get("range", 0.0))
	var scale := float(shot.get("scale", 1.0))
	var q := PhysicsRayQueryParameters3D.create(from, from + (shot.dir as Vector3) * reach, 0xFFFFFFFF, [shooter.get_rid()])
	var hit := shooter.get_world_3d().direct_space_state.intersect_ray(q)
	var end: Vector3 = hit.position if hit else from + (shot.dir as Vector3) * reach
	var shield := float(d.get("shield_damage", 0.0)) * scale
	# the impact look depends on the target's shield before this shot lands (FxSurface)
	var surface := FxSurface.of(hit.collider, end, shield) if hit else ""
	var sounds: Dictionary = d.get("sounds", {})
	_announce(shooter, "beam", [from, end, Weapon.make_color(d), sounds.get("fire", d.get("name", "")),
		str(d.get("id", "")), surface, sounds.get("hit", "hit_laser")])
	if hit and hit.collider and hit.collider.has_method("apply_hit"):
		DamageModel.apply_weapon_hit(hit.collider, DamageModel.make_hit(shield, float(d.get("armor_damage", 0.0)) * scale,
			shooter, end, d))
		Weapon.apply_effects(hit.collider, d.get("effects", {}), shooter)
	return hit


## Launches the weapon's projectile into the shooter's battle; returns it.
static func launch_projectile(shot: Dictionary) -> Projectile:
	var shooter: Node3D = shot.shooter
	var target: Node3D = shot.get("target")
	var p := Weapon.make_projectile(shot.def, shooter, shot.from, shot.dir, target)
	shooter.get_parent().add_child(p)
	p.global_position = shot.from
	var message := [shot.from, shot.dir, str((shot.def as Dictionary).get("id", "")), target.net_id if target is Herc else 0]
	if shooter is Herc:
		message.append((shooter as Herc).net_id)   # clients adopt the missile for the missile cam / steering
	_announce(shooter, "projectile", message, true)
	return p


## Battle effect message (every peer draws it); battles without the fx channel (tools) skip it.
static func _announce(shooter: Node3D, kind: String, args: Array, reliable := false) -> void:
	var battle := shooter.get_parent()
	if battle.has_method("fx"):
		battle.fx(kind, args, reliable)

class_name TribesTurretGun
extends RefCounted
## The gun of a Tribes base turret (TribesTurret): its catalog weapon (gameplay/weapons_turret.json, the turret's
## own projectile datablock) and how a shot leaves it. Projectiles go through the shared Projectile code and the
## battle fx channel; beams (the ELF turrets) hit the first thing along the ray. A ballistic shell (projectile
## gravity > 0: mortars) is lobbed on the flatter of the two arcs that reach the target at its muzzle speed.

var def: Dictionary = {}


static func make(weapon_id: String) -> TribesTurretGun:
	var g := TribesTurretGun.new()
	g.def = Packs.weapon(weapon_id)
	return g


func is_valid() -> bool:
	return not def.is_empty()


func make_speed() -> float:
	return float(def.get("speed", 0.0))


func make_gravity() -> float:
	var pr = def.get("projectile")
	return float(pr.get("gravity", 0.0)) if pr is Dictionary and pr.get("gravity") != null else 0.0


func is_beam() -> bool:
	return str(def.get("kind", "")) in Weapon.INSTANT_BEAM_KINDS and not (def.get("projectile") is Dictionary)


## World direction a shot from `from` must leave in to reach `to`: straight for beams and flat shots, the
## low ballistic arc for shells; Vector3.ZERO when a shell cannot reach it.
func make_fire_direction(from: Vector3, to: Vector3) -> Vector3:
	var g := make_gravity()
	var v := make_speed()
	var d := to - from
	if g <= 0.0 or v <= 0.0 or is_beam():
		return d.normalized()
	var flat := Vector2(d.x, d.z)
	var x := flat.length()
	if x < 0.01:
		return Vector3.UP if d.y > 0.0 else Vector3.DOWN
	var root := v * v * v * v - g * (g * x * x + 2.0 * d.y * v * v)
	if root < 0.0:
		return Vector3.ZERO
	var angle := atan((v * v - sqrt(root)) / (g * x))
	var h := flat.normalized() * cos(angle)
	return Vector3(h.x, sin(angle), h.y).normalized()


## Seconds a shot from `from` takes to `to` (for leading a moving target).
func make_flight_time(from: Vector3, to: Vector3) -> float:
	var v := make_speed()
	return from.distance_to(to) / v if v > 1.0 else 0.0


## One shot from `turret` at `from` along `dir` toward `target`.
func fire(turret: Node3D, from: Vector3, dir: Vector3, target: Node3D) -> void:
	var shot := {"shooter": turret, "def": def, "from": from, "dir": dir, "target": target}
	if is_beam():
		WeaponShot.fire_beam(shot)
	else:
		WeaponShot.launch_projectile(shot)
	Sfx.play_at(str(def.get("sounds", {}).get("fire", "")), from)

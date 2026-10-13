class_name SSTurretGun
extends RefCounted
## One weapon of a Starsiege mission turret: a catalog weapon (Weapon.from_def keeps its range, reload,
## damage, colour and ammunition: datWeapon.cs weaponAmmo maxAmmo, energy weapons unlimited) on a
## datTurret.cs hardpoint (offset on the head node, pitch and yaw limits). An empty gun is rearmed after
## the turret record's reload/rearm period (IDITG_TURRET_RELOAD_FREQ).
## Fires beams and projectiles through the shared weapon code (Weapon.make_projectile,
## Weapon.apply_effects) and the battle fx channel, like a Herc's Weapon does.

## Guided missiles leave the rails at a fixed pitch and steer onto the target, so only the yaw
## limits apply to them (the missile hardpoints of datTurret.cs have pitch range 0..0).
const UNGUIDED := "none"

var weapon: Weapon
var hardpoint: Dictionary
var offset := Vector3.ZERO       # engine frame, metres, on the head node
var pitch_min := deg_to_rad(-90.0)
var pitch_max := deg_to_rad(90.0)
var yaw_min := deg_to_rad(-180.0)
var yaw_max := deg_to_rad(180.0)
var _empty_t := 0.0


## A gun for catalog weapon `weapon_id` on `hp` (a datTurret.cs hardpoint, may be empty); null when
## the weapon is unknown. The Weapon node is added to `owner` (it counts down its own reload).
static func make(owner: Node, weapon_id: String, hp: Dictionary) -> SSTurretGun:
	var d := Packs.weapon(weapon_id)
	if d.is_empty():
		push_error("SSTurretGun: unknown weapon %s" % weapon_id)
		return null
	var g := SSTurretGun.new()
	g.weapon = Weapon.from_def(d)
	owner.add_child(g.weapon)
	g.hardpoint = hp
	if not hp.is_empty():
		g.offset = ShapeInstance.es_dir(hp.offset)
		g.pitch_min = deg_to_rad(float(hp.pitch_deg[0]))
		g.pitch_max = deg_to_rad(float(hp.pitch_deg[1]))
		g.yaw_min = deg_to_rad(float(hp.yaw_deg[0]))
		g.yaw_max = deg_to_rad(float(hp.yaw_deg[1]))
	return g


func is_guided() -> bool:
	var pr = weapon.def.get("projectile")
	return pr is Dictionary and String(pr.get("guidance", UNGUIDED)) != UNGUIDED


func is_ready() -> bool:
	return weapon.cooldown <= 0.0 and not is_empty()


## Out of ammunition (energy weapons never are).
func is_empty() -> bool:
	return weapon.ammo == 0


## Counts an empty gun's rearm time; refills it once `period` seconds have passed.
func apply_rearm(delta: float, period: float) -> void:
	if not is_empty():
		return
	_empty_t += delta
	if _empty_t >= period:
		_empty_t = 0.0
		weapon.reload()


## True when `aim_dir` (world) lies inside this hardpoint's arc of a head facing `head_basis`.
func is_in_arc(head_basis: Basis, aim_dir: Vector3) -> bool:
	var local := head_basis.inverse() * aim_dir
	var yaw := atan2(-local.x, -local.z)    # counter-clockwise from the head's forward, like the original
	if yaw < yaw_min or yaw > yaw_max:
		return false
	if is_guided():
		return true
	var pitch := atan2(local.y, Vector2(local.x, local.z).length())
	return pitch >= pitch_min and pitch <= pitch_max


## Fires one shot from `from` along `dir` at `target`; `shooter` is the turret (damage attacker).
func fire(shooter: SSTurret, from: Vector3, dir: Vector3, target: Node3D) -> void:
	weapon.spend_shot()
	var shot := {"shooter": shooter, "def": weapon.def, "from": from, "dir": dir, "target": target}
	if weapon.fires_beam():
		WeaponShot.fire_beam(shot)
	else:
		WeaponShot.launch_projectile(shot)
	Sfx.play_at(weapon.def.get("sounds", {}).get("fire", weapon.weapon_name), from)

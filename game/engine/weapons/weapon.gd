class_name Weapon
extends Node
## A weapon mounted on a vehicle, configured from a catalog weapon definition (Packs.weapon(),
## engine weapon schema in docs/formats/weapon_schema.md). Supports beams (single/multi), cannons,
## guided missiles, lobbed grenades/artillery, plasma, dropped mines and bombs, EMP/ELF effects, bursts and
## spread, ammo and capacitor energy. Firing happens only where the vehicle is simulated
## (server / single player); every peer renders shots from the weapon id via the battle fx channel.

var herc: Herc
var def: Dictionary
var weapon_id := ""
var weapon_name := "LAS100"
## What the HUD shows: the catalog's display name (ES1 keeps its original short names, LAS100 ...).
var display_name := "LAS100"
var kind := "beam"
var weapon_range := 200.0
var refire := 1.2
var ammo := -1
var ammo_max := -1
var per_shot := 0
var min_charge := 0
var beams := 1
var burst := 1
var burst_interval := 0.0
var spread := 0.0
var shield_damage := 600.0
var armor_damage := 1500.0
var splash := 0.0
var effects := {}
var projectile_speed := 300.0
var color := DEFAULT_COLOR
var mount_index := 0
var group := 0               # 0 = primary trigger, 1 = secondary (missiles, mines, artillery)

## Beam / tracer colour of a weapon whose data and name give none (the laser red).
const DEFAULT_COLOR := Color(1.0, 0.25, 0.15)
## Kinds drawn as instant beams (unless the weapon has a projectile block).
const INSTANT_BEAM_KINDS := ["beam", "emp", "flame"]
## Kinds on the secondary trigger unless the weapon names its fire group (schema "fire_group" 1 / 2).
const SECONDARY_KINDS := ["missile", "grenade", "mine", "artillery", "bomb"]
## Speed given to projectiles whose data has none (m/s).
const DEFAULT_PROJECTILE_SPEED := 300.0
## Bombs and mines keep their (near zero) launch speed: they fall or lie where they are released.
const DROPPED_KINDS := ["mine", "bomb"]
## Projectile lifetime when the data has none: Projectile derives it from range and speed.
const LIFETIME_FROM_RANGE := 0.0

## "<weapon id>.<field>" already reported as null (warn once per field, not per shot).
static var _warned_null_fields := {}

var trigger := false
var cooldown := 0.0
var _burst_left := 0
var _burst_t := 0.0

const COLORS := {
	"LAS": Color(1.0, 0.25, 0.15), "PBEAM": Color(0.45, 0.65, 1.0), "EMP": Color(0.6, 1.0, 1.0),
	"ELF": Color(0.9, 0.5, 1.0), "ATC": Color(1.0, 0.9, 0.5), "MLRS": Color(1, 1, 1),
	"MISSL": Color(1, 1, 1), "GREN": Color(1.0, 0.7, 0.3), "PLASM": Color(0.5, 1.0, 0.6),
	"BLAST": Color(0.4, 1.0, 0.4), "MINE": Color(1.0, 0.4, 0.1),
}


static func from_def(d: Dictionary) -> Weapon:
	var w := Weapon.new()
	w.apply_def(d)
	return w


## Configures this weapon from a catalog weapon definition (subclasses: InfantryWeapon).
func apply_def(d: Dictionary) -> void:
	def = d
	weapon_id = d.get("id", "")
	weapon_name = d.name
	display_name = str(d.get("display_name", d.name))
	kind = d.kind
	weapon_range = d.range
	refire = d.refire
	ammo_max = d.ammo
	ammo = d.ammo
	per_shot = int(d.get("per_shot", 0))
	min_charge = int(d.get("min_charge", 0))
	beams = int(d.get("beams", 1))
	burst = maxi(1, int(d.get("burst", 1)))
	burst_interval = float(d.get("burst_interval", 0.0))
	spread = deg_to_rad(float(d.get("spread_deg", 0.0)))
	shield_damage = float(d.shield_damage)
	armor_damage = float(d.armor_damage)
	splash = float(d.get("splash", 0.0))
	effects = d.get("effects", {})
	projectile_speed = float(d.speed) if float(d.speed) > 1.0 else DEFAULT_PROJECTILE_SPEED
	group = make_fire_group(d)
	color = make_color(d)


## The weapon's beam / tracer colour: the data's own, else by the original name's family (LAS..., PBEAM...).
static func make_color(d: Dictionary) -> Color:
	var c = _make_color_value(d)
	if c is Array and c.size() >= 3:
		return Color(float(c[0]), float(c[1]), float(c[2]))
	for k in COLORS:
		if String(d.get("name", "")).begins_with(k):
			return COLORS[k]
	return DEFAULT_COLOR


## 0 = primary trigger, 1 = secondary: the weapon's own "fire_group" (1 / 2), else by kind.
static func make_fire_group(d: Dictionary) -> int:
	var fg := int(d.get("fire_group", 0))
	if fg > 0:
		return fg - 1
	return 1 if d.kind in SECONDARY_KINDS else 0


## The beam colour, else the projectile's (Tribes tracer / flare colours), else null.
static func _make_color_value(d: Dictionary) -> Variant:
	for block in [d.get("beam"), d.get("projectile")]:
		if block is Dictionary and block.get("color") is Array:
			return block.color
	return null


func reload() -> void:
	ammo = ammo_max
	cooldown = 0.0
	_burst_left = 0


func _physics_process(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	if herc == null or not herc.alive or herc.is_puppet:
		return
	if _burst_left > 0:
		_burst_t -= delta
		if _burst_t <= 0.0:
			_burst_left -= 1
			_burst_t = burst_interval
			_shoot()
		return
	if not trigger or not ready_to_fire():
		return
	fire()


## Passive equipment (ECM, targeting/shield/turbo/energy pods) occupies a hardpoint but never fires.
func is_passive() -> bool:
	return kind in ["ecm", "other"]


func ready_to_fire() -> bool:
	if ammo == 0 or is_passive() or herc.missile_steering.is_group_blocked(group):
		return false
	if kind in ["beam", "emp"] and herc.capacitor < min_charge:
		return false
	return cooldown <= 0.0


## Projectile origin: the muzzle at the barrel of this hardpoint's weapon model (weapon_mounts.md).
func muzzle() -> Node3D:
	var mounts := herc.mount_points()
	return HercModel.muzzle_of(mounts[mount_index % mounts.size()])


## Starts a trigger pull: one shot, or a burst/salvo. Firing ends the shooter's spawn protection.
func fire() -> void:
	herc.end_spawn_protection()
	cooldown = refire
	if ammo > 0:
		ammo -= 1
	_burst_left = burst - 1
	_burst_t = burst_interval
	_shoot()


## Where the pilot aims: the first thing on the sight line (aim_origin along aim_basis -Z, the crosshair ray of
## the cockpit camera) within range, else the point at full range. Every muzzle fires at this point, so the
## guns converge on the crosshair wherever they hang on the vehicle.
func make_aim_point() -> Vector3:
	var aim := -herc.aim_basis().z
	var eye := herc.aim_origin()
	var q := PhysicsRayQueryParameters3D.create(eye, eye + aim * weapon_range, 0xFFFFFFFF, [herc.get_rid()])
	var hit := herc.get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position if hit else eye + aim * weapon_range


## Shot direction from muzzle point `from` to the aim point (no spread).
func make_aim_direction(from: Vector3) -> Vector3:
	return (make_aim_point() - from).normalized()


func _aim_dir(from: Vector3) -> Vector3:
	var dir := make_aim_direction(from)
	if spread > 0.0:
		var b := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
		dir = (b * Basis(Vector3.RIGHT, randf_range(-spread, spread)) * Basis(Vector3.UP, randf_range(-spread, spread)) * Vector3.FORWARD).normalized()
	return dir


func _shoot() -> void:
	var from := muzzle().global_position
	var dir := _aim_dir(from)
	var scale := 1.0
	if kind in ["beam", "emp"]:
		var use := float(per_shot)
		if herc.capacitor < use:
			use = herc.capacitor
		herc.capacitor -= use
		if def.get("charge_scaled", false):
			# original (gameplay.md section 4): a full shot does the row's damage; only when the capacitor
			# can't pay per_shot does it fire with the whole charge, scaled by charge / 1024
			scale = 1.0 if use >= float(per_shot) else minf(use / 1024.0, 1.0)
		elif per_shot > 0:
			# engine-schema damage is per full shot; partial charge fires proportionally weaker
			scale = clampf(use / float(per_shot), 0.0, 1.0)
	if fires_beam():
		_fire_beams(from, dir, scale)
	else:
		_launch(from, dir)
	FxPodCells.play(herc, def, mount_index)
	Sfx.play_at(def.get("sounds", {}).get("fire", weapon_name), from)


func _launch(from: Vector3, dir: Vector3) -> void:
	match kind:
		"mine":
			from = herc.global_position - herc.global_basis.z * -4.0 + Vector3.UP * 1.0
			_spawn_projectile(from, Vector3.DOWN)
		"bomb":
			_spawn_projectile(from, Vector3.DOWN)
		_:
			if kind == "artillery" or (kind == "grenade" and def.get("projectile", {}).get("gravity", 0.0) > 0.0):
				dir = (dir + Vector3.UP * 0.35).normalized()
			_spawn_projectile(from, dir)


## Instant beams: beam kinds without a flying projectile (an ES1 EMP is a bullet: it flies).
func fires_beam() -> bool:
	return kind in INSTANT_BEAM_KINDS and not (def.get("projectile") is Dictionary)


func _fire_beams(from: Vector3, dir: Vector3, scale: float) -> void:
	var n := maxi(beams, int(def.get("beam", {}).get("count", 1)) if def.get("beam") is Dictionary else beams)
	var origins := [from]
	if n >= 3:
		var side := herc.aim_basis().x * 0.8
		origins = [from, from + side, from - side]
	elif n == 2:
		var side2 := herc.aim_basis().x * 0.5
		origins = [from + side2, from - side2]
	var aim_point := from + dir * from.distance_to(make_aim_point())
	for o in origins:
		var beam_dir: Vector3 = (aim_point - o).normalized()   # side-by-side beams converge on the crosshair
		WeaponShot.fire_beam({"shooter": herc, "def": def, "from": o, "dir": beam_dir, "scale": scale})


func _spawn_projectile(from: Vector3, dir: Vector3) -> void:
	var p := WeaponShot.launch_projectile({"shooter": herc, "def": def, "from": from, "dir": dir, "target": herc.target})
	herc.missile_steering.adopt(p, group)


## Builds a projectile from a weapon definition (used by the shooter and by clients' visuals).
static func make_projectile(d: Dictionary, shooter: Node3D, from: Vector3, dir: Vector3, target: Node3D, visual := false) -> Projectile:
	var pr: Dictionary = d.get("projectile", {}) if d.get("projectile") is Dictionary else {}
	var p := Projectile.new()
	p.shooter = shooter
	p.visual_only = visual
	p.direction = dir
	p.speed = _projectile_number(d, "speed", float(d.get("speed", DEFAULT_PROJECTILE_SPEED)))
	if p.speed <= 1.0 and not (d.kind in DROPPED_KINDS):
		p.speed = DEFAULT_PROJECTILE_SPEED
	if shooter is CharacterBody3D:
		p.inherited_velocity = (shooter as CharacterBody3D).velocity * _projectile_number(d, "inherit_velocity", 0.0)
	p.gravity = _projectile_number(d, "gravity", 9.8 if d.kind == "grenade" else 0.0)
	p.lifetime = _projectile_number(d, "lifetime", LIFETIME_FROM_RANGE)
	p.max_range = float(d.range)
	p.shield_damage = float(d.shield_damage)
	p.armor_damage = float(d.armor_damage)
	p.splash = float(d.get("splash", 0.0))
	p.splash_radius = float(d.get("splash_radius", 12.0)) if float(d.get("splash_radius", 0.0)) > 0.0 else 12.0
	p.effects = d.get("effects", {})
	var g := String(pr.get("guidance", "arh" if d.kind == "missile" else "none"))
	p.guidance = g
	p.turn_rate = deg_to_rad(_projectile_number(d, "turn_rate_deg", 140.0)) if g != "none" else 0.0
	p.proximity = _projectile_number(d, "proximity", 0.0)
	p.arm_delay = _projectile_number(d, "arm_delay", 0.0)
	p.water_drag = _projectile_number(d, "water_drag_per_s", 0.0)
	p.is_mine = d.kind == "mine"
	if p.is_mine:
		p.mine = MineRunner.make_for(d)
		if bool(pr.get("shootable", false)) and not visual:
			p.add_child(MineBody.new(p))
	p.weapon_def = d
	p.target = target
	p.color = make_color(d)
	return p


## A number from the weapon's "projectile" block; `fallback` when it is missing or null (a null is
## a data bug: it is reported once per weapon and field, the weapon still fires).
static func _projectile_number(d: Dictionary, field: String, fallback: float) -> float:
	var pr: Dictionary = d.get("projectile", {}) if d.get("projectile") is Dictionary else {}
	var value = pr.get(field, fallback)
	if value == null:
		var key := "%s.%s" % [d.get("id", "?"), field]
		if not _warned_null_fields.has(key):
			_warned_null_fields[key] = true
			push_warning("Weapon %s: projectile.%s is null, using %s" % [d.get("id", "?"), field, fallback])
		return fallback
	return float(value)


## Special effects on hit: EMP takes the shields (the target's damage model: Earthsiege switches them off for its
## shield-down time), ELF leeches capacitor energy, disable stops a vehicle (a non-EMP weapon's
## "disable_seconds"; an Earthsiege 2 EMP's is its shield-down time).
static func apply_effects(target: Object, fx: Dictionary, shooter: Node) -> void:
	if fx.is_empty() or not (target is Herc):
		return
	var h := target as Herc
	var emp := float(fx.get("emp_shield_drain", 0))
	if emp > 0.0:
		h.damage_model.apply_emp(h, emp, fx)
	var elf := float(fx.get("elf_leech", 0))
	if elf > 0.0:
		var taken := minf(h.capacitor, elf)
		h.capacitor -= taken
		if shooter is Herc:
			shooter.capacitor = minf(shooter.capacitor_max, shooter.capacitor + taken)
	var dis := float(fx.get("disable_seconds", 0))
	if dis > 0.0 and emp <= 0.0:
		h.set_meta("disabled_until", Time.get_ticks_msec() + int(dis * 1000.0))

class_name CollisionDamage
extends RefCounted
## Damage from collisions (host only; puppets never simulate): a moving vehicle that rams another vehicle or a
## structure, or runs over a soldier. Called by a vehicle after each move_and_slide with the velocity it moved at.
##
## Vehicle <-> vehicle and vehicle <-> structure: Earthsiege's ramming rule (DBSIM 0x14180..0x14482, docs/formats/
## gameplay.md mass field 0x4c): momentum p = mass * v / 1024 (fixmul 0x5e818), impact = 300 * (p_self - p_other
## along self's motion) / 1024; above 200 both bodies take `impact` (0x13a7c, called for each of the pair): each of
## the 28 damage components, at a 50% chance (rand & 0xfff < 0x802), takes impact * (1 - d / 1200 units) by its
## distance d from the contact point (Blast.make_component_hits: each component's COL sphere, the unit centre for
## one without; a vehicle without positioned components takes the falloff's mean, RAM_COMPONENT_SHARE). The original compares the forward speeds; the remake uses the velocities
## along the line between the two bodies (the same for a Herc walking into something). A structure is at rest.
## Masses and speeds are converted to Earthsiege units (MASS_TO_ES1, ES1_MPS_PER_SPEED_UNIT), so every game's
## vehicles ram by one rule.
##
## Vehicle -> soldier: Tribes 2's vehicle collision damage (VehicleData collDamageThresholdVel /
## collDamageMultiplier, scripts/vehicles/vehicle_*.cs; the victim takes $DamageType::Impact, "run down by
## vehicle", defaultGame.cs): above the threshold speed the soldier takes speed * multiplier (Tribes 2 damage,
## x3000 = engine hit points, tribes_infantry.md). Tribes 2 vehicles use their own datablock's values, which the
## importer reads from the user's scripts into the vehicle def ("run_over", tools/export_tribes_vehicles.py); every
## other vehicle (Hercs, Tribes 1, Starsiege, or a Tribes 2 pack imported before that field) the remake rule
## RUN_OVER_DEFAULT (a walking threshold), so a fast Herc kills a light soldier and a slow one hurts him.
##
## One contact damages a pair once per REPEAT_SECONDS (remake: move_and_slide reports a held contact every frame).

## DBSIM 0x14353 / 0x14366 / 0x14455.
const RAM_SCALE := 300.0
const RAM_THRESHOLD := 200.0
const FIXED_ONE := 1024.0
const RAM_COMPONENT_CHANCE := 0.5
## The ram's component reach (0x13a7c called with 1200 units).
const RAM_REACH_UNITS := 1200.0
## Mean of the linear falloff (1 - d / reach) over the reach.
const RAM_COMPONENT_SHARE := 0.5
## Earthsiege speed unit in code metres per second (units.json run_mps_per_speed_unit: 256 units = 30.48 m/s).
const ES1_MPS_PER_SPEED_UNIT := 30.48 / 256.0
## Vehicle "mass" of each pack in Earthsiege mass units (Raptor 6000; ~10 kg): Earthsiege and Battledrome (the
## loader already scales BD x4) as they are, Starsiege in tonnes, Tribes 1 armour/vehicle mass (light armour 9 =
## ~90 kg), Tribes 2 in kilograms (light armour 90). Remake conversion.
const MASS_TO_ES1 := {"es1": 1.0, "es2": 1.0, "bd": 1.0, "starsiege": 100.0, "tribes": 1.0, "tribes2": 0.1}
const DEFAULT_MASS := 6000.0
## Remake rule for vehicles without a "run_over" def field: faster than a soldier runs, Tribes damage per m/s.
const RUN_OVER_DEFAULT := {"threshold_mps": 4.0, "multiplier": 0.03}
## Tribes damage -> engine hit points (InfantryCatalog hp = maxDamage x 3000).
const TRIBES_DAMAGE_TO_HP := 3000.0
const IMPACT_DAMAGE_TYPE := "impact"
const REPEAT_SECONDS := 1.0
const META_LAST_HITS := "collision_hits"


## Host: damage from the contacts of `mover`'s last move_and_slide, made at velocity `moved_at`.
static func apply_contacts(mover: Herc, moved_at: Vector3) -> void:
	if mover is Infantry or mover.is_puppet or not mover.alive or not mover.multiplayer.is_server():
		return   # a soldier running into things takes his own falling damage (InfantryMotion)
	for i in mover.get_slide_collision_count():
		var hit := mover.get_slide_collision(i)
		var other := hit.get_collider()
		if other == null or other == mover or not _is_due(mover, other):
			continue
		if other is Infantry:
			_apply_run_over(mover, other as Infantry, moved_at)
		elif other is Herc:
			_apply_ram(mover, other as Herc, moved_at, hit.get_position())
		elif other is Structure:
			_apply_ram_structure(mover, other as Structure, moved_at, hit.get_position())


## True (and the pair's time recorded) when `mover` may damage `other` again.
static func _is_due(mover: Herc, other: Object) -> bool:
	var hits: Dictionary = mover.get_meta(META_LAST_HITS, {})
	var now := Engine.get_physics_frames()   # simulation time: the same under any frame rate or load
	var key := other.get_instance_id()
	var repeat_frames := int(REPEAT_SECONDS * Engine.physics_ticks_per_second)
	if hits.has(key) and now - int(hits[key]) < repeat_frames:
		return false
	hits[key] = now
	mover.set_meta(META_LAST_HITS, hits)
	return true


static func _apply_ram(mover: Herc, other: Herc, moved_at: Vector3, contact: Vector3) -> void:
	var n := _make_contact_direction(mover.global_position, other.global_position)
	var impact := make_ram_impact(make_es1_mass(mover), moved_at.dot(n), make_es1_mass(other), other.velocity.dot(n))
	if impact <= RAM_THRESHOLD or not other.alive:
		return
	mover.apply_collision_damage(impact, other, contact)
	other.apply_collision_damage(impact, mover, contact)


static func _apply_ram_structure(mover: Herc, st: Structure, moved_at: Vector3, contact: Vector3) -> void:
	var n := _make_contact_direction(mover.global_position, st.global_position)
	var impact := make_ram_impact(make_es1_mass(mover), moved_at.dot(n), 0.0, 0.0)
	if impact <= RAM_THRESHOLD or not st.alive:
		return
	mover.apply_collision_damage(impact, st, contact)
	st.apply_damage_event(DamageEvent.make_ram(impact, mover, mover.global_position))


static func _apply_run_over(mover: Herc, soldier: Infantry, moved_at: Vector3) -> void:
	var n := _make_contact_direction(mover.global_position, soldier.global_position)
	var closing := (moved_at - soldier.velocity).dot(n)
	var dmg := make_run_over_damage(mover.def, closing)
	if dmg > 0.0 and soldier.alive:
		DamageTypes.apply_typed_hit(soldier, [0.0, dmg, mover, soldier.global_position], IMPACT_DAMAGE_TYPE)


## Earthsiege ramming impact of a body (mass, speed towards the other, m/s) against another (mass, its speed
## along the same direction): 300 * (p_self - p_other) / 1024, p = mass * speed units / 1024.
static func make_ram_impact(mass: float, speed: float, other_mass: float, other_speed: float) -> float:
	var p_self := mass * make_es1_speed_units(speed) / FIXED_ONE
	var p_other := other_mass * make_es1_speed_units(other_speed) / FIXED_ONE
	return RAM_SCALE * (p_self - p_other) / FIXED_ONE


## Hit points a soldier loses when a vehicle of definition `vdef` runs into him at `closing` m/s.
static func make_run_over_damage(vdef: Dictionary, closing: float) -> float:
	var rule: Dictionary = vdef.get("run_over") if vdef.get("run_over") is Dictionary else RUN_OVER_DEFAULT
	if closing <= float(rule.get("threshold_mps", RUN_OVER_DEFAULT.threshold_mps)):
		return 0.0
	return closing * float(rule.get("multiplier", RUN_OVER_DEFAULT.multiplier)) * TRIBES_DAMAGE_TO_HP


## A world speed (m/s) in Earthsiege speed units.
static func make_es1_speed_units(mps: float) -> float:
	return mps / (ES1_MPS_PER_SPEED_UNIT * Packs.code_to_world("es1"))


## The vehicle's (or soldier's armour's) mass in Earthsiege units.
static func make_es1_mass(h: Herc) -> float:
	var pack := str(h.def.get("pack", Assets.split_id(h.vehicle_id)[0]))
	return float(h.def.get("mass", DEFAULT_MASS)) * float(MASS_TO_ES1.get(pack, 1.0))


## Horizontal direction from `from` to `to` (forward when they stand on each other).
static func _make_contact_direction(from: Vector3, to: Vector3) -> Vector3:
	var d := Vector3(to.x - from.x, 0.0, to.z - from.z)
	return d.normalized() if d.length_squared() > 0.0001 else Vector3.FORWARD

class_name InfantryPack
extends RefCounted
## What the worn backpack does each frame and to each hit (docs/formats/tribes_infantry.md section 6):
##   energy  adds recharge (T1 EnergyPackImage negative energy use, T2 rechargeRateBoost);
##   repair  while on: repairs its wearer at repair_per_s, spending energy_per_s (T1 RepairBolt with no
##           target, T2 RepairGunImage repairFactorPlayer);
##   shield  while on: the energy absorbs hits, energy_per_damage per point (T1 Player::onDamage
##           shieldStrength, T2 Armor checkShields / energyPerDamagePoint); spends energy_per_s;
##   jammer  while on: bots don't see the wearer beyond jam_radius and homing missiles are deflected;
##   ammo    more rounds (InfantryKit.make_max_count, Infantry.make_rounds).
## A toggled pack switches off when the energy falls below its min_energy (the image's minEnergy).

const META_JAM_DEG := "ecm_jam_deg"
const META_JAM_RADIUS := "jam_radius"

static var _deflection := -1.0   # make_missile_deflection, looked up once


## Extra energy recharge per second of the worn pack.
static func make_recharge_bonus(kit: InfantryKit) -> float:
	return float(InfantryGear.pack(kit.pack_id).get("recharge_bonus_per_s", 0.0))


## One frame of a switched-on pack: energy use, repair, jamming.
static func apply_frame(soldier: Infantry, delta: float) -> void:
	var kit := soldier.kit
	var p := InfantryGear.pack(kit.pack_id)
	if kit.pack_active and soldier.capacitor < float(p.get("min_energy", 0.0)):
		kit.pack_active = false
	if kit.pack_active:
		soldier.capacitor = maxf(0.0, soldier.capacitor - float(p.get("energy_per_s", 0.0)) * delta)
		if p.effect == "repair":
			apply_repair(soldier, float(p.get("repair_per_s", 0.0)) * delta)
	_apply_jamming(soldier, kit.pack_active and p.get("effect", "") == "jammer", p)


## Adds `amount` health (never above the armour's).
static func apply_repair(soldier: Infantry, amount: float) -> void:
	var c: Dictionary = soldier.components[0]
	c.hp = minf(float(c.max), float(c.hp) + amount)
	soldier.integrity = HercDamage.integrity_of(soldier.components)


static func _apply_jamming(soldier: Infantry, on: bool, p: Dictionary) -> void:
	if on:
		soldier.set_meta(META_JAM_DEG, make_missile_deflection())
		soldier.set_meta(META_JAM_RADIUS, float(p.get("jam_radius", 0.0)))
	elif soldier.has_meta(META_JAM_RADIUS):
		soldier.remove_meta(META_JAM_DEG)
		soldier.remove_meta(META_JAM_RADIUS)


## The shield pack takes `damage` (of `type`) out of the energy; returns what gets through.
static func apply_shield(soldier: Infantry, damage: float, type: String) -> float:
	var kit := soldier.kit
	var p := InfantryGear.pack(kit.pack_id)
	if not kit.pack_active or p.get("effect", "") != "shield" or damage <= 0.0:
		return damage
	var per_point := float(soldier.armor.get("shield_energy_per_damage", p.get("energy_per_damage", 0.0)))
	per_point /= float((p.get("weak_types", {}) as Dictionary).get(type, 1.0))
	if per_point <= 0.0:
		return damage
	var capacity := soldier.capacitor / per_point
	if damage <= capacity:
		soldier.capacitor -= damage * per_point
		return 0.0
	soldier.capacitor = 0.0
	return damage - capacity


## How far homing missiles aimed at a jamming soldier turn off (the engine's ECM effect, Projectile): the
## installed catalog's ECM equipment value (the Earthsiege 2 ECM pod, effects.missile_jam_deg), the remake's
## stand-in for the Tribes sensor suppression; 0 (no deflection) when no pack provides one.
static func make_missile_deflection() -> float:
	if _deflection < 0.0:
		_deflection = 0.0
		for w in Packs.weapons.values():
			var fx = (w as Dictionary).get("effects", {})
			if fx is Dictionary and fx.has("missile_jam_deg"):
				_deflection = float(fx.missile_jam_deg)
				break
	return _deflection


## True when `soldier` jams sensors at `distance` metres (the jammer hides him farther out).
static func is_hidden_at(soldier: Node, distance: float) -> bool:
	return soldier.has_meta(META_JAM_RADIUS) and distance > float(soldier.get_meta(META_JAM_RADIUS))

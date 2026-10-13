class_name InfantryWeapon
extends Weapon
## A hand weapon of a Tribes soldier (category "infantry"): ammunition per armour ($ItemMax rounds) and the
## soldier's energy for energy weapons. Beams (laser rifle, ELF) already pay per shot from the energy pool in
## Weapon; projectile energy weapons (the blaster: minEnergy to fire, maxEnergy per shot) pay here.

const BEAM_KINDS := ["beam", "emp"]


## A weapon from a catalog definition carrying `rounds` of ammunition (-1 = none needed).
static func make(d: Dictionary, rounds: int) -> InfantryWeapon:
	var w := InfantryWeapon.new()
	w.apply_def(d)
	w.ammo_max = rounds
	w.ammo = rounds
	return w


## True for a projectile weapon that fires on energy instead of ammunition (the blaster).
func uses_energy_per_shot() -> bool:
	return per_shot > 0 and not BEAM_KINDS.has(kind)


func ready_to_fire() -> bool:
	if not super.ready_to_fire():
		return false
	return not uses_energy_per_shot() or herc.capacitor >= maxf(float(min_charge), float(per_shot))


func fire() -> void:
	super.fire()
	if uses_energy_per_shot():
		herc.capacitor = maxf(0.0, herc.capacitor - per_shot)


## Rounds short of a full load (0 for weapons without ammunition).
func missing_rounds() -> int:
	return maxi(ammo_max - ammo, 0) if ammo_max >= 0 else 0


## Adds up to `rounds` of ammunition (an ammo station), never beyond a full load.
func apply_resupply(rounds: int) -> void:
	ammo += mini(rounds, missing_rounds())

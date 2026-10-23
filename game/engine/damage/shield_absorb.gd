class_name ShieldAbsorb
extends RefCounted
## The two shield rules every game uses, as pure functions (results are Array[float] pairs: a Vector2 would round the doubles).
##   bank     Earthsiege / Starsiege Herc banks: a pool of points that takes the shield part of a hit;
##            the rest passes through as a share of the armour damage.
##   energy   Tribes shields and shield packs: an energy pool with a cost per point of damage; the armour
##            damage the energy cannot pay for goes on.


## A bank of `bank` points takes `shield_dmg`; [0] = the share of the armour damage that gets through, [1] = the bank left.
static func make_through_bank(bank: float, shield_dmg: float) -> Array[float]:
	if shield_dmg <= 0.0:
		return [1.0, bank]
	if bank >= shield_dmg:
		return [0.0, bank - shield_dmg]
	return [(shield_dmg - bank) / shield_dmg, 0.0]


## `energy` pays `cost` per point of `damage`; [0] = the damage that gets through, [1] = the energy left.
static func make_through_energy(energy: float, cost: float, damage: float) -> Array[float]:
	if cost <= 0.0 or energy <= 0.0 or damage <= 0.0:
		return [damage, energy]
	var capacity := energy / cost
	if damage <= capacity:
		return [0.0, energy - damage * cost]
	return [damage - capacity, 0.0]

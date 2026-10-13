class_name BdDamageModel
extends DamageModel
## Battledrome shields by weapon class (Herc events 0x67 / 0x68, docs/formats/bd_weapons.md section 4; the
## catalog damage is already on the Earthsiege scale, section 5):
##   laser, plasma   the bank absorbs 1:1 (the generic rule)
##   blaster         the bank absorbs at most 3/4: at least 1/4 always leaks through
##   canon           at least 1/8 always gets through
##   missile         a bank above MISSILE_SHIELD_LIMIT stops it: the missile detonates on the shield at half damage
##                   and drains an eighth of its damage
##   mine            bypasses the shield
## Battledrome Hercs carry one hull (no logical parts in the catalog), so the 3/4 + 1/4 part spread lands on it.

const BLASTER_LEAK := 0.25
const CANON_LEAK := 0.125
const MISSILE_SHIELD_LIMIT := 200.0
const MISSILE_ON_SHIELD := 0.5
const MISSILE_DRAIN := 0.125


func make_shield_through(h: Herc, hit: Dictionary) -> float:
	var wdef: Dictionary = hit.get("weapon", {})
	match make_class(wdef):
		"mine":
			return 1.0
		"missile":
			return _make_missile_through(h, hit)
		"blaster":
			return maxf(super.make_shield_through(h, hit), BLASTER_LEAK)
		"canon":
			return maxf(super.make_shield_through(h, hit), CANON_LEAK)
	return super.make_shield_through(h, hit)


func _make_missile_through(h: Herc, hit: Dictionary) -> float:
	var front := h.is_front_hit(hit.pos, hit.attacker)
	var bank := h.shield_front if front else h.shield_rear
	if bank <= MISSILE_SHIELD_LIMIT:
		return super.make_shield_through(h, hit)
	h.absorb_with_shield(float(hit.armor) * MISSILE_DRAIN, front)
	return MISSILE_ON_SHIELD


## The Battledrome weapon class: the catalog kind, with blaster and canon told apart by the original name.
static func make_class(wdef: Dictionary) -> String:
	var n := str(wdef.get("name", "")).to_upper()
	if n.begins_with("BLASTER"):
		return "blaster"
	if n.begins_with("CANON"):
		return "canon"
	return str(wdef.get("kind", ""))

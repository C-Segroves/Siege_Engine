class_name DamageTypes
extends RefCounted
## The damage type of the hit being applied (Tribes $DamageScale / damageScale[$DamageType::X],
## docs/formats/tribes_infantry.md section 6). The hit pipeline (Herc.apply_hit and every target's
## apply_hit) takes no type, so shooters that know one (projectiles, beams, thrown grenades) apply their
## hit through apply_typed_hit, which names the type for exactly that call; Infantry reads `current`.
## Types are the armours' lower-case keys ("bullet", "shrapnel", "disc" ...); "" = untyped (scale 1).

## Type of the apply_hit call in progress ("" outside a typed hit).
static var current := ""


## The damage type of a catalog weapon ("" when its data has none).
static func of_weapon(def: Dictionary) -> String:
	return str(def.get("damage_type", ""))


## Calls target.apply_hit(...) with `type` as the hit's damage type.
static func apply_typed_hit(target: Object, hit: Array, type: String) -> void:
	var previous := current
	current = type
	target.callv("apply_hit", hit)
	current = previous


## Armour scale of `type` in `scales` (an armour's damage_scale), 1 when not listed.
static func make_scale(scales: Dictionary, type: String) -> float:
	return float(scales.get(type, 1.0)) if type != "" else 1.0

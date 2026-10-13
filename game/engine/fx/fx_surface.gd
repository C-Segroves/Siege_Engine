class_name FxSurface
extends RefCounted
## Which impact list a hit plays (weapon_fx.md 1.2): "miss" for terrain, structures or nothing,
## "shield" when the vehicle's shield bank on the hit side absorbs the whole shot (Earthsiege: the
## ricochet case of Mech::onHit, gameplay.md section 5 step 3), else "armor".
## Called before the damage is applied, on every peer (puppets carry their shield banks).

const MISS := "miss"
const SHIELD := "shield"
const ARMOR := "armor"
const WATER := "water"


static func of(collider: Object, hit_pos: Vector3, shield_damage: float) -> String:
	if collider == null or not is_instance_valid(collider) or not collider.has_method("shield_bank_at"):
		return MISS
	var bank: float = collider.shield_bank_at(hit_pos)
	if bank > 0.0 and bank >= shield_damage:
		return SHIELD
	return ARMOR

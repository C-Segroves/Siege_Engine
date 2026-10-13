extends StaticBody3D
## Target block of the weapon fx contact sheet: an armour surface (no shield) that takes no damage.

## Shield charge FxSurface reads: `shield` > 0 shows the shield-hit effects instead.
var shield := 0.0


func shield_bank_at(_hit_pos: Vector3) -> float:
	return shield


func apply_hit(_shield_dmg: float, _armor_dmg: float, _attacker: Node = null, _hit_pos := Vector3.ZERO) -> void:
	pass

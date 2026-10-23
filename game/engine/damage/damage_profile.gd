class_name DamageProfile
extends RefCounted
## The per-game data of how a target takes damage; `DamageTarget` runs it. Each game builds its own from its original
## values (TribesDamageProfile: base_equipment.json blocks; plain structures use the defaults):
##   scale_by_type      damage-type scale (Tribes 2 damage profiles, Tribes armours' damageScale); 1 when not listed
##   shield_cost        energy per point of damage a shield absorbs (0: no shield; Tribes 1 shieldStrength,
##                      Tribes 2 energyPerDamagePoint)
##   disabled_damage    damage taken from which the target is Disabled (-1: never, only Destroyed)
##   team_cap           damage level a team's own hits cannot take the target past (-1: no cap; Tribes 1
##                      StaticShape::onDamage keeps a Generator / Station just short of disabled)
##   strict_types       an unlisted (or no) damage type counts 0 (Tribes 1 Door::onDamage reads an unset $DoorScale global)
##   invincible         takes nothing (Tribes `invincible`)
##   indestructible     is hit, reports the hit, and never loses hit points (Starsiege SimShape flag)

var scale_by_type: Dictionary = {}
var shield_cost := 0.0
var disabled_damage := -1.0
var team_cap := -1.0
var strict_types := false
var invincible := false
var indestructible := false


## Scale of damage type `type` (1 when untyped or not listed).
func make_scale(type: String) -> float:
	if strict_types:
		return float(scale_by_type.get(type, 0.0))
	return DamageTypes.make_scale(scale_by_type, type)


## `amount` after the team-damage cap: a team's own hit may only take the target up to `team_cap` damage taken.
func make_team_capped(amount: float, damage_taken: float, friendly: bool) -> float:
	if team_cap < 0.0 or not friendly:
		return amount
	return clampf(team_cap - damage_taken, 0.0, amount)

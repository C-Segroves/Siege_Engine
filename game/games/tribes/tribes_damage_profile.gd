class_name TribesDamageProfile
extends RefCounted
## The Tribes games' DamageProfile data (docs/TRIBES_BASE_EQUIPMENT.md): a base object's block of the pack's
## base_equipment.json (the game's own datablocks) and a Tribes 1 door.

## Tribes 1 StaticShape::onDamage (scripts/staticshape.cs): a team's own hits on its Generator / Station class
## objects stop just short of disabling them (this much below the disabled damage, in Tribes damage units).
const T1_TEAM_DAMAGE_MARGIN := 0.05
const T1_PACK := "tribes"


## The profile of base object `kind` of pack `pack` built from `spec`: damage scale per type, shield cost, disabled
## damage (Tribes 1: maxDamage x the engine's disabled ratio; Tribes 2: disabledLevel), invincible, and the Tribes 1 team cap.
static func make_object(spec: Dictionary, pack: String, kind: String) -> DamageProfile:
	var p := DamageProfile.new()
	var dmg: Dictionary = spec.get("damage", {})
	p.disabled_damage = float(dmg.get("disabled_damage", dmg.get("hp", DamageTarget.DEFAULT_HP)))
	p.shield_cost = float((spec.get("shield", {}) as Dictionary).get("energy_per_point", 0.0))
	p.scale_by_type = spec.get("damage_scale", {})
	p.invincible = bool(spec.get("invincible", false))
	if pack == T1_PACK and (kind == TribesBaseObject.KIND_GENERATOR or kind in TribesBaseObject.STATION_KINDS):
		p.team_cap = p.disabled_damage - T1_TEAM_DAMAGE_MARGIN * TribesMissionRuntime.TRIBES_DAMAGE_SCALE
	return p


## A destroyable Tribes 1 door: hits scaled by the game's $DoorScale per damage type (Door::onDamage).
static func make_door(door_scale: Dictionary) -> DamageProfile:
	var p := DamageProfile.new()
	p.scale_by_type = door_scale
	p.strict_types = true
	return p

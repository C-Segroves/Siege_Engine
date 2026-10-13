class_name DamageModel
extends RefCounted
## How a vehicle takes a weapon hit, per game (one strategy per pack; Herc delegates apply_weapon_hit to it):
##   make_shield_through   the share of the armour damage the shields let through (the banks absorb first)
##   apply_armor           where the armour damage lands (component pick, splash within the unit)
##   apply_emp             what an EMP hit does to the shields
## This base is the remake's generic rule, kept for the games whose own model is not decoded (Starsiege, Tribes
## vehicles): the bank facing the attacker absorbs the shield damage 1:1, a component is picked by hit height,
## an EMP drains its amount from both banks. EsDamageModel (Earthsiege 1 / 2) and BdDamageModel (Battledrome)
## follow their decodes. A hit: {shield, armor, attacker, pos, weapon: catalog weapon definition or {}}.

static var _models := {}


## The model of the game vehicle definition `vdef` belongs to.
static func for_vehicle(vdef: Dictionary) -> DamageModel:
	var pack := pack_of(vdef)
	if not _models.has(pack):
		_models[pack] = _make_for_pack(pack)
	return _models[pack]


static func _make_for_pack(pack: String) -> DamageModel:
	match pack:
		"es1", "es2":
			return EsDamageModel.new(pack)
		"bd":
			return BdDamageModel.new()
	return DamageModel.new()


## The game a catalog definition (vehicle or weapon) belongs to.
static func pack_of(def: Dictionary) -> String:
	return str(def.get("pack", Assets.split_id(str(def.get("id", "")))[0]))


## True when weapon `wdef`'s splash reaches the units around the impact (Projectile); Earthsiege splash stays
## inside the struck unit (DBSIM 0x13a7c, radius 500 units: EsDamageModel).
static func splashes_nearby_units(wdef: Dictionary) -> bool:
	return not pack_of(wdef) in ["es1", "es2"]


## Lands weapon `wdef`'s hit on `target`: a vehicle takes it through its damage model (apply_weapon_hit), other
## targets through their apply_hit with the weapon's damage type (DamageTypes: Tribes armour scales).
static func apply_weapon_hit(target: Object, hit: Dictionary) -> void:
	if target.has_method("apply_weapon_hit"):
		var previous := DamageTypes.current
		DamageTypes.current = DamageTypes.of_weapon(hit.weapon)
		target.call("apply_weapon_hit", hit)
		DamageTypes.current = previous
		return
	DamageTypes.apply_typed_hit(target, [hit.shield, hit.armor, hit.attacker, hit.pos], DamageTypes.of_weapon(hit.weapon))


## A hit record of the plain apply_hit arguments (no weapon known).
static func make_hit(shield: float, armor: float, attacker: Node, pos: Vector3, wdef := {}) -> Dictionary:
	return {"shield": shield, "armor": armor, "attacker": attacker, "pos": pos, "weapon": wdef}


## Share (0..1) of the armour damage that gets through `h`'s shields; takes the shield damage off the bank.
func make_shield_through(h: Herc, hit: Dictionary) -> float:
	return h.absorb_with_shield(float(hit.shield), h.is_front_hit(hit.pos, hit.attacker))


## Lands `amount` armour damage of `hit` on `h`'s components.
func apply_armor(h: Herc, hit: Dictionary, amount: float) -> void:
	var local := h.global_transform.affine_inverse() * (hit.pos as Vector3)
	var pick := HercDamage.pick_component(h.components, local)
	if pick >= 0:
		h.wound_component(pick, amount)


## An EMP hit of `drain` shield points (weapon effects "emp_shield_drain"; `fx` = the weapon's effects).
func apply_emp(h: Herc, drain: float, _fx: Dictionary) -> void:
	h.shield_front = maxf(0.0, h.shield_front - drain * 0.5)
	h.shield_rear = maxf(0.0, h.shield_rear - drain * 0.5)

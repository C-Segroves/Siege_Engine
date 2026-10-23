class_name DamageEvent
extends RefCounted
## One piece of damage on its way to a target: what every game's hit, blast, ram, script call and burn becomes.
## `shield_part` is the share a shield bank takes first (Earthsiege / Starsiege weapons name it), `amount` what
## reaches the armour or hit points. `type` is the Tribes damage type of the hit ("" untyped, DamageTypes), `radius`
## the splash radius the damage came from (0: a direct hit).

const KIND_WEAPON := "weapon"
const KIND_RAM := "ram"
const KIND_SCRIPTED := "scripted"
const KIND_BURN := "burn"
const KIND_LETHAL := "lethal"
## Armour damage of a scripted kill: more than any target has.
const LETHAL_AMOUNT := 1.0e9

var amount := 0.0
var shield_part := 0.0
var attacker: Node
var position := Vector3.ZERO
var kind := KIND_WEAPON
var radius := 0.0
var type := ""


## The event of the plain `apply_hit` arguments, typed by the hit in progress (DamageTypes.current).
static func make(shield: float, armor: float, p_attacker: Node = null, p_position := Vector3.ZERO) -> DamageEvent:
	var e := DamageEvent.new()
	e.shield_part = shield
	e.amount = armor
	e.attacker = p_attacker
	e.position = p_position
	e.type = DamageTypes.current
	return e


## A vehicle's ram of a structure: `armor` points from `p_attacker` at `p_position`.
static func make_ram(armor: float, p_attacker: Node, p_position: Vector3) -> DamageEvent:
	var e := make(0.0, armor, p_attacker, p_position)
	e.kind = KIND_RAM
	return e


## Damage a mission script deals (armour only, nobody to credit, not typed).
static func make_scripted(armor: float, p_position := Vector3.ZERO) -> DamageEvent:
	var e := make(0.0, armor, null, p_position)
	e.kind = KIND_SCRIPTED
	e.type = ""
	return e


## A scripted destruction (AA campaign_logic DestroyItem): skips shields and scales.
static func make_lethal() -> DamageEvent:
	var e := make_scripted(LETHAL_AMOUNT)
	e.kind = KIND_LETHAL
	return e


## Fire damage (Starsiege static-base fire): `armor` points, credited to whoever last hit the target.
static func make_burn(armor: float, p_attacker: Node = null) -> DamageEvent:
	var e := make(0.0, armor, p_attacker)
	e.kind = KIND_BURN
	e.type = ""
	return e


## The event of a DamageModel hit record {shield, armor, attacker, pos, weapon}.
static func make_from_hit(hit: Dictionary) -> DamageEvent:
	var e := make(float(hit.shield), float(hit.armor), hit.attacker, hit.pos)
	e.type = DamageTypes.of_weapon(hit.get("weapon", {}))
	return e


## True when the event is not scaled or absorbed (a scripted kill).
func is_lethal() -> bool:
	return kind == KIND_LETHAL

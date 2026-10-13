class_name HercCondition
extends RefCounted
## A garage Herc's condition between missions (docs/formats/campaign_availability.md section 7): one
## fraction (0 destroyed .. 1 intact) per damage component, in the vehicle's component order
## (HercDamage.make_components: the DMG components, or one hull). [] means pristine. The originals
## keep the same per-component condition in the career Herc record (Earthsiege CAR files: 33 condition
## percents; Earthsiege 2 results.dat: 13 armour + 10 system + 10 weapon percents per squad Herc).
##
## The battle reads it back from the Herc's components (make_from_components) and applies it to a
## spawned Herc (apply_to_herc); the hangar shows it on the model (apply_to_model: a component below
## DAMAGED_LOOK shows its damaged cell, as the battle switches a destroyed component's part).

const PRISTINE := 1.0
const INTACT_STATE := 0
const DAMAGED_STATE := 1
## Below this a component shows its damaged look in the hangar (half its hit points, like the leg rule).
const DAMAGED_LOOK := 0.5
## Remake hull of a vehicle without damage components (HercDamage.DEFAULT_HULL_HP).
const HULL := [{"hp": HercDamage.DEFAULT_HULL_HP}]


## The vehicle's damage components ({hp, shape_part, index, name}; a single hull when it lists none).
static func make_component_defs(vid: String) -> Array:
	var comps: Array = Packs.vehicle(vid).get("damage", {}).get("components", [])
	return comps if not comps.is_empty() else HULL


## `condition` padded / trimmed to the vehicle's component count (missing entries are intact).
static func make_fractions(vid: String, condition: Array) -> Array:
	var out: Array = []
	for i in make_component_defs(vid).size():
		out.append(clampf(float(condition[i]), 0.0, 1.0) if i < condition.size() else PRISTINE)
	return out


## The condition of a battle Herc's components (hp / max each).
static func make_from_components(components: Array) -> Array:
	return components.map(func(c): return clampf(float(c.hp) / maxf(float(c.max), 1.0), 0.0, 1.0))


## Overall integrity (hit-point weighted, the battle's HercDamage.integrity_of rule), 0..1.
static func make_integrity(vid: String, condition: Array) -> float:
	var defs := make_component_defs(vid)
	var fractions := make_fractions(vid, condition)
	var total := 0.0
	var left := 0.0
	for i in defs.size():
		var hp := float(defs[i].get("hp", 1.0))
		total += hp
		left += hp * float(fractions[i])
	return left / maxf(total, 1.0)


static func make_percent(vid: String, condition: Array) -> int:
	return roundi(make_integrity(vid, condition) * 100.0)


static func is_pristine(condition: Array) -> bool:
	return condition.all(func(f): return float(f) >= PRISTINE)


## Every component brought up to at least `target` (0..1).
static func make_repaired(vid: String, condition: Array, target: float) -> Array:
	return make_fractions(vid, condition).map(func(f): return maxf(float(f), target))


## Sets a freshly spawned Herc's components to `condition` and shows the damaged parts.
static func apply_to_herc(h: Herc, condition: Array) -> void:
	if condition.is_empty():
		return
	var fractions := make_fractions(h.vehicle_id, condition)
	for i in mini(h.components.size(), fractions.size()):
		h.components[i].hp = float(h.components[i].max) * float(fractions[i])
	h.integrity = HercDamage.integrity_of(h.components)
	apply_to_model(h.shape, h.vehicle_id, condition)


## Damaged look on a Herc model: each component's shape part (DMG shape_part = cell slot) shows its
## damaged state while its worst component is below DAMAGED_LOOK, intact otherwise.
static func apply_to_model(model: ShapeInstance, vid: String, condition: Array) -> void:
	if model == null:
		return
	var worst := make_slot_worst(vid, condition)
	for slot in worst:
		model.set_slot_state(int(slot), DAMAGED_STATE if float(worst[slot]) < DAMAGED_LOOK else INTACT_STATE)


## {shape part slot: lowest fraction of the components drawn on it}.
static func make_slot_worst(vid: String, condition: Array) -> Dictionary:
	var defs := make_component_defs(vid)
	var fractions := make_fractions(vid, condition)
	var worst := {}
	for i in defs.size():
		var slot := int(defs[i].get("shape_part", -1))
		if slot >= 0:
			worst[slot] = minf(float(worst.get(slot, PRISTINE)), float(fractions[i]))
	return worst

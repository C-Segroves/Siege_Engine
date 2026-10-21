class_name HercMounts
extends RefCounted
## The component slots of a Starsiege Herc (docs/formats/cloaking.md): the free mountpoints of the vehicle's data
## (`mountpoints` of gameplay/hercs.json: id, size, allowed categories) that take optional gear, and which cloak
## component (Chameleon 830, Cuttlefish 831) a player fits in each. A slot is a mountpoint whose `allowed` list names
## the category "Cloak"; the engine, reactor, computer, shield, armour and sensor mountpoints take one category each
## and are not listed. A component fits when its mount size (catalog `mount_size`, carried in cloak.json) is no larger
## than the slot's size (S < M < L < X, the datHerc mountpoint sizes).
##
## `mounts` is one int per slot, the shared loadout data that the garage entry ("mounts"), the character slot
## ("herc_mounts"), the roster ("mounts") and the spawn spec ("mounts") carry: 0 = the factory fit of that slot,
## -1 = emptied, else a component id. The factory fit is the vehicle's default_mountables beyond the fixed
## categories, in mountpoint order. Only cloaks are modelled so far: the other gear of a slot (amplifier, ECM ...)
## has no effect in the remake.

const CLOAK_CATEGORY := "Cloak"
const SIZES := ["S", "M", "L", "X"]
const FACTORY := 0
const EMPTIED := -1
## default_mountables kinds that belong to a fixed mountpoint, not to a free slot.
const FIXED_KINDS := ["engine", "reactor", "computer", "shield", "armor", "sensor"]


## [{index, mount_id, size, allowed}] for the free slots of vehicle `v` ([] when it has none).
static func make_slots(v: Dictionary) -> Array:
	var out := []
	for m in v.get("mountpoints", []):
		if (m.get("allowed", []) as Array).has(CLOAK_CATEGORY):
			out.append({"index": out.size(), "mount_id": int(m.get("id", 0)), "size": str(m.get("size", "S")),
				"allowed": m.allowed})
	return out


static func has_slots(v: Dictionary) -> bool:
	return not make_slots(v).is_empty()


## The component ids the factory fits in the free slots (0 = nothing), one per slot.
static func make_factory(v: Dictionary) -> Array:
	var gear := []
	for m in v.get("default_mountables", []):
		if not FIXED_KINDS.has(str(m.get("kind", ""))):
			gear.append(int(m.get("id", 0)))
	var out := []
	for i in make_slots(v).size():
		out.append(int(gear[i]) if i < gear.size() else 0)
	return out


## The cloak components that fit slot `slot_index` of `v`: [CloakProfile], lowest id first.
static func make_options(v: Dictionary, slot_index: int) -> Array:
	var slots := make_slots(v)
	if slot_index < 0 or slot_index >= slots.size():
		return []
	return CloakProfile.make_components(str(v.get("pack", ""))).filter(func(p: CloakProfile) -> bool:
		return is_size_fit(p.mount_size, str(slots[slot_index].size)))


## True when a component of mount size `part_size` goes into a slot of `slot_size`.
static func is_size_fit(part_size: String, slot_size: String) -> bool:
	var part := SIZES.find(part_size)
	return part >= 0 and part <= SIZES.find(slot_size)


## True when `component_id` (FACTORY, EMPTIED or a cloak) may go into slot `slot_index` of `v`.
static func is_allowed(v: Dictionary, slot_index: int, component_id: int) -> bool:
	if component_id == FACTORY or component_id == EMPTIED:
		return slot_index >= 0 and slot_index < make_slots(v).size()
	var pack_name := str(v.get("pack", ""))
	return make_options(v, slot_index).any(func(p: CloakProfile) -> bool: return p.component_id_of(pack_name) == component_id)


## `mounts` fitted to the slots of `v`: the right length, only fitting cloaks (anything else becomes the factory fit).
static func make_sanitized(v: Dictionary, mounts: Array) -> Array:
	var out := []
	for i in make_slots(v).size():
		var value := int(mounts[i]) if i < mounts.size() and mounts[i] != null else FACTORY
		out.append(value if is_allowed(v, i, value) else FACTORY)
	return out


static func is_default(mounts: Array) -> bool:
	return mounts.all(func(m: Variant) -> bool: return int(m) == FACTORY)


## The component ids really fitted, one per slot (0 = empty): the factory fit where `mounts` says 0.
static func make_fitted(v: Dictionary, mounts: Array) -> Array:
	var factory := make_factory(v)
	var out := []
	for i in factory.size():
		var value := int(mounts[i]) if i < mounts.size() and mounts[i] != null else FACTORY
		out.append(factory[i] if value == FACTORY else maxi(value, 0))
	return out


## The cloak a Herc `v` carries with `mounts` (CloakProfile.NONE when none).
static func make_cloak(v: Dictionary, mounts: Array) -> CloakProfile:
	if not has_slots(v):
		return CloakProfile.of_vehicle(str(v.get("id", "")), v)
	return CloakProfile.of_mountables(str(v.get("pack", "")), make_fitted(v, mounts))


## Puts `component_id` (FACTORY, EMPTIED or a cloak) in slot `slot_index` of `mounts`; false (unchanged) when it does not fit.
static func apply_set(v: Dictionary, mounts: Array, slot_index: int, component_id: int) -> bool:
	if mounts.size() != make_slots(v).size() or not is_allowed(v, slot_index, component_id):
		return false
	mounts[slot_index] = component_id
	return true


## "Chameleon Cloak", "Factory fit  (Shield Amplifier)" or "(empty)" for what slot `slot_index` holds under `value`.
static func make_label(v: Dictionary, slot_index: int, value: int) -> String:
	if value == EMPTIED:
		return "(empty)"
	if value == FACTORY:
		var factory := int(make_factory(v)[slot_index])
		return "Factory fit  (%s)" % make_part_name(v, factory) if factory > 0 else "Factory fit  (empty)"
	return make_part_name(v, value)


## The name of component `component_id`: the vehicle's own default part, else a cloak of its game.
static func make_part_name(v: Dictionary, component_id: int) -> String:
	for m in v.get("default_mountables", []):
		if int(m.get("id", 0)) == component_id:
			return str(m.get("name", component_id))
	var p := CloakProfile.of_component(str(v.get("pack", "")), component_id)
	return p.display_name if p.is_real() else str(component_id)


## One row per slot for a loadout list: {key "mount:<i>", label, size, current, options [{id, name, size, mass_t}]}.
static func make_rows(v: Dictionary, mounts: Array) -> Array:
	var rows := []
	var pack_name := str(v.get("pack", ""))
	for s in make_slots(v):
		var i := int(s.index)
		var opts := [{"id": FACTORY, "name": make_label(v, i, FACTORY), "size": "", "mass_t": 0.0},
			{"id": EMPTIED, "name": make_label(v, i, EMPTIED), "size": "", "mass_t": 0.0}]
		for p in make_options(v, i):
			opts.append({"id": (p as CloakProfile).component_id_of(pack_name), "name": p.display_name,
				"size": p.mount_size, "mass_t": p.mass_t})
		rows.append({"key": "mount:%d" % i, "label": "Component slot %d (%s)" % [i + 1, s.size], "size": s.size,
			"current": int(mounts[i]) if i < mounts.size() else FACTORY, "options": opts})
	return rows

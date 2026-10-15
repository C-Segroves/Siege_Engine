class_name ExtractionInventory
extends RefCounted
## What a soldier carries in a raid (docs/design/extraction.md section 4): item stacks (ExtractionItems ids) and
## money. The armour size limits it: slots (each started stack of up to the item's "stack" units takes one) and
## kilograms (ExtractionRules capacity). Money weighs nothing. The weapons in hand and the worn pack are items here
## too; rounds loaded in a weapon and hand items in the kit are not (ExtractionLoadout moves them in and out).
## Also the stash's and a cache's contents use the same stack form: [[id, count], ...] (make_stacks).

var stacks := {}         # item id -> count, insertion order kept
var money := 0
var max_slots := 10
var max_kg := 30.0


static func make_for_size(size: String) -> ExtractionInventory:
	var inv := ExtractionInventory.new()
	inv.apply_size(size)
	return inv


## Capacity of armour size `size` (light / medium / heavy).
func apply_size(size: String) -> void:
	var cap := ExtractionRules.capacity(size)
	max_slots = int(cap.get("slots", 10))
	max_kg = float(cap.get("kg", 30.0))


func count(id: String) -> int:
	return int(stacks.get(id, 0))


func is_empty() -> bool:
	return stacks.is_empty() and money <= 0


## Slots in use: one per started stack of each item.
func make_used_slots() -> int:
	var used := 0
	for id in stacks:
		used += make_slots_for(id, count(id))
	return used


static func make_slots_for(id: String, units: int) -> int:
	var per := maxi(int(ExtractionItems.item(id).get("stack", 1)), 1)
	return int(ceil(float(units) / float(per)))


func make_used_kg() -> float:
	var kg := 0.0
	for id in stacks:
		kg += float(ExtractionItems.item(id).get("kg", 0.0)) * count(id)
	return kg


## How many units of `id` fit (by slots and weight), at most `wanted`.
func make_room_for(id: String, wanted: int) -> int:
	var rec := ExtractionItems.item(id)
	if rec.is_empty() or wanted <= 0:
		return 0
	var kg := float(rec.get("kg", 0.0))
	var by_weight := wanted if kg <= 0.0 else int(floor((max_kg - make_used_kg()) / kg + 0.0001))
	var per := maxi(int(rec.get("stack", 1)), 1)
	var other_slots := make_used_slots() - make_slots_for(id, count(id))
	var by_slots := (max_slots - other_slots) * per - count(id)
	return maxi(mini(wanted, mini(by_weight, by_slots)), 0)


## Adds as many of `units` of `id` as fit; returns how many were taken.
func apply_add(id: String, units: int) -> int:
	var n := make_room_for(id, units)
	if n > 0:
		stacks[id] = count(id) + n
	return n


## Adds `units` of `id` whatever the capacity (rounds unloaded from a weapon, the stash).
func apply_add_unchecked(id: String, units: int) -> void:
	if units > 0 and ExtractionItems.has(id):
		stacks[id] = count(id) + units


## Removes up to `units` of `id`; returns how many were removed.
func apply_take(id: String, units: int) -> int:
	var n := mini(units, count(id))
	if n <= 0:
		return 0
	stacks[id] = count(id) - n
	if int(stacks[id]) <= 0:
		stacks.erase(id)
	return n


## Puts `id` first in the stack order (what the soldier carries in hand / wears is read in this order).
func apply_move_to_front(id: String) -> void:
	if not stacks.has(id):
		return
	var rest := stacks.duplicate()
	rest.erase(id)
	var n := count(id)
	stacks.clear()
	stacks[id] = n
	stacks.merge(rest)


func apply_clear() -> void:
	stacks.clear()
	money = 0


## The stacks as [[id, count], ...] (the network and save form).
func make_stacks() -> Array:
	var out := []
	for id in stacks:
		out.append([id, count(id)])
	return out


## Replaces the stacks with `list` ([[id, count], ...]); unknown items are dropped.
func apply_stacks(list: Array) -> void:
	stacks.clear()
	for e in list:
		if e is Array and e.size() >= 2:
			apply_add_unchecked(str(e[0]), int(e[1]))


## Merges `list` into the stacks without capacity checks.
func apply_merge(list: Array) -> void:
	for e in list:
		if e is Array and e.size() >= 2:
			apply_add_unchecked(str(e[0]), int(e[1]))


## {stacks, money, slots, kg}: what the owner's HUD shows (sent host -> owner).
func make_state() -> Dictionary:
	return {"stacks": make_stacks(), "money": money, "slots": max_slots, "kg": max_kg}


func apply_state(state: Dictionary) -> void:
	apply_stacks(state.get("stacks", []))
	money = int(state.get("money", 0))
	max_slots = int(state.get("slots", max_slots))
	max_kg = float(state.get("kg", max_kg))


## Credits the items would sell for, plus the money.
func make_value() -> int:
	var total := money
	for id in stacks:
		total += ExtractionItems.make_sell_price(id, count(id))
	return total


## Free kilograms and slots: "Can carry 4.2 kg more, 2 slots free".
func make_capacity_text() -> String:
	var slots := maxi(max_slots - make_used_slots(), 0)
	return "Can carry %.1f kg more, %d slot%s free" % [maxf(max_kg - make_used_kg(), 0.0), slots, "" if slots == 1 else "s"]


## True when one more unit of `id` would not fit.
func is_full_for(id: String) -> bool:
	return make_room_for(id, 1) < 1

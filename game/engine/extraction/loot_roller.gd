class_name LootRoller
extends RefCounted
## Rolls what a cache holds from the rules' loot tables (ExtractionRules "caches": rolls, money, category weights)
## over the item catalog of the installed packs (ExtractionItems), optionally limited to a pack set. Weapons and Herc
## salvage favour the weaker items (weight 1.25 - rating); a rolled weapon comes with part of a load of its ammo
## (ammo_loaded_fraction); armour rolls only the paid (medium / heavy) armours. Seeded: the host rolls a raid's caches once and sends the result.
## A cache: {"kind", "stacks": [[item id, count], ...], "money"}.

const STRONG_ITEM_DAMPING := 1.25
const GEAR_MAX := 3
const VALUABLE_MAX := 2
const AMMO_MIN_FRACTION := 0.3

var rng := RandomNumberGenerator.new()
## Packs the items may come from ([] = every installed pack).
var packs: Array = []


static func make(seed_value: int, p_packs: Array = []) -> LootRoller:
	var r := LootRoller.new()
	r.rng.seed = seed_value
	r.packs = p_packs
	return r


## A cache of `kind` (supply / armory / salvage) with its rolled contents.
func make_cache(kind: String) -> Dictionary:
	var rules := ExtractionRules.cache(kind)
	var inv := ExtractionInventory.new()
	for i in ExtractionRules.roll_range(rng, rules.get("rolls", [0, 0])):
		var category := make_weighted_key(rules.get("weights", {}))
		for stack in make_category_roll(category):
			inv.apply_add_unchecked(str(stack[0]), int(stack[1]))
	return {"kind": kind, "stacks": inv.make_stacks(), "money": ExtractionRules.roll_range(rng, rules.get("money", [0, 0]))}


## A key of `weights` ({key: weight}) drawn by weight ("" when empty).
func make_weighted_key(weights: Dictionary) -> String:
	var total := 0.0
	for k in weights:
		total += float(weights[k])
	var pick := rng.randf() * total
	for k in weights:
		pick -= float(weights[k])
		if pick <= 0.0:
			return str(k)
	return ""


## The stacks one roll of `category` yields ([] when the installed packs have no such item).
func make_category_roll(category: String) -> Array:
	var choices := ExtractionItems.items_of_kind(category, packs)
	if category == "valuable":
		choices = choices.filter(func(r: Dictionary) -> bool: return not bool(r.get("cybrid_only", false)) and not bool(r.get("task_only", false)))
	elif category in [ExtractionItems.ARMOR_KIND, "weapon"]:
		choices = choices.filter(func(r: Dictionary) -> bool: return int(r.get("price", 0)) > 0)   # standard issue is no find
	if choices.is_empty():
		return []
	var r := _pick(choices, category in ["weapon", "salvage"])
	match category:
		"weapon":
			return _make_weapon_roll(r)
		"ammo":
			return [[r.id, maxi(1, int(round(int(r.stack) * rng.randf_range(AMMO_MIN_FRACTION, 1.0))))]]
		"gear":
			return [[r.id, rng.randi_range(1, GEAR_MAX)]]
		"valuable":
			return [[r.id, rng.randi_range(1, VALUABLE_MAX)]]
	return [[r.id, 1]]


func _make_weapon_roll(r: Dictionary) -> Array:
	var out := [[r.id, 1]]
	var ammo_id := ExtractionItems.make_id("ammo", str(r.ref))
	if ExtractionItems.has(ammo_id):
		var fraction := float(ExtractionRules.data().get("ammo_loaded_fraction", 0.5))
		out.append([ammo_id, maxi(1, int(round(ExtractionItems.make_full_load(str(r.ref)) * fraction)))])
	return out


func _pick(choices: Array, damp_strong: bool) -> Dictionary:
	if not damp_strong:
		return choices[rng.randi_range(0, choices.size() - 1)]
	var weights := {}
	for i in choices.size():
		weights[i] = maxf(STRONG_ITEM_DAMPING - float(choices[i].get("rating", 0.5)), 0.05)
	return choices[int(make_weighted_key(weights))]

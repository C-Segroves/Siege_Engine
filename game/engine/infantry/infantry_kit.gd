class_name InfantryKit
extends RefCounted
## What a soldier carries besides his weapons (docs/formats/tribes_infantry.md section 6): hand items (the
## grenade type he chose, mines, repair kits: counts up to the armour's $ItemMax / max[]) and one backpack,
## switched on and off with pack_use when its effect is toggled (repair, shield, jammer).
## Counts follow the original limits; an ammo pack adds its extra rounds ($AmmoPackMax / AmmoPack max[]).

## Grenade id, else "" when he carries none.
var grenade_id := ""
var pack_id := ""
var pack_active := false
## Item id -> count.
var counts := {}
var _next_throw_ms := 0


## The spawn kit: the armour's default items (T1 $spawnBuyList, T2 DefaultGame::equip), no pack.
func apply_spawn(armor: Dictionary) -> void:
	pack_id = ""
	pack_active = false
	counts = (armor.get("default_items", {}) as Dictionary).duplicate()
	var grenades := InfantryGear.grenades_of(armor)
	grenade_id = ""
	for id in grenades:
		if int(counts.get(id, 0)) > 0:
			grenade_id = id
	if grenade_id == "" and not grenades.is_empty():
		grenade_id = grenades[0]


## An inventory purchase: `grenade` (one type, T2 maxGrenades 1) and `pack_choice`, every item full.
func apply_purchase(armor: Dictionary, grenade: String, pack_choice: String) -> void:
	pack_id = pack_choice if InfantryGear.packs_of(armor).has(pack_choice) else ""
	pack_active = false
	var grenades := InfantryGear.grenades_of(armor)
	grenade_id = grenade if grenades.has(grenade) else (grenades[0] if not grenades.is_empty() else "")
	counts.clear()
	for id in armor.get("hand_items", {}):
		if not bool(InfantryGear.item(id).get("mapped", false)):
			continue
		if grenades.has(id) and id != grenade_id:
			continue
		counts[id] = make_max_count(armor, id)


## The most of item `id` the soldier may carry: the armour's limit plus the ammo pack's extra.
func make_max_count(armor: Dictionary, id: String) -> int:
	return int((armor.get("hand_items", {}) as Dictionary).get(id, 0)) + make_extra_rounds(id)


## Extra rounds of weapon or item `id` the worn ammo pack holds (0 without one).
func make_extra_rounds(id: String) -> int:
	return int((InfantryGear.pack(pack_id).get("extra_rounds", {}) as Dictionary).get(id, 0))


func count(id: String) -> int:
	return int(counts.get(id, 0))


## The first mine the armour carries ("" when it carries none).
static func make_mine_id(armor: Dictionary) -> String:
	for id in InfantryGear.thrown_items_of(armor):
		if InfantryGear.item(id).kind == InfantryGear.KIND_MINE:
			return id
	return ""


## The repair kit id of the armour ("" when none).
static func make_repair_kit_id(armor: Dictionary) -> String:
	for id in armor.get("hand_items", {}):
		if InfantryGear.item(id).get("kind", "") == InfantryGear.KIND_REPAIR_KIT:
			return id
	return ""


## Takes one of item `id` (the caller checked count() > 0).
func apply_take(id: String) -> void:
	counts[id] = maxi(count(id) - 1, 0)


## True when the throw timeout of the last throw has passed (T1 throwTime 0.5 s, T2 $HandInvThrowTimeout).
func is_throw_ready(now_ms: int) -> bool:
	return now_ms >= _next_throw_ms


func apply_throw_timeout(now_ms: int, seconds: float) -> void:
	_next_throw_ms = now_ms + int(seconds * 1000.0)


## One ammo-station step: every carried thrown item and repair kit gains `rounds`, up to its maximum.
func apply_resupply(armor: Dictionary, rounds: int) -> void:
	for id in armor.get("hand_items", {}):
		if counts.has(id) or id == make_mine_id(armor):
			counts[id] = mini(count(id) + rounds, make_max_count(armor, id))


func is_pack_toggled() -> bool:
	return bool(InfantryGear.pack(pack_id).get("toggled", false))


## [grenade id, pack id, pack active, counts]: the snapshot / kit message form.
func make_state() -> Array:
	return [grenade_id, pack_id, pack_active, counts.duplicate()]


func apply_state(state: Array) -> void:
	if state.size() < 4:
		return
	grenade_id = str(state[0])
	pack_id = str(state[1])
	pack_active = bool(state[2])
	counts = (state[3] as Dictionary).duplicate()

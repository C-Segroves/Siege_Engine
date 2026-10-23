class_name ExtractionProfile
extends RefCounted
## A pilot's extraction-mode profile (docs/design/extraction.md section 6), saved with SaveGames as
## user://saves/profiles/extraction_<pilot>.json:
##   money      credits
##   stash      what he owns between raids (stacks, no capacity limit; medium / heavy armours as armor/ items)
##   kit        the raid loadout: the worn armour and the items he takes along (limited by that armour's capacity);
##              a paid armour leaves the stash while it is worn, light armour is free (ExtractionItems.is_free_armor)
##   insured    the insured slot (in the kit): one kit stack (at most one slot of it) or the worn paid armour,
##              [item id, units] or []
##   tasks      the pre-raid tasks taken from the board (RaidTaskBoard; at most max_picked), in the kit
##   task_board the board on offer until the next raid starts (a new one after each raid)
##   last_kit   the kit of the last raid (Re-equip moves what the stash still has back into the kit)
##   stats      raids, extracted, died, earned
## A raid spends the kit and the worn armour when it starts (apply_commit_kit): what the soldier brings out goes to
## the stash (apply_extracted); dying loses it except the insured stack (apply_died). Each peer keeps its own profile;
## the kit travels to the host in the lobby roster. Version 1 files (armour was free to pick) migrate on load: the
## armour they wear stays worn and their last raid's armour becomes owned (_apply_migration_v1).

const VERSION := 2
const ID_PREFIX := "extraction_"
const STARTER_AMMO_LOADS := 2
const STARTER_GRENADES := 3

var pilot := SaveGames.DEFAULT_PILOT
var money := 0
var stash := ExtractionInventory.new()
var kit_armor := ""
var kit := ExtractionInventory.new()
var insured: Array = []
var tasks: Array = []
var task_board: Array = []
var last_kit := {}
var stats := {"raids": 0, "extracted": 0, "died": 0, "earned": 0}


static func make_id(pilot_name: String) -> String:
	return ID_PREFIX + SaveGames.make_slug(pilot_name)


## The saved profile of `pilot_name`, else a new one (starting money and the starter kit; not written until saved).
static func load_for(pilot_name: String) -> ExtractionProfile:
	var d := SaveGames.read_profile(make_id(pilot_name))
	var p := ExtractionProfile.new()
	if d.is_empty():
		p.apply_new(pilot_name)
	else:
		p.apply_dict(d)
		p.pilot = pilot_name
	var operator := OperatorProfile.load_for(pilot_name)
	p.apply_slot_armor(operator)
	p.money = operator.credits   # one wallet: the operator's credits (the file's own "money" is only the old copy)
	return p


func save() -> bool:
	return SaveGames.write_profile(make_id(pilot), to_dict())


func apply_new(pilot_name: String) -> void:
	pilot = pilot_name
	money = EconomyRules.start_credits()
	_wear_armor(make_free_armor_id())
	for stack in make_starter_stacks(InfantryCatalog.armor(kit_armor)):
		kit.apply_add(str(stack[0]), int(stack[1]))


## The standard-issue light armour of the first infantry pack.
static func make_free_armor_id() -> String:
	return InfantryCatalog.light_armor_id(InfantryCatalog.make_default_pack())


## The starter kit of `armor`: its spawn weapons with two loads of ammunition, grenades and its repair kit.
static func make_starter_stacks(armor: Dictionary) -> Array:
	var out := []
	for wid in armor.get("default_loadout", []):
		out.append([ExtractionItems.make_id("weapon", str(wid)), 1])
		var load := int((armor.get("ammo", {}) as Dictionary).get(wid, 0))
		if load > 0:
			out.append([ExtractionItems.make_id("ammo", str(wid)), load * STARTER_AMMO_LOADS])
	for id in InfantryGear.grenades_of(armor).slice(0, 1):
		out.append([ExtractionItems.make_id("gear", str(id)), STARTER_GRENADES])
	var repair := InfantryKit.make_repair_kit_id(armor)
	if repair != "":
		out.append([ExtractionItems.make_id("gear", repair), 1])
	return out.filter(func(s: Array) -> bool: return ExtractionItems.has(str(s[0])))


# ------------------------------------------------------------------ the kit

## The armours he may wear next raid: every free light armour, the paid ones in his stash and the one he wears.
func make_wearable_armors() -> Array:
	var out := []
	for pack in InfantryCatalog.INFANTRY_PACKS:
		for a in InfantryCatalog.armors_of(pack):
			var id := str(a.id)
			if ExtractionItems.is_free_armor(id) or id == kit_armor or stash.count(ExtractionItems.make_armor_id(id)) > 0:
				out.append(id)
	return out


## Wears `armor_id` in the next raid (a paid armour comes out of the stash, the one worn before goes back); what no
## longer fits in the kit goes to the stash. False when he does not own it.
func apply_kit_armor(armor_id: String) -> bool:
	if armor_id == kit_armor:
		return true
	var item_id := ExtractionItems.make_armor_id(armor_id)
	if InfantryCatalog.armor(armor_id).is_empty() or (not ExtractionItems.is_free_armor(armor_id) and stash.count(item_id) < 1):
		return false
	if kit_armor != "" and not ExtractionItems.is_free_armor(kit_armor):
		stash.apply_add_unchecked(ExtractionItems.make_armor_id(kit_armor), 1)
	stash.apply_take(item_id, 1)
	_wear_armor(armor_id)
	return true


## The raid kit wears the armour of the operator's active character slot (docs/design/lobby_loadout_economy.md section 4.2): the
## slot's own armour when a raider may field it (free in a raid, or bought and not lost), else free light armour. The stash is
## not touched: a bought armour is an unlock of the operator now, not an item.
func apply_slot_armor(operator: OperatorProfile) -> void:
	var armor_id := operator.make_active_slot().armor
	var unlock_id := UnlockId.make("armor", armor_id)
	var usable := not InfantryCatalog.armor(armor_id).is_empty() and (FreeUnlocks.is_free_in_raid(unlock_id) or operator.unlocks.owned.has(unlock_id))
	var wanted := armor_id if usable else make_free_armor_id()
	if wanted != kit_armor:
		_wear_armor(wanted)


## Puts on `armor_id` without touching the stash: the kit takes its capacity, the overflow goes to the stash.
func _wear_armor(armor_id: String) -> void:
	kit_armor = armor_id
	var keep := kit.make_stacks()
	kit = ExtractionInventory.make_for_size(str(InfantryCatalog.armor(armor_id).get("size", "light")))
	for s in keep:
		var n := kit.apply_add(str(s[0]), int(s[1]))
		stash.apply_add_unchecked(str(s[0]), int(s[1]) - n)
	_apply_insured_fit()


## Moves up to `units` of `id` from the stash into the kit (as far as it fits); returns how many moved.
func apply_move_to_kit(id: String, units: int) -> int:
	var n := kit.apply_add(id, mini(units, stash.count(id)))
	stash.apply_take(id, n)
	return n


func apply_move_to_stash(id: String, units: int) -> int:
	var n := kit.apply_take(id, units)
	stash.apply_add_unchecked(id, n)
	_apply_insured_fit()
	return n


## Makes the kit hold `wanted` units of `id`: the difference comes from the stash (as far as it has and the kit has
## room) or goes back to it. Standard-issue items are never stashed. Returns how many the kit holds afterwards.
func apply_set_kit_count(id: String, wanted: int) -> int:
	var have := kit.count(id)
	if wanted > have:
		var supply := 1000000 if ExtractionItems.is_standard_issue(id) else stash.count(id)
		var n := kit.apply_add(id, mini(wanted - have, supply))
		if not ExtractionItems.is_standard_issue(id):
			stash.apply_take(id, n)
	elif wanted < have:
		if ExtractionItems.is_standard_issue(id):
			kit.apply_take(id, have - wanted)
			_apply_insured_fit()
		else:
			apply_move_to_stash(id, have - wanted)
	return kit.count(id)


## Moves the last raid's kit back from the stash, as much as the stash still holds, and insures what it insured.
func apply_refill_last_kit() -> void:
	if str(last_kit.get("armor", "")) != "":
		apply_kit_armor(str(last_kit.armor))
	for s in last_kit.get("items", []):
		apply_move_to_kit(str(s[0]), int(s[1]) - kit.count(str(s[0])))
	var last_insured: Array = last_kit.get("insured", []) if last_kit.get("insured") is Array else []
	if last_insured.size() >= 2:
		apply_insure(str(last_insured[0]))


## The kit as the lobby roster carries it: {armor, items: [[id, count], ...], insured: [id, units] or [], tasks}.
func make_kit_dict() -> Dictionary:
	return {"armor": kit_armor, "items": kit.make_stacks(), "insured": insured.duplicate(), "tasks": tasks.duplicate(true)}


# ------------------------------------------------------------------ pre-raid tasks

## The board on offer (made once per raid: RaidTaskBoard.make_board, seeded by the clock).
func make_task_board() -> Array:
	if task_board.is_empty():
		task_board = RaidTaskBoard.make_board(int(Time.get_unix_time_from_system()))
	return task_board


func is_task_taken(task_id: String) -> bool:
	return tasks.any(func(t: Dictionary) -> bool: return str(t.id) == task_id)


## Takes board task `task_id` (up to RaidTaskBoard.make_max_picked); false when it is not on the board or the
## limit is reached.
func apply_take_task(task_id: String) -> bool:
	if is_task_taken(task_id) or tasks.size() >= RaidTaskBoard.make_max_picked():
		return false
	for t in make_task_board():
		if str(t.id) == task_id:
			tasks.append(t.duplicate())
			return true
	return false


func apply_drop_task(task_id: String) -> void:
	tasks = tasks.filter(func(t: Dictionary) -> bool: return str(t.id) != task_id)


# ------------------------------------------------------------------ the insured slot

## Insures `id`: the worn paid armour, or a kit item (at most one slot of it). False when it cannot be insured.
func apply_insure(id: String) -> bool:
	if id == ExtractionItems.make_armor_id(kit_armor) and not ExtractionItems.is_free_armor(kit_armor):
		insured = [id, 1]
		return true
	if kit.count(id) <= 0:
		return false
	insured = [id, mini(kit.count(id), make_slot_units(id))]
	return true


## Insures the at-risk unlock `id` (a paid skin, body, armour or vehicle of OperatorProfile.at_risk) instead of a kit
## item: the one insured slot holds either (docs/design/lobby_loadout_economy.md section 4.1). False when `id` is not a
## look unlock or is not among `at_risk`.
func apply_insure_unlock(id: String, at_risk: Array) -> bool:
	if not UnlockId.LOOK_KINDS.has(UnlockId.kind_of(id)) or not at_risk.has(id):
		return false
	insured = [id, 1]
	return true


## The insured unlock id ("" when the slot holds nothing or a kit item).
func make_insured_unlock_id() -> String:
	var id := make_insured_id()
	return id if id != "" and is_unlock_id(id) else ""


## True when `id` is a look unlock other than armour (kit armour stays on the stash path of apply_insure).
static func is_unlock_id(id: String) -> bool:
	var kind := UnlockId.kind_of(id)
	return kind != ExtractionItems.ARMOR_KIND and UnlockId.LOOK_KINDS.has(kind)


func apply_uninsure() -> void:
	insured = []


## The insured item id ("" = the slot is empty).
func make_insured_id() -> String:
	return make_insured_id_of(insured)


## The item id of an insured slot [id, units] ("" when empty).
static func make_insured_id_of(slot: Array) -> String:
	return str(slot[0]) if slot.size() >= 2 else ""


## Units of `id` one inventory slot holds: the most the insured slot keeps.
static func make_slot_units(id: String) -> int:
	return maxi(int(ExtractionItems.item(id).get("stack", 1)), 1)


## The insured slot follows the kit: emptied when its item left the kit, cut to what the kit still holds.
func _apply_insured_fit() -> void:
	var id := make_insured_id()
	if id == "":
		return
	if ExtractionItems.kind_of(id) == ExtractionItems.ARMOR_KIND:
		if id != ExtractionItems.make_armor_id(kit_armor):
			insured = []
		return
	if is_unlock_id(id):
		return   # an unlock, not a kit item: it stays insured while it is at risk
	if kit.count(id) <= 0:
		insured = []
	else:
		insured = [id, mini(int(insured[1]), kit.count(id))]


# ------------------------------------------------------------------ raids

## The raid starts: the kit and the worn armour go into it (he wears free light armour until it comes back).
func apply_commit_kit() -> void:
	last_kit = make_kit_dict()
	kit.apply_clear()
	insured = []
	tasks = []
	task_board = []
	_wear_armor(make_free_armor_id())
	stats.raids = int(stats.get("raids", 0)) + 1


## Back from a raid with `stacks` (his worn armour among them) and `p_money`; he wears that armour again.
func apply_extracted(stacks: Array, p_money: int) -> void:
	var brought := ExtractionInventory.new()
	brought.apply_merge(stacks)
	brought.apply_take(ExtractionItems.make_armor_id(str(last_kit.get("armor", ""))), 1)   # his own armour is no gain
	brought.money = p_money
	stash.apply_merge(stacks)   # the credits are paid into the operator's wallet (RaidOperator.apply_survived)
	stats.extracted = int(stats.get("extracted", 0)) + 1
	stats.earned = int(stats.get("earned", 0)) + brought.make_value()
	_apply_rewear()


## Killed in a raid: only `kept` (the insured stack) comes back.
func apply_died(kept: Array = []) -> void:
	stash.apply_merge(kept)
	stats.died = int(stats.get("died", 0)) + 1
	_apply_rewear()


## Puts the last raid's armour back on when it came home.
func _apply_rewear() -> void:
	var armor_id := str(last_kit.get("armor", ""))
	if armor_id != "" and not ExtractionItems.is_free_armor(armor_id):
		apply_kit_armor(armor_id)


# ------------------------------------------------------------------ save form

func to_dict() -> Dictionary:
	return {"version": VERSION, "pilot": pilot, "money": money, "stash": stash.make_stacks(), "kit": make_kit_dict(),
		"last_kit": last_kit, "stats": stats, "task_board": task_board}


func apply_dict(d: Dictionary) -> void:
	pilot = str(d.get("pilot", SaveGames.DEFAULT_PILOT))
	money = int(d.get("money", 0))
	stash.apply_stacks(d.get("stash", []))
	var k: Dictionary = d.get("kit", {}) if d.get("kit") is Dictionary else {}
	var armor_id := str(k.get("armor", ""))
	if InfantryCatalog.armor(armor_id).is_empty():
		armor_id = make_free_armor_id()
	_wear_armor(armor_id)
	kit.apply_stacks(k.get("items", []))
	last_kit = d.get("last_kit", {}) if d.get("last_kit") is Dictionary else {}
	var slot: Array = k.get("insured", []) if k.get("insured") is Array else []
	insured = [str(slot[0]), int(slot[1])] if slot.size() >= 2 else []   # JSON numbers come back as floats
	_apply_insured_fit()
	tasks = (k.get("tasks", []) as Array).duplicate(true) if k.get("tasks") is Array else []
	task_board = (d.get("task_board", []) as Array).duplicate(true) if d.get("task_board") is Array else []
	for t in tasks + task_board:
		t["count"] = int(t.get("count", 1))   # JSON numbers come back as floats
		t["reward"] = int(t.get("reward", 0))
	if d.get("stats") is Dictionary:
		for key in d.stats:
			stats[key] = int(d.stats[key])
	if int(d.get("version", 1)) < 2:
		_apply_migration_v1()


## Version 1 let any armour be picked for free: the worn one stays worn (owned), and the last raid's armour, when
## another paid one, becomes owned in the stash.
func _apply_migration_v1() -> void:
	var last := str(last_kit.get("armor", ""))
	if last != "" and last != kit_armor and not InfantryCatalog.armor(last).is_empty() and not ExtractionItems.is_free_armor(last):
		stash.apply_add_unchecked(ExtractionItems.make_armor_id(last), 1)

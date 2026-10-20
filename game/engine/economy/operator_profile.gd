class_name OperatorProfile
extends RefCounted
## The operator's save file (docs/design/lobby_loadout_economy.md section 2.4): the credits wallet, the unlocks, three
## character slots, and what a running extraction raid has put at risk. One file per pilot name,
## user://saves/profiles/operator_<slug>.json (SaveGames). A profile with no file is new: start credits, free slots,
## and whatever the older stores hold (ProfileMigration: loadout presets, player settings, the extraction profile).

const VERSION := 1
const ID_PREFIX := "operator_"

var pilot := ""
var credits := 0
var unlocks := Unlocks.new()
var slots: Array = []
var active_slot := 0
var at_risk: Array = []
## Raid points (RP): the extraction call-in currency. Carries over between raids up to the cap, is lost with the operator on
## death and never turns into credits (user answer O8, economy option "o8_raid_points").
var raid_points := 0
## True from the start of a raid until its result: a raid that was left counts as a death.
var raid_open := false
var stats := {"matches": 0, "earned": 0, "spent": 0, "unlocks_lost": 0, "bought_back": 0}
var migrated: Array = []


static func make_id(pilot_name: String) -> String:
	return ID_PREFIX + SaveGames.make_slug(pilot_name)


static func is_saved(pilot_name: String) -> bool:
	return not SaveGames.read_profile(make_id(pilot_name)).is_empty()


## The saved profile of `pilot_name`, else a new one (not written until saved).
static func load_for(pilot_name: String) -> OperatorProfile:
	var d := SaveGames.read_profile(make_id(pilot_name))
	var p := OperatorProfile.new()
	if d.is_empty():
		p.apply_new(pilot_name)
	else:
		p.apply_dict(d)
		p.pilot = pilot_name
	ProfileMigration.apply_all(p)
	return p


func save() -> bool:
	return SaveGames.write_profile(make_id(pilot), to_dict())


func apply_new(pilot_name: String) -> void:
	pilot = pilot_name
	credits = EconomyRules.start_credits()
	unlocks = Unlocks.new()
	active_slot = 0
	at_risk = []
	slots = []
	for i in EconomyRules.slot_count():
		slots.append(CharacterSlot.make_default(i))


func make_active_slot() -> CharacterSlot:
	return slots[clampi(active_slot, 0, slots.size() - 1)]


func apply_select_slot(i: int) -> void:
	active_slot = clampi(i, 0, slots.size() - 1)


# ------------------------------------------------------------------ credits

## Pays the award `CreditsLedger.make_award` made.
func apply_award(award: Dictionary) -> void:
	var total := maxi(int(award.get("total", 0)), 0)
	credits += total
	stats.earned = int(stats.get("earned", 0)) + total
	stats.matches = int(stats.get("matches", 0)) + 1


func is_affordable(price: int) -> bool:
	return price >= 0 and credits >= price


## Takes `price` from the wallet; false (nothing changes) when it is short.
func apply_spend(price: int) -> bool:
	if not is_affordable(price):
		return false
	credits -= price
	stats.spent = int(stats.get("spent", 0)) + price
	return true


# ------------------------------------------------------------------ extraction risk

## The unlock ids the active slot puts at risk when a raid starts: its paid armour, body and skin, and (open question
## O4, "raid_start") its vehicle. A vehicle is otherwise committed when it is called in (apply_commit_risk).
func make_raid_start_risk(_ctx: LoadoutContext) -> Array:
	var s := make_active_slot()
	var ids := [UnlockId.make("armor", s.armor)]
	var shown := s.body if s.body != "" else PlayerProfile.make_default_body(s.armor)
	if s.body != "":
		ids.append(UnlockId.make("body", s.body))
	if s.skin != "":
		ids.append(UnlockId.make("skin", UnlockId.make_skin_ref(shown, s.skin)))
	if str(EconomyRules.option("o4_vehicle_risk")) == "raid_start" and s.vehicle != "":
		ids.append(UnlockId.make("vehicle", s.vehicle))
	return ids.filter(func(id: String) -> bool: return not FreeUnlocks.is_free_in_raid(id) and unlocks.owned.has(id))


## Commits unlock ids to the running raid (what a raider wears for free, per FreeUnlocks.is_free_in_raid, is never at risk;
## bought Medium and Heavy armour is).
func apply_commit_risk(ids: Array) -> void:
	for id in ids:
		if not FreeUnlocks.is_free_in_raid(str(id)) and unlocks.owned.has(str(id)) and not at_risk.has(str(id)):
			at_risk.append(str(id))


func apply_raid_survived() -> void:
	at_risk = []
	raid_open = false


## Killed in the raid: the at-risk unlocks except the `insured` ones are lost (bought back for the rebuy price).
## Returns the lost ids.
func apply_raid_lost(insured: Array) -> Array:
	var lost_ids := []
	for id in at_risk:
		if not insured.has(id):
			unlocks.apply_lose(str(id))
			lost_ids.append(id)
	stats.unlocks_lost = int(stats.get("unlocks_lost", 0)) + lost_ids.size()
	at_risk = []
	raid_open = false
	if bool(make_raid_points_rules().get("lost_on_death", true)):
		raid_points = 0
	return lost_ids


## A raid that was left (the game closed) counts as a death: call once when the lobby opens. Returns the lost ids.
func apply_resolve_abandoned() -> Array:
	return apply_raid_lost([]) if raid_open or not at_risk.is_empty() else []


# ------------------------------------------------------------------ save form

func to_dict() -> Dictionary:
	var slot_dicts := []
	for s in slots:
		slot_dicts.append((s as CharacterSlot).to_dict())
	return {"version": VERSION, "pilot": pilot, "credits": credits, "active_slot": active_slot,
		"unlocks": unlocks.make_owned_ids(), "lost": unlocks.make_lost_ids(), "at_risk": at_risk.duplicate(), "raid_points": raid_points, "raid_open": raid_open,
		"slots": slot_dicts, "stats": stats.duplicate(), "migrated": migrated.duplicate()}


func apply_dict(d: Dictionary) -> void:
	pilot = str(d.get("pilot", SaveGames.DEFAULT_PILOT))
	credits = int(d.get("credits", 0))   # JSON numbers come back as floats
	active_slot = int(d.get("active_slot", 0))
	unlocks = Unlocks.new()
	unlocks.apply_ids(_strings(d.get("unlocks", [])), _strings(d.get("lost", [])))
	at_risk = _strings(d.get("at_risk", []))
	raid_points = maxi(int(d.get("raid_points", 0)), 0)
	raid_open = bool(d.get("raid_open", false))
	migrated = _strings(d.get("migrated", []))
	if d.get("stats") is Dictionary:
		for key in d.stats:
			stats[key] = int(d.stats[key])
	slots = []
	var saved: Array = d.get("slots", []) if d.get("slots") is Array else []
	for i in EconomyRules.slot_count():
		if i < saved.size() and saved[i] is Dictionary:
			var s := CharacterSlot.new()
			s.apply_dict(saved[i])
			s.index = i
			slots.append(s)
		else:
			slots.append(CharacterSlot.make_default(i))
	apply_select_slot(active_slot)


static func _strings(list: Variant) -> Array:
	return (list as Array).map(func(x: Variant) -> String: return str(x)) if list is Array else []


# ------------------------------------------------------------------ raid points

## The raid-points policy (economy option o8_raid_points): {max, carry_over, lost_on_death, to_credits}.
static func make_raid_points_rules() -> Dictionary:
	var o = EconomyRules.option("o8_raid_points")
	return o if o is Dictionary else {}


## The most raid points an operator may hold (the economy option; the extraction rules' default without it).
static func make_raid_points_cap() -> int:
	return int(make_raid_points_rules().get("max", CallinRules.points().get("default_max", 1000)))


## A raid begins: the operator is committed to it (leaving it is a death at the next load).
func apply_raid_begin() -> void:
	raid_open = true


## The raid points he starts a raid with: all he kept when they carry over, else none.
func make_raid_points_start() -> int:
	var carry := bool(make_raid_points_rules().get("carry_over", true))
	return mini(raid_points, make_raid_points_cap()) if carry else 0


## Sets the balance (cut to 0..cap).
func apply_raid_points(amount: int) -> void:
	raid_points = clampi(amount, 0, make_raid_points_cap())

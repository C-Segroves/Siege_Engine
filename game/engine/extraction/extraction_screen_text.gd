class_name ExtractionScreenText
extends RefCounted
## Texts about an extraction profile shared by the stash screen and the LAN lobby.


## "Scout (light) armor (Tribes 2) - 6 kinds of item, 21.5 / 30 kg, 7 / 10 slots".
static func make_kit_summary(profile: ExtractionProfile) -> String:
	return "%s  -  %d kinds of item, %.1f / %.0f kg, %d / %d slots" % [make_armor_name(profile.kit_armor), profile.kit.stacks.size(),
		profile.kit.make_used_kg(), profile.kit.max_kg, profile.kit.make_used_slots(), profile.kit.max_slots]


## "Insured slot: Disc Launcher (kept if you die)" / "Insured slot: empty - Insure one kit item or your armour".
static func make_insured_text(profile: ExtractionProfile) -> String:
	var id := profile.make_insured_id()
	if id == "":
		return "Insured slot: empty  -  insure one kit item (one slot of it) or your paid armour to keep it if you die"
	return "Insured slot: %s  (kept if you die)" % ExtractionItems.make_stack_text(id, int(profile.insured[1]))


## "  -  free" after a standard-issue armour's name, else "".
static func make_armor_cost_text(armor_id: String) -> String:
	return "  -  free" if ExtractionItems.is_free_armor(armor_id) else ""


## "Scout (light) armor (Tribes 2)".
static func make_armor_name(armor_id: String) -> String:
	var a := InfantryCatalog.armor(armor_id)
	if a.is_empty():
		return "no armour"
	return "%s (%s)" % [str(a.get("name", armor_id)), Packs.pack_name(str(a.get("pack", "")))]


## "Pilot IRONSIDE - 4 250 cr - raids 3, extracted 2, killed 1, earned 6 100 cr".
static func make_profile_summary(profile: ExtractionProfile) -> String:
	var st := profile.stats
	return "Pilot %s  -  %s  -  raids %d, extracted %d, killed %d, earned %s" % [profile.pilot,
		ExtractionRules.make_money_text(profile.money), int(st.get("raids", 0)), int(st.get("extracted", 0)),
		int(st.get("died", 0)), ExtractionRules.make_money_text(int(st.get("earned", 0)))]


## "6 kg  -  sells for 150 cr".
static func make_item_detail(id: String, units: int) -> String:
	return "%.1f kg  -  sells for %s" % [float(ExtractionItems.item(id).get("kg", 0.0)) * units,
		ExtractionRules.make_money_text(ExtractionItems.make_sell_price(id, units))]


## "Tasks taken: 1 / 2 - Map flags and generators only count on maps that have them".
static func make_tasks_summary(profile: ExtractionProfile) -> String:
	return "Tasks taken: %d / %d  -  a task the raid's map cannot hold (no base, no flag) is void" % [profile.tasks.size(),
		RaidTaskBoard.make_max_picked()]

class_name ExtractionScreenText
extends RefCounted
## Texts about an extraction profile, shared by Operator Setup's stash tab and the lobby.


## "Scout (light) armor (Tribes 2) - 6 kinds of item, 21.5 / 30 kg, 7 / 10 slots".
static func make_kit_summary(profile: ExtractionProfile) -> String:
	return "%s  -  %d kinds of item, %.1f / %.0f kg, %d / %d slots" % [make_armor_name(profile.kit_armor), profile.kit.stacks.size(),
		profile.kit.make_used_kg(), profile.kit.max_kg, profile.kit.make_used_slots(), profile.kit.max_slots]


## "Insured slot: Disc Launcher (kept if you die)" / "Insured slot: empty - Insure one kit item or your armour".
static func make_insured_text(profile: ExtractionProfile) -> String:
	var id := profile.make_insured_id()
	if id == "":
		return "Insured slot: empty  -  pick one kit item (one slot of it) or your paid armour under Insured in the Loadout list to keep it if you die"
	return "Insured slot: %s  (kept if you die)" % ExtractionItems.make_stack_text(id, int(profile.insured[1]))



## "Scout (light) armor (Tribes 2)".
static func make_armor_name(armor_id: String) -> String:
	var a := InfantryCatalog.armor(armor_id)
	if a.is_empty():
		return "no armour"
	return "%s (%s)" % [str(a.get("name", armor_id)), Packs.pack_name(str(a.get("pack", "")))]



## "6 kg  -  sells for 150 cr".
static func make_item_detail(id: String, units: int) -> String:
	if ExtractionItems.is_standard_issue(id):
		return "%.1f kg  -  standard issue: free, never lost" % (float(ExtractionItems.item(id).get("kg", 0.0)) * units)
	return "%.1f kg  -  sells for %s" % [float(ExtractionItems.item(id).get("kg", 0.0)) * units,
		ExtractionRules.make_money_text(ExtractionItems.make_sell_price(id, units))]

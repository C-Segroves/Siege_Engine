class_name InsuredRow
extends RefCounted
## The raid's insured slot as a loadout row (docs/design/lobby_loadout_economy.md section 4.1): one kit stack or one worn paid
## look unlock survives a death. Row key "insured"; the choices are none, the kit's stacks and the worn unlocks at risk.
## Pure data, in the shape ExtractionKitEditor rows have (so KitRow draws it).

const KEY := "insured"
const NONE_TEXT := "(none)"


## The row of `profile`; `at_risk` are the worn unlock ids the raid would put at risk (OperatorProfile.make_raid_start_risk).
static func make_row(profile: ExtractionProfile, at_risk: Array) -> Dictionary:
	var current := profile.make_insured_id()
	return {"key": KEY, "kind": KEY, "label": "Insured", "accepts": KEY, "current": current, "ammo": 0, "ammo_max": 0,
		"locked": false, "choices": make_choices(profile, at_risk), "choice": current}


## [{id, text}]: none first, then what can be insured.
static func make_choices(profile: ExtractionProfile, at_risk: Array) -> Array:
	var out := [{"id": "", "text": NONE_TEXT}]
	for id in profile.kit.stacks:
		if _is_insurable_stack(str(id)):
			out.append({"id": str(id), "text": ExtractionItems.make_stack_text(str(id), mini(profile.kit.count(str(id)), ExtractionProfile.make_slot_units(str(id))))})
	for id in at_risk:
		out.append({"id": str(id), "text": "%s  (worn)" % SlotCheck.make_name(str(id))})
	return out


## Insures `choice` (a choice id of make_choices; "" empties the slot); false when it cannot be insured.
static func apply_choice(profile: ExtractionProfile, at_risk: Array, choice: String) -> bool:
	if choice == "":
		profile.apply_uninsure()
		return true
	if at_risk.has(choice):
		return profile.apply_insure_unlock(choice, at_risk)
	return profile.apply_insure(choice)


static func _is_insurable_stack(id: String) -> bool:
	return ExtractionItems.kind_of(id) != ExtractionItems.ARMOR_KIND and not ExtractionItems.is_standard_issue(id)

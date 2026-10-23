class_name RaidOperator
extends RefCounted
## What a raid does to the local operator's save file (OperatorProfile; docs/design/lobby_loadout_economy.md sections 4
## and 9): it begins (the worn paid look is put at risk, the raid points come along), a called-in vehicle is put at risk
## when it first leaves the hangar, and the raid ends in extraction (nothing lost) or death (the at-risk unlocks the
## insured slot does not hold are lost, the raid points go). Each call loads the operator, changes it and saves it at
## once, on the machine of the player it concerns (the same trust model as the extraction kit).


## The raid starts for `pilot`: the active slot's paid look is committed to it and the raid is marked open. Returns the
## raid points he starts with.
static func apply_begin(pilot: String, settings: Dictionary) -> int:
	var profile := OperatorProfile.load_for(pilot)
	profile.apply_raid_begin()
	profile.apply_commit_risk(profile.make_raid_start_risk(LoadoutContext.make_for(settings, "player", profile.unlocks)))
	profile.save()
	return profile.make_raid_points_start()


## The called-in vehicle `vehicle_ref` ("es1:RAPTOR") left the hangar: it is at risk until the raid ends (open
## question O4, "on_call_in"). True when it was a paid vehicle that is now at risk.
static func apply_vehicle_risk(pilot: String, vehicle_ref: String) -> bool:
	var profile := OperatorProfile.load_for(pilot)
	var id := UnlockId.make("vehicle", vehicle_ref)
	profile.apply_commit_risk([id])
	profile.save()
	return profile.at_risk.has(id)


## The raid ended: extracted keeps everything, and the `money` he carried out (plus tasks and bonus) joins his credits.
static func apply_survived(pilot: String, money := 0) -> void:
	var profile := OperatorProfile.load_for(pilot)
	profile.apply_deposit(money)
	profile.apply_raid_survived()
	profile.save()


## The operator died: the at-risk unlocks except `insured` are lost and the raid points go. Returns the lost ids.
static func apply_died(pilot: String, insured: Array) -> Array:
	var profile := OperatorProfile.load_for(pilot)
	var lost := profile.apply_raid_lost(insured)
	profile.save()
	return lost


## Saves the raid-point balance `amount` for `pilot`.
static func apply_points(pilot: String, amount: int) -> void:
	var profile := OperatorProfile.load_for(pilot)
	profile.apply_raid_points(amount)
	profile.save()


## The raid points saved for `pilot`.
static func make_points(pilot: String) -> int:
	return OperatorProfile.load_for(pilot).raid_points


## True when `vehicle_ref` is usable by `pilot` for a delivery: free, or an unlock that is not lost.
static func is_vehicle_owned(pilot: String, vehicle_ref: String) -> bool:
	return OperatorProfile.load_for(pilot).unlocks.is_owned(UnlockId.make("vehicle", vehicle_ref))


## True when `vehicle_ref` was bought and then lost in a raid (the menu says so).
static func is_vehicle_lost(pilot: String, vehicle_ref: String) -> bool:
	return OperatorProfile.load_for(pilot).unlocks.is_lost(UnlockId.make("vehicle", vehicle_ref))


## The called-in vehicle was recalled (nobody came for it): it is no longer at risk.
static func apply_vehicle_recalled(pilot: String, vehicle_ref: String) -> void:
	var profile := OperatorProfile.load_for(pilot)
	profile.at_risk.erase(UnlockId.make("vehicle", vehicle_ref))
	profile.save()


## A short name for an unlock id: "Raptor", "Medium armour", "skin red".
static func make_unlock_text(id: String) -> String:
	var ref := UnlockId.ref_of(id)
	match UnlockId.kind_of(id):
		"vehicle":
			return str(Packs.vehicle(ref).get("name", ref))
		"armor":
			return "%s armour" % str(InfantryCatalog.armor(ref).get("name", ref))
	return "%s %s" % [UnlockId.kind_of(id), ref.get_slice("#", 1) if ref.contains("#") else ref]

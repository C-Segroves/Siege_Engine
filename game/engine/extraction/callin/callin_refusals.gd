class_name CallinRefusals
extends RefCounted
## Why a call-in cannot be made right now, from the facts that do not need the physics world (docs/design/lobby_loadout_economy.md
## section 9.3): the raid, the downed state, the raid points, the cooldowns, the caps, the orders on their way, the saved
## vehicle. The host builds the facts from its tables (CallinDirector.make_facts) and so does the call-in menu from what
## the host told its owner, which is why both show the same text. The roofed / landing-zone reasons need the
## physics world and come from CallinSafety.
##
## facts: {in_raid, downed, balance, cost, shared_left, cool_left, used, cap, in_flight, vehicle_id, installed, owned, lost}

const UNKNOWN := "Unknown call-in."
const NO_ARMOR := "Choose an armour: light, medium or heavy."
const NOT_IN_RAID := "You are not in the raid."
const DOWNED := "You cannot call in while downed."
const NO_COST := "That call-in is not available."
const NO_VEHICLE := "No vehicle is saved in your character slot."


## "" when the call-in may be made, else the HUD text. The order is the design's: raid, downed, points, cooldown,
## cap, orders on their way, vehicle.
static func make(kind: String, variant: String, facts: Dictionary) -> String:
	if not CallinRules.is_kind(kind):
		return UNKNOWN
	if kind == CallinRules.KIND_ARMOR and not variant in CallinRules.ARMOR_SIZES:
		return NO_ARMOR
	if not bool(facts.get("in_raid", false)):
		return NOT_IN_RAID
	if bool(facts.get("downed", false)):
		return DOWNED
	var cost := int(facts.get("cost", -1))
	if cost < 0 and kind != CallinRules.KIND_VEHICLE:
		return NO_COST
	if kind == CallinRules.KIND_VEHICLE:
		var vehicle := _make_vehicle_refusal(facts)
		if vehicle != "":
			return vehicle
	return _make_budget_refusal(kind, facts, cost)


static func _make_budget_refusal(kind: String, facts: Dictionary, cost: int) -> String:
	if int(facts.get("balance", 0)) < cost:
		return "Need %d RP for %s (you have %d)." % [cost, CallinRules.make_label(kind).to_lower(), int(facts.get("balance", 0))]
	if float(facts.get("shared_left", 0.0)) > 0.0:
		return "Wait %d s between call-ins." % int(ceil(float(facts.shared_left)))
	if float(facts.get("cool_left", 0.0)) > 0.0:
		return "%s is on cooldown: %d s." % [CallinRules.make_label(kind), int(ceil(float(facts.cool_left)))]
	if int(facts.get("used", 0)) >= int(facts.get("cap", 0)):
		return "No more %s this raid (%d used)." % [CallinRules.make_label(kind).to_lower(), int(facts.get("used", 0))]
	if int(facts.get("in_flight", 0)) >= CallinRules.max_active_orders():
		return "Too many call-ins on their way (%d)." % CallinRules.max_active_orders()
	return ""


static func _make_vehicle_refusal(facts: Dictionary) -> String:
	var id := str(facts.get("vehicle_id", ""))
	if id == "":
		return NO_VEHICLE
	if not bool(facts.get("installed", false)):
		return "%s is not installed." % id
	var name := str(Packs.vehicle(id).get("name", id))
	if bool(facts.get("lost", false)):
		return "Your %s was lost in a raid: buy it back (%d cr) first." % [name, EconomyRules.rebuy_price()]
	if not bool(facts.get("owned", true)):
		return "You do not own the %s." % name
	if int(facts.get("cost", -1)) < 0:
		return NO_COST
	return ""

class_name OccupancyHint
extends RefCounted
## The standing boarding / exit hint of the local player (InfantryHud, and the cockpit's message area while a
## cockpit shows), following each vehicle family's rules (BoardingRules, tribes_vehicles.md section 6):
##   inside a HATCH vehicle      "E: get out of the Raptor";
##   inside a Tribes vehicle     "E / Space: get out of the Scout (pilot seat)" (the jump key gets out too),
##                               plus "F: next seat" when it has more seats;
##   on foot, something in reach "E: pick up the Laser Rifle" / "E: enter the Raptor" (InfantryInteraction: the
##                               nearest interact offer), else by a HATCH vehicle the rules' refusal ("Light armor
##                               required");
##   inside without infantry      nothing: no Tribes pack installed, pilots cannot get out (PLAYTEST C5);
##   on foot near a Tribes one   "Walk into the LPC to board (passenger seat)", else the rules' refusal.

## A Tribes vehicle within this many metres beyond the touch reach gets a boarding hint.
const TOUCH_HINT_REACH := 4.0


## The hint for `director`'s local player ("" when there is nothing to do).
static func make_local(director: OccupancyDirector) -> String:
	var me := director.multiplayer.get_unique_id()
	var inside := director.vehicle_of(me)
	if inside:
		return make_inside(inside, me) if director.can_leave_vehicle(me) else ""
	var soldier := director.soldier_of(me)
	if soldier == null or not soldier.alive or soldier.stowed:
		return ""
	var interaction := InfantryInteraction.of(director.battle)
	var offer := interaction.make_hint(soldier) if interaction else ""
	if offer != "":
		return offer
	var hatch := make_hatch_text(director.make_hatch_choice(soldier))
	return hatch if hatch != "" else make_touch_text(director, soldier)


## The exit hint inside `vehicle` for occupant `me`.
static func make_inside(vehicle: Herc, me: int) -> String:
	var name_text := _vehicle_name(vehicle)
	if not BoardingRules.is_boarded_by_touch(vehicle.def):
		return "%s: get out of the %s" % [make_key_text(), name_text]
	var occ := VehicleOccupancy.of(vehicle)
	var role := VehicleSeats.make_role(vehicle.vehicle_id, occ.seat_of(me))
	var text := "%s / %s: get out of the %s (%s seat)" % [make_key_text(), make_key_text("ascend"), name_text, role]
	if occ.seats.size() > 1:
		text += "   %s: next seat" % make_key_text("seat_next")
	return text


## "E: enter the Raptor" or the refusal, for a hatch choice {vehicle, check} ("" for no choice).
static func make_hatch_text(choice: Dictionary) -> String:
	if choice.is_empty():
		return ""
	if bool(choice.check.ok):
		return "%s: enter the %s" % [make_key_text(), _vehicle_name(choice.vehicle)]
	return str(choice.check.reason)


## The hint for the nearest Tribes vehicle near `soldier` ("" when none is near or he just left it).
static func make_touch_text(director: OccupancyDirector, soldier: Infantry) -> String:
	var vehicle := find_touch_vehicle(director, soldier)
	if vehicle == null:
		return ""
	var check := BoardingRules.make_seat_choice(soldier, vehicle, VehicleOccupancy.of(vehicle))
	if not bool(check.ok):
		return str(check.reason)
	var role := VehicleSeats.make_role(vehicle.vehicle_id, int(check.seat))
	return "Walk into the %s to board (%s seat)" % [_vehicle_name(vehicle), role]


## The nearest live Tribes vehicle within TOUCH_HINT_REACH of `soldier`'s touch reach (null when none).
static func find_touch_vehicle(director: OccupancyDirector, soldier: Infantry) -> Herc:
	var best: Herc = null
	var best_gap := TOUCH_HINT_REACH
	for h in director.battle.vehicles.values():
		if not is_instance_valid(h) or h is Infantry or not h.alive or not BoardingRules.is_boarded_by_touch(h.def):
			continue
		if director.is_remount_blocked(soldier, h):
			continue
		var gap := BoardingRules.make_touch_gap(soldier, h)
		if gap <= best_gap:
			best_gap = gap
			best = h
	return best


## The first control bound to `action` ("E").
static func make_key_text(action := "vehicle_enter_exit") -> String:
	return BindingText.make_action_bindings(action).get_slice(BindingText.SEPARATOR, 0)


static func _vehicle_name(vehicle: Herc) -> String:
	return str(vehicle.def.get("name", "vehicle"))

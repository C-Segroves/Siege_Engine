class_name SupportCraft
extends RefCounted
## AI-flown support craft (insertion and exfil transports, call-in deliveries, bombers, attack craft): they fly in and out
## across the map edge by design, so the out-of-area rule (BattleBounds) leaves them, and whoever rides them, alone.
## Tribes 2 only warns a player outside the mission area (DefaultGame::leaveMissionArea); Tribes 1 and the remake's matches
## damage a player-driven vehicle and its passengers, and that stays.

const GROUP := "support_craft"


static func mark(craft: Node) -> void:
	craft.add_to_group(GROUP)


## Variant, not Node: a craft can be freed (shot down) while a seat or list still holds it.
static func is_craft(h: Variant) -> bool:
	return is_instance_valid(h) and (h as Node).is_in_group(GROUP)


## True for a support craft, or a soldier riding one.
static func is_exempt(h: Variant) -> bool:
	if not is_instance_valid(h):
		return false
	if is_craft(h):
		return true
	var s := h as Infantry
	return s != null and s.stowed and s.seat != null and is_craft(s.seat.vehicle)

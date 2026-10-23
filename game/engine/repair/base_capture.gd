class_name BaseCapture
extends RefCounted
## The one rule for repair work on a structure, shared by every game (a Tribes base object, an Earthsiege / Starsiege
## Structure): repair work for a team that is not allied to the structure's owner captures it first (a neutral
## structure, team -1, has no owner to take it from); a captured structure's capturer keeps it going, its owner's
## work takes it back. Per-game data (on / off, how long) is RepairRules "capture". Host only.

## The structure is neutral: it belongs to no team.
const NEUTRAL_TEAM := -1


static func is_on(pack_id: String) -> bool:
	return bool(RepairRules.capture(pack_id).get("enabled", false))


static func make_seconds(pack_id: String) -> float:
	return float(RepairRules.capture(pack_id).get("seconds", 0.0))


## True when a unit of `team` may repair `s`: neutral, allied, or any (capture on for its game).
static func may_repair(team: int, s: Structure) -> bool:
	return s.team == NEUTRAL_TEAM or TeamRelations.is_allied(team, s.team) or is_on(s.make_pack())


## Host: `amount` points of repair work by a unit of `by_team` on `s`, capturing first when the rules say so.
static func apply_work(s: Structure, by_team: int, amount: float) -> void:
	if not s.can_repair():
		return
	if is_on(s.make_pack()):
		_apply_capture_rule(s, by_team, make_seconds(s.make_pack()))
	s.apply_repair(amount)


static func _apply_capture_rule(s: Structure, by_team: int, seconds: float) -> void:
	if s.is_captured():
		if TeamRelations.is_allied(by_team, s.home_team):
			s.apply_release()
		else:
			s.apply_capture(s.team if TeamRelations.is_allied(by_team, s.team) else by_team, seconds)
	elif s.team >= 0 and not TeamRelations.is_allied(by_team, s.team):
		s.apply_capture(by_team, seconds)

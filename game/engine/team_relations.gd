class_name TeamRelations
extends RefCounted
## Who the AI treats as an enemy (AIPilot, FlyerAI, InfantryBot target searches). By default every other team is
## hostile, as the matches have always played. A mode may declare pairs of teams NEUTRAL (they leave each other
## alone) or ALLIED (they leave each other alone and count as friends: the extraction mode's relation presets,
## docs/design/extraction.md section 3); a Battle clears the table when it starts (Battle._ready), so one match's
## rules never leak into the next.

const HOSTILE := "hostile"
const NEUTRAL := "neutral"
const ALLIED := "allied"
const STANCES := [HOSTILE, NEUTRAL, ALLIED]

static var _stances := {}      # "a|b" (a < b) -> NEUTRAL / ALLIED (hostile pairs are not listed)


## True when a unit of `team` should attack a unit of `other`.
static func is_hostile(team: int, other: int) -> bool:
	return team != other and not _stances.has(make_pair_key(team, other))


## True when `team` and `other` are the same team or allied.
static func is_allied(team: int, other: int) -> bool:
	return team == other or make_stance(team, other) == ALLIED


## HOSTILE, NEUTRAL or ALLIED (a team is allied with itself).
static func make_stance(team: int, other: int) -> String:
	if team == other:
		return ALLIED
	return str(_stances.get(make_pair_key(team, other), HOSTILE))


## Declares `team` and `other` neutral to each other (both ways).
static func apply_neutral(team: int, other: int) -> void:
	apply_stance(team, other, NEUTRAL)


## Sets the stance between `team` and `other` (both ways); an unknown stance is an error and leaves them hostile.
static func apply_stance(team: int, other: int, stance: String) -> void:
	if team == other:
		return
	if not STANCES.has(stance):
		push_error("TeamRelations: unknown stance '%s'" % stance)
		stance = HOSTILE
	if stance == HOSTILE:
		_stances.erase(make_pair_key(team, other))
	else:
		_stances[make_pair_key(team, other)] = stance


static func clear() -> void:
	_stances.clear()


## The relation table as {pair key: stance} (LAN: the host sends it with the raid setup).
static func make_state() -> Dictionary:
	return _stances.duplicate()


## Applies a make_state() table; the old form {pair key: true} reads as neutral.
static func apply_state(state: Dictionary) -> void:
	_stances.clear()
	for key in state:
		_stances[str(key)] = state[key] if STANCES.has(state[key]) else NEUTRAL


static func make_pair_key(a: int, b: int) -> String:
	return "%d|%d" % [mini(a, b), maxi(a, b)]

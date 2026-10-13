class_name SSTeams
extends RefCounted
## Starsiege team relations. Neutral objects (team bits 0 in the .mis, engine team 9: civilian
## convoys, scenery vehicles) take no side: nobody targets them and they target nobody.

const NEUTRAL := 9


static func is_neutral(team: int) -> bool:
	return team == NEUTRAL


## True when a unit of team `a` should engage one of team `b` on its own initiative.
static func is_hostile(a: int, b: int) -> bool:
	return a != b and not is_neutral(a) and not is_neutral(b)

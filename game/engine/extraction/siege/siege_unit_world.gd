class_name SiegeUnitWorld
extends MissionWorld
## The mission world of one unit under the safe-area rule: it answers only "how long has he been outside" (the
## LeftAreaRule asks), set by SiegeEnforcer before each ruling.

var out_seconds := 0.0


func get_out_of_area_seconds() -> float:
	return out_seconds

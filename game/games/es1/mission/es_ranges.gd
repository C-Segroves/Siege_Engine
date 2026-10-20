class_name EsRanges
extends RefCounted
## The detect and safe ranges the Earthsiege 1 and 2 mission rules share (DBSIM 0xf744 / 0x4137b4), in original units.

## Alert region: an enemy within 50000 original units (195 m) or a hit (ES1 SIM@e722, SIM@1f496; ES2 DBSIM +0xc flag).
const DETECT_RANGE_UNITS := 50000.0
## "Safe": no aware enemy within 80000 units (312 m), 100000 (390 m) if it targets the unit.
const SAFE_RANGE_UNITS := 80000.0
const SAFE_RANGE_TARGETING_UNITS := 100000.0


## True when enemy `v` is close enough to make `u` unsafe (closer still counts when `v` targets `u`).
static func is_in_safe_range(v: Node3D, u: Node3D) -> bool:
	var r := SAFE_RANGE_TARGETING_UNITS if v.target == u else SAFE_RANGE_UNITS
	return v.global_position.distance_to(u.global_position) < r * Assets.UNIT

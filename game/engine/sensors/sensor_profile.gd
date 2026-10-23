class_name SensorProfile
extends RefCounted
## One game's detection numbers as data, read by the shared sensor code (ProximityAlert, SensorTowers, RadarMode, the
## scan objectives). The engine holds the rules once; each game builds the profile its originals need and cites where
## the numbers come from (docs/MECHANICS_UNIFICATION.md section 5, docs/CODING_STANDARDS.md section 4).

## Remake choices every game shares until its original says otherwise.
## Reach (m) of a com tower without a sensor spec of its own (Earthsiege towers; the original value is unknown, USER_TODO).
const DEFAULT_TOWER_RANGE_M := 1500.0
## A passive radar sees an unlit unit only this share of its range away.
const DEFAULT_PASSIVE_NEAR_SHARE := 0.34
## A passive unit is detected at this share of a sensor's reach.
const DEFAULT_PASSIVE_SIGNATURE := 0.5

## Alert region / detection flag: an enemy within this many metres of a unit, or a hit (0 = no proximity alert).
var detect_range_m := 0.0
## "Safe" test: no aware enemy within this many metres (more when it targets the unit).
var safe_range_m := 0.0
var safe_range_targeting_m := 0.0
## The scan objective (onScan): keep the target within scan_range_m for scan_seconds.
var scan_range_m := 0.0
var scan_seconds := 0.0
## Half-angle (degrees) the scanner must face the target within; 360 = no cone.
var scan_cone_degrees := SensorSource.ALL_ROUND_DEGREES
## A structure is scanned from this much farther (its size).
var scan_structure_extra_m := 0.0
var tower_range_m := DEFAULT_TOWER_RANGE_M
var passive_near_share := DEFAULT_PASSIVE_NEAR_SHARE
var passive_signature := DEFAULT_PASSIVE_SIGNATURE
## The soldiers' own sensor (null = soldiers carry none: Tribes 1).
var soldier_sensor: SensorSource = null


## The remake's defaults for a game with no numbers of its own.
static func make_default() -> SensorProfile:
	return SensorProfile.new()

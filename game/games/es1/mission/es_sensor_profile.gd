class_name EsSensorProfile
extends RefCounted
## The detect and safe ranges the Earthsiege 1 and 2 mission rules share (DBSIM 0xf744 / 0x4137b4), as the game's
## SensorProfile. The original units are converted once here.

## Alert region: an enemy within 50000 original units (195 m) or a hit (ES1 SIM@e722, SIM@1f496; ES2 DBSIM +0xc flag).
const DETECT_RANGE_UNITS := 50000.0
## "Safe": no aware enemy within 80000 units (312 m), 100000 (390 m) if it targets the unit.
const SAFE_RANGE_UNITS := 80000.0
const SAFE_RANGE_TARGETING_UNITS := 100000.0

## Scan missions (header word 3 = 3 / 7, es2.md 10.2): face the target within 60 m (+20 m for a structure), +-45 degrees, for 4 s.
const SCAN_RANGE_M := 60.0
const SCAN_STRUCTURE_EXTRA_M := 20.0
const SCAN_CONE_DEGREES := 45.0
const SCAN_SECONDS := 4.0

static var _profile: SensorProfile = null


static func make() -> SensorProfile:
	if _profile == null:
		_profile = SensorProfile.make_default()
		_profile.detect_range_m = DETECT_RANGE_UNITS * Assets.UNIT
		_profile.safe_range_m = SAFE_RANGE_UNITS * Assets.UNIT
		_profile.safe_range_targeting_m = SAFE_RANGE_TARGETING_UNITS * Assets.UNIT
		_profile.scan_range_m = SCAN_RANGE_M
		_profile.scan_structure_extra_m = SCAN_STRUCTURE_EXTRA_M
		_profile.scan_cone_degrees = SCAN_CONE_DEGREES
		_profile.scan_seconds = SCAN_SECONDS
	return _profile

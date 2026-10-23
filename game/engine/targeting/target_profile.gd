class_name TargetProfile
extends RefCounted
## One game's target-choice rules as data, read by TargetSelector. The engine holds the algorithm once; every game
## (and every kind of shooter in it: pilot, soldier bot, turret) builds the profile its original behaviour needs and
## cites where the numbers come from (docs/MECHANICS_UNIFICATION.md section 5, docs/CODING_STANDARDS.md section 4).

## Most a unit's aim point is assumed to sit from its origin (m) for a turret's prefilter.
const AIM_PAD_M := 6.0

## How hidden units are left out: not at all, by the viewer's radar (CloakRules.is_hidden_from_radar), by eyes at the
## distance (a jamming soldier and the cloak's reveal range), or by a turret's sensor rules (`sensor`).
enum Visibility { NONE, RADAR, EYES, SENSOR }

## Candidates farther than this (m) are never picked; INF for "anywhere".
var range_m := INF
## Most the aim point may sit from a unit's origin (m): the cheap distance prefilter measures to the origin first.
var pad_m := 0.0
var visibility := Visibility.NONE
## The turret sensor rules ({detects_cloaked, min_velocity}) for Visibility.SENSOR and for keeps().
var sensor := {}
## A passive (EMCON) unit is seen from half as far: the distance is divided by RadarMode.make_signature.
var weigh_signature := false
## Only Hercs (vehicles and soldiers) are candidates, not other members of the vehicles group.
var herc_only := false
## A soldier stowed in a vehicle is not a target (turrets).
var skip_stowed := false
## Stickiness: a held target is kept up to range_m + this many metres; negative = no distance limit when keeping.
var keep_buffer := -1.0
## Seconds between a shooter's target searches (0 = the caller's own timing).
var think_seconds := 0.0
## Callable(team: int, other_team: int) -> bool; empty = TeamRelations.is_hostile.
var hostile_rule := Callable()


func with_range(metres: float) -> TargetProfile:
	range_m = metres
	return self


## The base turret: sensor rules for cloaked units, soldiers stowed in a vehicle skipped, a prefilter pad for aim points
## above the origin. Each game adds its hostility rule, sensor datablock and timings.
static func make_turret() -> TargetProfile:
	var profile := TargetProfile.new()
	profile.visibility = Visibility.SENSOR
	profile.skip_stowed = true
	profile.pad_m = AIM_PAD_M
	return profile

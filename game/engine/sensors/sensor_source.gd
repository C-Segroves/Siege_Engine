class_name SensorSource
extends RefCounted
## One detector as data (a base sensor, a turret's sensor, a soldier's own eyes, a com tower): how far it reaches,
## whether it needs a clear line, how wide it looks, and which hidden units it can still find. The rules of every
## game's sensors are the same few questions; a game's SensorProfile only says which numbers its originals use
## (docs/MECHANICS_UNIFICATION.md section 5, Sensors).
##
## Spec dictionary keys (base_equipment.json "sensor" / "player_sensor" blocks, Tribes 1 SensorData, Tribes 2 SensorData):
##   range, los (castLOS / detectsUsingLOS), jams (Tribes 1 supression), detects_jammed (detectsPassiveJammed),
##   detects_cloaked, min_velocity (detectMinVelocity), fov_only + fov_deg + fov_percent (detectFOVPercent).

## Lines of sight and ranges aim at a unit's middle (metres above its origin).
const SIGHT_HEIGHT := 1.0
const DEFAULT_FOV_DEGREES := 90.0
const ALL_ROUND_DEGREES := 360.0

var range_m := 0.0
var needs_los := false
## The view cone (degrees) around the facing direction; 360 = all round.
var cone_degrees := ALL_ROUND_DEGREES
## A jammer hides its own side from the enemy's sensors instead of detecting anything.
var jams := false
var detects_jammed := false
var detects_cloaked := false
var min_velocity := 0.0


## The source a spec dictionary describes (an empty one is a sensor that sees nothing: range 0).
static func make_from_spec(spec: Dictionary) -> SensorSource:
	var source := SensorSource.new()
	source.range_m = float(spec.get("range", 0.0))
	source.needs_los = bool(spec.get("los", false))
	source.jams = bool(spec.get("jams", false))
	source.detects_jammed = bool(spec.get("detects_jammed", false))
	source.detects_cloaked = bool(spec.get("detects_cloaked", false))
	source.min_velocity = float(spec.get("min_velocity", 0.0))
	if bool(spec.get("fov_only", false)):
		source.cone_degrees = float(spec.get("fov_deg", DEFAULT_FOV_DEGREES)) * float(spec.get("fov_percent", 1.0))
	return source


## The cloak rules' view of this sensor (CloakRules.is_hidden_from_sensor).
func make_cloak_rules() -> Dictionary:
	return {"detects_cloaked": detects_cloaked, "min_velocity": min_velocity}


## True when a sensor standing at `origin` finds `unit`: inside the range, not hidden by a cloak it cannot see
## through, inside the cone around `facing` (ignored when all round) and with a clear line when it needs one.
## Range and line are measured from the sensor's eye (SIGHT_HEIGHT above `origin`) to the unit's middle.
func senses(origin: Node3D, unit: Node3D, facing := Vector3.ZERO) -> bool:
	var eye := origin.global_position + Vector3.UP * SIGHT_HEIGHT
	var middle := unit.global_position + Vector3.UP * SIGHT_HEIGHT
	var to := middle - eye
	if to.length() > range_m or CloakRules.is_hidden_from_sensor(unit, make_cloak_rules(), to.length()):
		return false
	if cone_degrees < ALL_ROUND_DEGREES and facing.angle_to(to) > deg_to_rad(cone_degrees) * 0.5:
		return false
	return not needs_los or LineOfSight.is_clear(origin, eye, unit, middle)

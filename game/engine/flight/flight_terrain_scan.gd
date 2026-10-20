class_name FlightTerrainScan
extends RefCounted
## Terrain look-ahead of a FlightPilot: samples the ground along the path the craft is about to fly and says how fast it
## must climb now to clear every rise by the profile's clearance, allowing the craft's reaction time. It reads the
## heightfield through a function, so it works on any map (and on a flat test world).

## Ground samples are at most this far apart (m), so a narrow ridge is not missed, and there are at least / at most this many.
const SAMPLE_SPACING_M := 25.0
const MIN_SAMPLES := 8
const MAX_SAMPLES := 48
## Never plan a climb into less time than this (s): a rise right ahead asks for a hard but finite climb.
const MIN_PLAN_S := 0.6
## Flying slower than this still reads the ground this far (m/s).
const MIN_READ_SPEED := 8.0
## Reported when no sample needs a climb.
const NONE := -1.0e9

## ground_height(x: float, z: float) -> float; NAN where the ground is unknown.
var ground := Callable()
## Height (m) to keep over every sample, how far ahead (s) to read and the craft's reaction time (s).
var clearance := 18.0
var look_ahead_s := 6.0
var react_s := 1.2
## The craft's present vertical speed (m/s) and how fast it can change it (m/s^2): turning a dive into a climb takes time.
var vertical_speed := 0.0
var climb_accel := 10.0
## The most the craft can climb at (m/s); with it the scan works out the speed it can fly and still climb every rise in time.
var climb_capacity := 10.0
## The fastest the craft may fly now (m/s) so that it can climb the rise ahead before it reaches it (INF when none).
var safe_speed := INF
## The craft does not fly farther than this (m): a goal it stops at.
var max_distance := INF


func apply_profile(profile: FlightProfile) -> void:
	clearance = profile.clearance_m
	look_ahead_s = profile.look_ahead_s
	react_s = profile.react_s


## The climb rate (m/s) the nearest-in-time sample demands along any of `directions` (flat unit vectors), or NONE.
## `sink_rate` (m/s, <= 0) is the descent already planned, which lowers the craft along the way down to `floor_y`, the
## height it levels off at.
func make_required_climb(pos: Vector3, directions: Array[Vector3], speed: float, sink_rate: float, floor_y: float) -> float:
	var read_speed := maxf(speed, MIN_READ_SPEED)
	var reach := minf(read_speed * look_ahead_s, max_distance)
	var samples := clampi(ceili(reach / SAMPLE_SPACING_M), MIN_SAMPLES, MAX_SAMPLES)
	var required := NONE
	safe_speed = INF
	for dir in directions:
		for i in samples + 1:
			var d := reach * float(i) / samples
			var t := d / read_speed
			var g := _ground_at(pos.x + dir.x * d, pos.z + dir.z * d)
			var gain := g + clearance - _make_height_at(pos.y, sink_rate, t, floor_y)
			if gain > 0.0:
				required = maxf(required, _make_rate_for(gain, t))
				if i > 0:
					safe_speed = minf(safe_speed, _make_speed_at(d, gain))
	return required


## The height (world y) the craft is planned to have after `t` seconds: sinking at `sink_rate` (<= 0) it levels off at `floor_y`;
## a craft that is below its goal height is not credited with having reached it.
static func _make_height_at(y: float, sink_rate: float, t: float, floor_y: float) -> float:
	if sink_rate < 0.0:
		return maxf(y + sink_rate * t, floor_y)
	return y


## The climb rate (m/s) that gains `gain` metres in `t` seconds, less the craft's reaction time and the time it needs to turn
## its present vertical speed into that climb.
func _make_rate_for(gain: float, t: float) -> float:
	var rate := gain / maxf(t - react_s, MIN_PLAN_S)
	var turn_s := absf(rate - vertical_speed) / maxf(climb_accel, 0.1)
	return gain / maxf(t - react_s - turn_s, MIN_PLAN_S)


## The fastest the craft may fly (m/s) and still have the time it needs to climb a rise of `gain` metres before it covers
## the `d` metres to it. Slowing down early matters more than the braking left: the craft is held to this speed from the
## moment the rise is in sight.
func _make_speed_at(d: float, gain: float) -> float:
	var climb_s := gain / maxf(climb_capacity, 0.1) + react_s + absf(climb_capacity - vertical_speed) / maxf(climb_accel, 0.1)
	return d / climb_s


func _ground_at(x: float, z: float) -> float:
	var h: float = ground.call(x, z) if ground.is_valid() else NAN
	return h if not is_nan(h) else -INF

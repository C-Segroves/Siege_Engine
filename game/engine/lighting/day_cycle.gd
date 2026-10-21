class_name DayCycle
extends RefCounted
## The maths of a day: where the sun is at a time of day and what the light, sky and fog look like then. Pure functions
## of a timing record and a look record, so the host's rules (night factors) and every peer's picture read the same day.
##
## timing  {length_s, start_phase, night_from, night_to}   (extraction_rules.json site_spawns.day)
##         phase 0..1 is the position in the day; the sun is up from night_to to night_from and below the horizon
##         for the rest, so "night" in the rules and the dark in the picture are the same span.
## look    {max_elevation_deg, stops: [{h, sun_color, sun_energy, ambient, fog_color, horizon_color, sky_tint, fog_start,
##         fog_end}]}   (a map's environment.day_cycle). h is the height of the sun (sine of its elevation, -1..1); the
##         stops are sorted by h and every value is blended between the two stops the sun's height lies between. Below
##         the horizon the light is the moon, which stands opposite the sun.


## Day length (seconds) of a timing record.
static func make_length(timing: Dictionary) -> float:
	return maxf(float(timing.get("length_s", 1800.0)), 1.0)


## Position in the day (0..1) after `clock_s` seconds.
static func make_phase(timing: Dictionary, clock_s: float) -> float:
	return fposmod(clock_s / make_length(timing), 1.0)


## Seconds on the clock at the start of the raid.
static func make_start_clock(timing: Dictionary) -> float:
	return float(timing.get("start_phase", 0.0)) * make_length(timing)


static func is_night(timing: Dictionary, phase: float) -> bool:
	var from := float(timing.get("night_from", 0.7))
	var to := float(timing.get("night_to", 0.1))
	return phase >= from or phase < to


## Angle of the sun along its orbit: 0 sunrise, PI/2 noon, PI sunset, 3 PI / 2 midnight.
static func make_orbit_angle(timing: Dictionary, phase: float) -> float:
	var from := float(timing.get("night_from", 0.7))
	var to := float(timing.get("night_to", 0.1))
	var day_len := maxf(from - to, 0.01)
	if phase >= to and phase < from:
		return PI * (phase - to) / day_len
	return PI + PI * fposmod(phase - from, 1.0) / maxf(1.0 - day_len, 0.01)


## The unit vector from the scene to the sun (below the horizon at night). `noon_toward` is the horizontal direction
## of the sun at noon; the orbit rises to the east of it and climbs to max_elevation_deg at noon.
static func make_sun_position(look: Dictionary, timing: Dictionary, phase: float, noon_toward: Vector3) -> Vector3:
	var theta := make_orbit_angle(timing, phase)
	var noon := Vector3(noon_toward.x, 0.0, noon_toward.z).normalized()
	var east := Vector3.UP.cross(noon).normalized()
	var max_el := deg_to_rad(float(look.get("max_elevation_deg", 60.0)))
	var peak := noon * cos(max_el) + Vector3.UP * sin(max_el)
	return (east * cos(theta) + peak * sin(theta)).normalized()


## The look at sun height `h`: {sun_color: Color, sun_energy, ambient: Color, fog_color: Color, horizon_color: Color,
## sky_tint: Color, fog_start, fog_end}.
static func make_look(look: Dictionary, h: float) -> Dictionary:
	var stops: Array = look.stops
	var lo: Dictionary = stops[0]
	var hi: Dictionary = stops[stops.size() - 1]
	for i in stops.size() - 1:
		if h >= float(stops[i].h) and h <= float(stops[i + 1].h):
			lo = stops[i]
			hi = stops[i + 1]
			break
	var span := float(hi.h) - float(lo.h)
	var t := 0.0 if span <= 0.0 else clampf((h - float(lo.h)) / span, 0.0, 1.0)
	t = smoothstep(0.0, 1.0, t)
	var out := {}
	for k in lo:
		if k == "h":
			continue
		out[k] = _blend(lo[k], hi.get(k, lo[k]), t)
	return out


static func _blend(a, b, t: float):
	if a is Array:
		return MapEnvironment.make_color(a).lerp(MapEnvironment.make_color(b), t)
	return lerpf(float(a), float(b), t)

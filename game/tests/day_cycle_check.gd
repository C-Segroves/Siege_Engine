extends Node
## The day cycle (DayCycle, DayCycleLight): the sun is up exactly while the rules say it is day, the light blends
## between the map's stops, and Varuna's Fall carries a cycle on the raid's own timing.
##   godot --headless --audio-driver Dummy --path game res://tests/day_cycle_check.tscn
const TIMING := {"length_s": 1000.0, "start_phase": 0.3, "night_from": 0.7, "night_to": 0.1}
const STOPS := {"max_elevation_deg": 60, "stops": [
	{"h": -1.0, "sun_energy": 0.2, "ambient": [0.1, 0.1, 0.2]},
	{"h": 1.0, "sun_energy": 1.0, "ambient": [0.5, 0.5, 0.5]}]}

var _failures := 0


func _ready() -> void:
	_check_orbit()
	_check_blend()
	_check_varuna()
	print("day_cycle_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
	print("  %s %s" % ["ok  " if ok else "FAIL", what])


func _check_orbit() -> void:
	var noon := Vector3(0.0, 0.0, 1.0)
	var agrees := true
	for i in 100:
		var phase := (i + 0.5) / 100.0
		var up := DayCycle.make_sun_position(STOPS, TIMING, phase, noon).y > 0.0
		agrees = agrees and up != DayCycle.is_night(TIMING, phase)
	_expect(agrees, "the sun is above the horizon exactly when it is not night")
	var peak := DayCycle.make_sun_position(STOPS, TIMING, 0.4, noon)
	_expect(is_equal_approx(peak.y, sin(deg_to_rad(60.0))), "noon: the sun stands at the map's maximum elevation")
	_expect(DayCycle.make_sun_position(STOPS, TIMING, 0.9, noon).y < -0.8, "midnight: the sun is far below the horizon")
	_expect(is_equal_approx(DayCycle.make_phase(TIMING, 1300.0), 0.3), "the phase wraps with the day length")
	_expect(is_equal_approx(DayCycle.make_start_clock(TIMING), 300.0), "the raid starts at start_phase")


func _check_blend() -> void:
	var mid := DayCycle.make_look(STOPS, 0.0)
	_expect(is_equal_approx(mid.sun_energy, 0.6), "halfway between the stops: halfway energy (%.2f)" % mid.sun_energy)
	_expect((mid.ambient as Color).is_equal_approx(Color(0.3, 0.3, 0.35)), "the ambient colour blends too")
	_expect(is_equal_approx(DayCycle.make_look(STOPS, -5.0).sun_energy, 0.2), "below the first stop the first stop holds")


func _check_varuna() -> void:
	if not VarunaMap.is_available():
		print("  skip Varuna (the Tribes 2 pack is not installed)")
		return
	var e: Dictionary = VarunaMap.make_map().environment
	_expect(e.get("day_cycle") is Dictionary and (e.day_cycle.get("stops") as Array).size() >= 4, "Varuna's environment has a day cycle")
	_expect(e.day_cycle.timing == SiteSpawner.day_timing(), "its timing is the rules' day (night factors and sky agree)")

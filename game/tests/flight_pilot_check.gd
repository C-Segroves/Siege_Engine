extends Node
## FlightPilot check (engine/flight/flight_pilot.gd): the shared AI autopilot, flown on the real flight models over a
## synthetic world (no map, no nodes):
##   1. a jet flying across a ridge climbs early, never goes below the clearance, sinks smoothly after, reaches the goal;
##   2. a hover transport does the same, pitching its nose for the climb;
##   3. a hard turn banks (bank proportional to the heading error, capped) without sliding sideways, and reaches the goal;
##   4. path, orbit and line goals are followed;
##   5. a wall of buildings ahead is turned away from, and the map edge turns the craft back;
##   6. a descent goal lands a hover craft softly;
##   7. a hover goal holds its height over the ground below however the ground ahead rises (a delivery hovers low).
##   godot --headless --audio-driver Dummy --path game res://tests/flight_pilot_check.tscn

const STEP := 1.0 / 30.0
const RIDGE_X := 0.0
const RIDGE_HEIGHT := 140.0
const RIDGE_WIDTH := 120.0
const START_X := -900.0
const GOAL_X := 1600.0
const GOAL_AGL := 30.0
const CLEARANCE_SLACK := 0.75
const MAX_SIDESLIP := 0.12
const REACH := 80.0
## Heading that flies along +x.
const EAST := -PI / 2.0

var _failures := 0


class Sim extends RefCounted:
	var model: FlightModel
	var pilot: FlightPilot
	var pos := Vector3.ZERO
	var ground := Callable()
	var min_agl := INF
	var max_bank := 0.0
	var min_pitch := 0.0
	var max_sideslip := 0.0

	func agl() -> float:
		return pos.y - float(ground.call(pos.x, pos.z))

	func step(goal: FlightGoal, speed: float) -> void:
		var c := pilot.steer(pos, agl(), goal, speed, STEP)
		model.step(c, agl(), STEP)
		pos += model.velocity * STEP
		min_agl = minf(min_agl, agl())
		max_bank = maxf(max_bank, absf(model.bank))
		min_pitch = minf(min_pitch, model.pitch)
		var flat := Vector3(model.velocity.x, 0.0, model.velocity.z)
		if flat.length() > 5.0:
			max_sideslip = maxf(max_sideslip, absf(angle_difference(FlightAvoidance._heading_of(flat), model.heading)))

	func flat_distance(p: Vector3) -> float:
		return Vector2(pos.x - p.x, pos.z - p.z).length()


func _ready() -> void:
	_check_jet_ridge()
	_check_hover_ridge()
	_check_banked_turn()
	_check_goal_kinds()
	_check_avoidance()
	_check_descent()
	_check_hover_goal()
	_check_patrol_clearance()
	print("flight_pilot_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


# ------------------------------------------------------------------ world

static func ridge_ground(x: float, _z: float) -> float:
	return RIDGE_HEIGHT * exp(-pow((x - RIDGE_X) / RIDGE_WIDTH, 2.0))


static func flat_ground(_x: float, _z: float) -> float:
	return 0.0


func _make_sim(params: Dictionary, vehicle_id: String, ground: Callable, start: Vector3) -> Sim:
	var s := Sim.new()
	s.model = FlightModel.create(params)
	s.model.heading = EAST
	s.model.apply_flying_state(float(params.cruise_speed))
	s.pilot = FlightPilot.new(s.model, FlightProfile.make_for(vehicle_id, params))
	s.pilot.apply_world(ground, Callable(), Rect2())
	s.ground = ground
	s.pos = start
	return s


func _make_jet_sim(ground: Callable, start: Vector3) -> Sim:
	return _make_sim(FlightPresets.make_reference_jet_params(FlightPresets.REFERENCE_JET), "es2:RAZOR", ground, start)


func _make_transport_params() -> Dictionary:
	return FlightPresets.make_hover_params(FlightPresets.make_reference_transport_datablock())


func _fly_ridge(s: Sim, seconds: float) -> Dictionary:
	var goal := FlightGoal.make_point(Vector3(GOAL_X, 0.0, 0.0), GOAL_AGL)
	var speed := float(s.model.params.cruise_speed)
	var crest_clear := INF
	var climbed_before := 0.0
	var t := 0.0
	while t < seconds and s.pos.x < GOAL_X - REACH:
		s.step(goal, speed)
		if s.pos.x < RIDGE_X - RIDGE_WIDTH:
			climbed_before = maxf(climbed_before, s.model.pitch)
		if absf(s.pos.x - RIDGE_X) < 20.0:
			crest_clear = minf(crest_clear, s.agl())
		t += STEP
	return {"time": t, "climbed_before": climbed_before, "crest_clear": crest_clear}


# ------------------------------------------------------------------ 1 / 2 ridge

func _check_jet_ridge() -> void:
	print("jet over a ridge (%.0f m high):" % RIDGE_HEIGHT)
	var s := _make_jet_sim(Callable(self, "ridge_ground"), Vector3(START_X, GOAL_AGL, 0.0))
	var clearance := s.pilot.profile.clearance_m
	var r := _fly_ridge(s, 120.0)
	_expect(s.pos.x >= GOAL_X - REACH, "reaches the far side (x %.0f in %.0f s)" % [s.pos.x, r.time])
	_expect(s.min_agl >= clearance * CLEARANCE_SLACK, "never below the clearance %.0f m (lowest %.1f m)" % [clearance, s.min_agl])
	_expect(r.climbed_before > 0.05, "starts climbing before the ridge (pitch %.0f deg)" % rad_to_deg(r.climbed_before))
	_expect(r.crest_clear >= clearance * CLEARANCE_SLACK, "clears the crest by %.1f m" % r.crest_clear)
	_expect(s.min_pitch < -0.02, "sinks nose down after it (pitch %.0f deg)" % rad_to_deg(s.min_pitch))
	_expect(absf(s.agl() - GOAL_AGL) < 25.0, "settles back towards the goal height (%.0f m)" % s.agl())
	_expect(s.max_sideslip < MAX_SIDESLIP, "flies where the nose points (sideslip %.3f rad)" % s.max_sideslip)


func _check_hover_ridge() -> void:
	print("hover transport over a ridge:")
	var s := _make_sim(_make_transport_params(), "tribes2:HAVOC", Callable(self, "ridge_ground"), Vector3(START_X, GOAL_AGL, 0.0))
	var clearance := s.pilot.profile.clearance_m
	var r := _fly_ridge(s, 200.0)
	_expect(s.pos.x >= GOAL_X - REACH, "reaches the far side (x %.0f in %.0f s)" % [s.pos.x, r.time])
	_expect(s.min_agl >= clearance * CLEARANCE_SLACK, "never below the clearance %.0f m (lowest %.1f m)" % [clearance, s.min_agl])
	_expect(r.climbed_before > 0.02, "noses up for the climb (pitch %.0f deg)" % rad_to_deg(r.climbed_before))
	_expect(s.min_pitch < -0.01, "noses down on the way after (pitch %.0f deg)" % rad_to_deg(s.min_pitch))


# ------------------------------------------------------------------ 3 banked turn

func _check_banked_turn() -> void:
	print("banked turns:")
	for side in [1.0, -1.0]:
		var s := _make_jet_sim(Callable(self, "flat_ground"), Vector3(0.0, GOAL_AGL, 0.0))
		var target := Vector3(0.0, 0.0, -side * 700.0)   # flying +x: -z is to the left
		var goal := FlightGoal.make_point(target, GOAL_AGL)
		var banked := 0.0
		var t := 0.0
		while t < 60.0 and s.flat_distance(target) > REACH:
			s.step(goal, float(s.model.params.cruise_speed))
			banked = s.model.bank if absf(s.model.bank) > absf(banked) else banked
			t += STEP
		var name := "left" if side > 0.0 else "right"
		_expect(s.flat_distance(target) <= REACH, "%s turn reaches its goal in %.0f s" % [name, t])
		_expect(signf(banked) == -side and absf(banked) > 0.2, "%s turn banks that way (%.0f deg)" % [name, rad_to_deg(banked)])
		_expect(s.max_bank <= s.pilot.profile.max_bank + 0.15, "bank capped (%.0f deg of %.0f)" % [rad_to_deg(s.max_bank), rad_to_deg(s.pilot.profile.max_bank)])
		_expect(s.max_sideslip < MAX_SIDESLIP * 2.0, "no sliding (sideslip %.3f rad)" % s.max_sideslip)
	var gentle := _make_jet_sim(Callable(self, "flat_ground"), Vector3(0.0, GOAL_AGL, 0.0))
	var small := FlightGoal.make_point(Vector3(900.0, 0.0, -60.0), GOAL_AGL)
	for i in 90:
		gentle.step(small, float(gentle.model.params.cruise_speed))
	var hard := gentle.pilot.profile.max_bank * 0.6
	_expect(gentle.max_bank < hard, "a small correction banks less than a hard turn (%.0f deg)" % rad_to_deg(gentle.max_bank))


# ------------------------------------------------------------------ 4 goals

func _check_goal_kinds() -> void:
	print("goal kinds:")
	var s := _make_jet_sim(Callable(self, "flat_ground"), Vector3(0.0, GOAL_AGL, 0.0))
	var square: Array[Vector3] = [Vector3(500, 0, 0), Vector3(500, 0, 500), Vector3(0, 0, 500), Vector3(0, 0, 0)]
	var path := FlightGoal.make_path(square, 0, GOAL_AGL)
	var laps := 0
	var last := 0
	for i in 3600:
		s.step(path, float(s.model.params.cruise_speed))
		if path.index == 0 and last == square.size() - 1:
			laps += 1
		last = path.index
	_expect(laps >= 1, "follows a path round (%d laps)" % laps)
	var o := _make_jet_sim(Callable(self, "flat_ground"), Vector3(400.0, GOAL_AGL, 0.0))
	var orbit := FlightGoal.make_orbit(Vector3.ZERO, 400.0, GOAL_AGL, true)
	var near := true
	for i in 2400:
		o.step(orbit, float(o.model.params.cruise_speed))
		if i > 600 and absf(Vector2(o.pos.x, o.pos.z).length() - 400.0) > 260.0:
			near = false
	_expect(near, "holds an orbit about its centre")
	var l := _make_jet_sim(Callable(self, "flat_ground"), Vector3(0.0, GOAL_AGL, 150.0))
	var line := FlightGoal.make_line(Vector3.ZERO, Vector3.RIGHT, 150.0, GOAL_AGL)
	for i in 1200:
		l.step(line, float(l.model.params.cruise_speed))
	_expect(absf(l.pos.z) < 40.0 and l.pos.x > 500.0, "flies back onto a line from 150 m off it (off %.0f m)" % l.pos.z)


# ------------------------------------------------------------------ 5 avoidance

## A wall across x = 450 from z = -2000 to z = 100 (the open side is z > 100).
func _wall_free_run(from: Vector3, dir: Vector3, length: float) -> float:
	if absf(dir.x) < 0.001:
		return length
	var t := (450.0 - from.x) / dir.x
	if t < 0.0 or t > length:
		return length
	return t if from.z + dir.z * t < 100.0 else length


func _check_avoidance() -> void:
	print("avoidance:")
	var s := _make_jet_sim(Callable(self, "flat_ground"), Vector3(0.0, GOAL_AGL, 0.0))
	s.pilot.apply_world(Callable(self, "flat_ground"), Callable(self, "_wall_free_run"), Rect2())
	var goal := FlightGoal.make_point(Vector3(1000.0, 0.0, 0.0), GOAL_AGL)
	var through_wall := false
	for i in 1800:
		s.step(goal, float(s.model.params.cruise_speed))
		if s.pos.x > 449.0 and s.pos.x < 460.0 and s.pos.z < 100.0:
			through_wall = true
	_expect(not through_wall, "turns away from a wall instead of flying through it (ended x %.0f, z %.0f)" % [s.pos.x, s.pos.z])
	var area := Rect2(-1000.0, -1000.0, 2000.0, 2000.0)
	var e := _make_jet_sim(Callable(self, "flat_ground"), Vector3(0.0, GOAL_AGL, 0.0))
	e.pilot.apply_world(Callable(self, "flat_ground"), Callable(), area)
	var edge := FlightGoal.make_straight(Vector3.ZERO, Vector3.RIGHT, GOAL_AGL)
	var out := false
	for i in 3000:
		e.step(edge, float(e.model.params.cruise_speed))
		out = out or not area.has_point(Vector2(e.pos.x, e.pos.z))
	_expect(not out, "turns back at the map edge (ended at %.0f, %.0f)" % [e.pos.x, e.pos.z])
	var leaving := _make_jet_sim(Callable(self, "flat_ground"), Vector3(0.0, GOAL_AGL, 0.0))
	leaving.pilot.apply_world(Callable(self, "flat_ground"), Callable(), area)
	var exit_goal := FlightGoal.make_straight(Vector3.ZERO, Vector3.RIGHT, GOAL_AGL)
	exit_goal.crosses_edge = true
	for i in 1500:
		leaving.step(exit_goal, float(leaving.model.params.cruise_speed))
	_expect(leaving.pos.x > 1100.0, "a craft leaving the map flies out of it (x %.0f)" % leaving.pos.x)


# ------------------------------------------------------------------ 6 descent

func _check_descent() -> void:
	print("descent:")
	var s := _make_sim(_make_transport_params(), "tribes2:HAVOC", Callable(self, "flat_ground"), Vector3(0.0, 40.0, 0.0))
	s.model.apply_flying_state(0.0)
	var goal := FlightGoal.make_descent(Vector3.ZERO, 4.0)
	var t := 0.0
	while t < 40.0 and not s.model.landed:
		s.step(goal, 0.0)
		t += STEP
	_expect(s.model.landed and s.model.hard_landing == 0.0, "sinks to a soft landing (%.0f s, level %.2f rad)" % [t, s.model.pitch])
	_expect(s.min_agl >= 0.0, "never below the ground")


# ------------------------------------------------------------------ 7 hover goal

const HOVER_AGL := 14.0
const HOVER_HILL_HEIGHT := 80.0
const HOVER_HILL_X := 60.0
const HOVER_HILL_WIDTH := 30.0
const HOVER_SPOT_REACH := 8.0
const HOVER_BAND := 2.0


static func hover_hill_ground(x: float, _z: float) -> float:
	return HOVER_HILL_HEIGHT * exp(-pow((x - HOVER_HILL_X) / HOVER_HILL_WIDTH, 2.0))


func _check_hover_goal() -> void:
	print("hover goal:")
	var params := _make_transport_params()
	params["max_alt"] = 300.0
	var s := _make_sim(params, "tribes2:HAVOC", Callable(self, "hover_hill_ground"), Vector3(-300.0, 45.0, 0.0))
	var goal := FlightGoal.make_hover(Vector3.ZERO, HOVER_AGL)
	var t := 0.0
	var highest := 0.0
	var lowest := INF
	var settled := 0.0
	while t < 60.0 and settled < 1.5:
		var flat := s.flat_distance(Vector3.ZERO)
		s.step(goal, clampf(flat * 0.4, 0.0, 10.0))
		if flat < 40.0:
			highest = maxf(highest, s.agl())
			lowest = minf(lowest, s.agl())
		settled = settled + STEP if flat < HOVER_SPOT_REACH and absf(s.agl() - HOVER_AGL) < HOVER_BAND else 0.0
		t += STEP
	_expect(settled >= 1.5, "stops over the spot at its height (%.0f s, %.1f m over the ground)" % [t, s.agl()])
	_expect(highest <= HOVER_AGL + HOVER_BAND, "the hill beside the spot does not lift it (highest %.1f m near the spot)" % highest)
	_expect(lowest >= HOVER_AGL * 0.5, "it does not dip below the hover (lowest %.1f m)" % lowest)


# ------------------------------------------------------------------ 8 patrol clearance

const PATROL_VEHICLE := "tribes2:SHRIKE"
const PATROL_AGL := 22.0
const PATROL_HILL := 30.0
const PATROL_WAVE_M := 150.0
const PATROL_LEG_M := 1000.0
const PATROL_SECONDS := 120.0


static func rolling_ground(x: float, z: float) -> float:
	return PATROL_HILL * (0.5 + 0.5 * sin(x / PATROL_WAVE_M * TAU)) * (0.6 + 0.4 * sin(z / PATROL_WAVE_M * TAU * 0.7))


func _check_patrol_clearance() -> void:
	print("patrol over rolling ground:")
	var vdef := Packs.vehicle(PATROL_VEHICLE)
	if vdef.is_empty():
		print("  skipped (%s is not installed)" % PATROL_VEHICLE)
		return
	var params := FlightPresets.make_params(vdef, Packs.metres_per_unit(String(vdef.get("pack", PATROL_VEHICLE.get_slice(":", 0)))))
	var s := _make_sim(params, PATROL_VEHICLE, Callable(self, "rolling_ground"), Vector3(-PATROL_LEG_M, PATROL_AGL + 20.0, 0.0))
	var corners: Array[Vector3] = [Vector3(PATROL_LEG_M, 0, 0), Vector3(PATROL_LEG_M, 0, 800), Vector3(-PATROL_LEG_M, 0, 800), Vector3(-PATROL_LEG_M, 0, 0)]
	var goal := FlightGoal.make_path(corners, 0, PATROL_AGL)
	var t := 0.0
	while t < PATROL_SECONDS:
		s.step(goal, float(params.cruise_speed))
		t += STEP
	var profile := s.pilot.profile
	_expect(s.min_agl >= profile.clearance_m * CLEARANCE_SLACK, "never below the clearance %.0f m on a patrol at full speed (lowest %.1f m)" % [profile.clearance_m, s.min_agl])
	_expect(profile.dive_clearance_m < profile.clearance_m, "the strafing dive's floor is a profile value below it (%.0f m)" % profile.dive_clearance_m)

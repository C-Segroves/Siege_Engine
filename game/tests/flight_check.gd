extends Node
## Flight model check (docs/formats/flight_model.md):
##   1. presets: the ES2 FM files decode to the documented values; every catalog flyer is
##      pilotable and gets a style;
##   2. pure HoverFlightModel: lift climbs to maxAlt and no higher, descend lands;
##   3. a Battle with the player in the Razor, driven only by injected actions: taxi, take off,
##      climb and respect the ceiling, bank-turn, descend and land;
##   4. an AI Skimmer in the same battle keeps patrolling its path in the air.
##   godot --headless --audio-driver Dummy --path game res://tests/flight_check.tscn [-- --herc=<flyer id>]

const TIME_SCALE := 4.0
const PLAYER_FLYER := "es2:RAZOR"
const AI_FLYER := {"vehicle": "es1:SKIMMER", "team": 0, "skill": 0.5, "flyer": true, "name": "Patrol"}
const CEILING_TOLERANCE := 1.3
const HOVER_STEP := 1.0 / 30.0

var _failures := 0
var battle: Battle
var _patrol: Flyer
var _patrol_last := -1
var _patrol_advances := 0


func _ready() -> void:
	_check_presets()
	_check_hover_model()
	await _check_battle_flight()
	print("flight_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


# ------------------------------------------------------------------ presets

func _check_presets() -> void:
	print("presets:")
	_check_jet_sane(FlightPresets.make_generic_jet_params(), "generic jet preset")
	var fm: Array = Packs.vehicles.get(FlightPresets.REFERENCE_JET, {}).get("flight_model", [])
	if fm.size() == FlightPresets.FM_WORDS:
		var raw := FlightPresets.decode_fm(fm)
		var p := FlightPresets.make_jet_params(fm, 1.0 / 256.0)
		_expect(absf(p.max_speed - raw.max_speed * 8.0 / 256.0) < 0.01, "Razor FM (from the ES2 pack) converts to m/s")
		_check_jet_sane(p, "Razor from the ES2 pack")
	else:
		print("  (ES2 not imported: Razor FM checks skipped)")
	var flyers := 0
	for id in Packs.vehicles:
		var v: Dictionary = Packs.vehicles[id]
		if not v.get("flyer", false):
			continue
		flyers += 1
		var fp := FlightPresets.make_params(v, Packs.metres_per_unit(v.pack))
		var armed := PackVehicleLoader.is_armed(v)
		_expect(v.pilotable == armed and fp.style in [FlightPresets.STYLE_JET, FlightPresets.STYLE_HOVER] and fp.max_speed > 0.0,
			"%s %s, %s style, %.0f m/s" % [id, "pilotable" if armed else "AI-only (unarmed)", fp.style, fp.max_speed])
	_expect(flyers > 0, "catalog has flyers (%d)" % flyers)


func _check_jet_sane(p: Dictionary, what: String) -> void:
	_expect(p.max_speed > p.min_speed and p.min_speed > 0.0 and p.ceiling_max > p.ceiling_min and p.ceiling_min > 0.0,
		"%s: speed %.0f..%.0f m/s, ceiling %.0f..%.0f m" % [what, p.min_speed, p.max_speed, p.ceiling_min, p.ceiling_max])


# ------------------------------------------------------------------ pure hover model

func _check_hover_model() -> void:
	print("hover model (Tribes Scout):")
	var scout = Packs.vehicles.get("tribes:SCOUT", {}).get("flier_data")
	var m := FlightModel.create(FlightPresets.make_hover_params(scout if scout is Dictionary else FlightPresets.GENERIC_HOVER))
	m.apply_landed_state()
	var alt := 0.0
	var top := 0.0
	var lift := FlightControls.make(0.5, 0.0, Vector2.ZERO, 1.0)
	for i in 600:
		m.step(lift, alt, HOVER_STEP)
		alt += m.velocity.y * HOVER_STEP
		top = maxf(top, alt)
	_expect(not m.landed and top > 20.0 and top <= float(m.params.max_alt) + 1.0, "climbs to maxAlt 25 m (top %.1f m)" % top)
	var sink := FlightControls.make(0.0, 0.0, Vector2.ZERO, -1.0)
	for i in 600:
		m.step(sink, maxf(alt, 0.0), HOVER_STEP)
		alt += m.velocity.y * HOVER_STEP
		if m.landed:
			break
	_expect(m.landed and m.hard_landing == 0.0, "descend lands softly")


# ------------------------------------------------------------------ battle

func _check_battle_flight() -> void:
	var herc := PLAYER_FLYER
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--herc="):
			herc = Assets.qualify(a.substr(7))
	battle = load("res://games/es1/battle.tscn").instantiate()
	var config := BattleSetup.make_default_config(herc)
	config.ai = [AI_FLYER]
	battle.config = config
	await get_tree().process_frame
	get_tree().root.add_child(battle)
	for i in 10:
		await get_tree().physics_frame
	var fl := battle.player as Flyer
	_expect(fl != null and battle.pilot is PlayerFlightPilot, "player %s is a Flyer with flight controls" % herc)
	if fl == null:
		return
	Engine.time_scale = TIME_SCALE
	_patrol = _find_ai_flyer()
	if fl.flight is JetFlightModel:
		await _fly_jet(fl)
	else:
		await _fly_hover(fl)
	_expect(_patrol != null and _patrol.alive and _patrol.make_altitude() > 5.0 and _patrol_advances >= 2,
		"AI Skimmer patrols in the air (%d patrol points reached, %.0f m up)" % [_patrol_advances, _patrol.make_altitude() if _patrol else 0.0])
	Engine.time_scale = 1.0


func _find_ai_flyer() -> Flyer:
	for v in battle.vehicles.values():
		if v is Flyer and v != battle.player:
			return v
	return null


func _fly_jet(fl: Flyer) -> void:
	print("jet (%s):" % fl.display_name)
	fl.apply_landed_start()
	await _hold(["throttle_up"], 2.0)
	_expect(fl.flight.landed and fl.speed > 5.0, "taxis on the ground (%.1f m/s)" % fl.speed)
	Input.action_press("throttle_up")
	var top := await _hold_tracking(fl, ["ascend"], 30.0)
	Input.action_release("throttle_up")
	var ceiling := float(fl.flight.params.ceiling_max)
	_expect(not fl.flight.landed and top > 40.0, "takes off and climbs (top %.0f m)" % top)
	_expect(top <= ceiling * CEILING_TOLERANCE, "respects the ceiling %.0f m (top %.0f m)" % [ceiling, top])
	var heading := fl.rotation.y
	await _hold(["turn_right"], 4.0)
	_expect(fl.torso_yaw > 0.0 or angle_difference(heading, fl.rotation.y) < -0.3,
		"banks right and turns (%.0f deg)" % rad_to_deg(angle_difference(heading, fl.rotation.y)))
	await _hold(["throttle_down"], 3.0)
	await _hold(["descend"], 0.7)
	await _wait_landed(fl, 90.0)
	_expect(fl.flight.landed and fl.alive, "descends and lands (alive %s, integrity %.2f)" % [fl.alive, fl.integrity])
	await _hold([], 10.0)
	_expect(fl.speed < 1.0, "rolls to a stop (%.1f m/s)" % fl.speed)


func _fly_hover(fl: Flyer) -> void:
	print("hover (%s):" % fl.display_name)
	fl.apply_landed_start()
	var top := await _hold_tracking(fl, ["ascend"], 20.0)
	_expect(not fl.flight.landed and top > 5.0 and top <= float(fl.flight.params.max_alt) * 1.1 + 2.0,
		"lifts off to max altitude %.0f m (top %.0f m)" % [fl.flight.params.max_alt, top])
	var heading := fl.rotation.y
	await _hold(["turn_right", "throttle_up"], 3.0)
	_expect(absf(angle_difference(heading, fl.rotation.y)) > 0.3, "turns")
	await _hold(["throttle_stop"], 0.1)
	await _hold(["descend"], 30.0)
	_expect(fl.flight.landed and fl.alive, "descends and lands")


## Holds `actions` for `seconds` of game time.
func _hold(actions: Array, seconds: float) -> void:
	for a in actions:
		Input.action_press(a)
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		_sample_patrol()
	for a in actions:
		Input.action_release(a)


## Holds `actions` and returns the highest altitude reached.
func _hold_tracking(fl: Flyer, actions: Array, seconds: float) -> float:
	for a in actions:
		Input.action_press(a)
	var t := 0.0
	var top := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		_sample_patrol()
		top = maxf(top, fl.make_altitude())
	for a in actions:
		Input.action_release(a)
	return top


func _wait_landed(fl: Flyer, seconds: float) -> void:
	var t := 0.0
	while t < seconds and not fl.flight.landed and fl.alive:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		_sample_patrol()


func _sample_patrol() -> void:
	if _patrol == null:
		return
	if _patrol_last >= 0 and _patrol.patrol_i != _patrol_last:
		_patrol_advances += 1
	_patrol_last = _patrol.patrol_i

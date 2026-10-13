class_name Flyer
extends Herc
## A flying vehicle (ES2 Razor and Landskimmer, ES1 Skimmer, Starsiege flyers, Tribes fliers),
## moved by the shared FlightModel (engine/flight, docs/formats/flight_model.md). The player
## (PlayerFlightPilot) and the built-in AI (FlyerAI, attached by BattleSpawner for AI units) write
## the same controls, so both fly by the same physics.
##
## Controls besides Herc.throttle (0..1; < 0 = reverse, hover craft) and Herc.turn (+ = roll / steer
## right): yaw_input (+ = nose right), pitch_input (+ = nose up), lift_input (+ = ascend), -1..1.
## Reuses Herc networking and damage. The body stays upright (yaw only); the visual model carries
## pitch and bank, which travel in the snapshot's pitch and torso slots (a flyer has no torso).

## ES1 Skimmer (not in the ES1 catalog): hull points from SKIMMER.DAT (docs/formats/gameplay.md §2).
const ES1_SKIMMER_HP := 300.0
const CRASH_SPIN := 1.5
## Hull damage per m/s of sink rate on a hard landing (approximation, no original landing model).
const HARD_LANDING_DAMAGE := 40.0
## Player jets start this high above the ground at cruise speed (ES2 flyers start airborne).
const PLAYER_START_HEIGHT := 40.0
## Ground probe when the map has no height field: ray length below the flyer (m).
const GROUND_PROBE := 2000.0
const NO_HEIGHT_FIELD := -100000.0

var altitude := 22.0          # AI cruise height above the ground (m)
var cruise := 30.0            # AI cruise speed (m/s)
var patrol: Array[Vector3] = []
var patrol_i := 0
var skill := 0.5
var flight: FlightModel
var ai: FlyerAI = null
var yaw_input := 0.0
var pitch_input := 0.0
var lift_input := 0.0
var _started := false


func _configure() -> void:
	if Packs.vehicle(vehicle_id).is_empty():
		_configure_es1_skimmer()
	else:
		super._configure()
	var pack := String(def.get("pack", vehicle_id.split(":")[0]))
	flight = FlightModel.create(FlightPresets.make_params(def, Packs.metres_per_unit(pack)))
	cruise = float(flight.params.cruise_speed)
	max_speed = float(flight.params.max_speed)
	_started = false


func _configure_es1_skimmer() -> void:
	def = {"shape": vehicle_id, "name": "Skimmer", "pack": vehicle_id.split(":")[0], "guns": []}
	if display_name == "":
		display_name = "Skimmer"
	shield_max = 0.0
	shield_front = 0.0
	shield_rear = 0.0
	components = [{"name": "HULL", "hp": ES1_SKIMMER_HP, "max": ES1_SKIMMER_HP, "fatal": true, "parent": -1}]
	integrity = 1.0


## Gives the flyer its built-in AI pilot (host side, AI units only).
func start_ai() -> void:
	ai = FlyerAI.new(self)


## Player start: jets in the air at cruise, hover craft on the ground.
func apply_player_start() -> void:
	if flight is JetFlightModel:
		global_position.y = _make_ground_height() + PLAYER_START_HEIGHT
		throttle = make_throttle_for(cruise)


## Puts the flyer on the ground at rest (tests, hover craft starts).
func apply_landed_start() -> void:
	global_position.y = _make_ground_height()
	flight.heading = rotation.y
	flight.apply_landed_state()
	throttle = 0.0
	_started = true


## Writes one frame of stick input (the AI autopilot's output, or a test's).
func apply_controls(c: FlightControls) -> void:
	throttle = c.throttle
	turn = c.roll
	yaw_input = c.yaw
	pitch_input = c.pitch
	lift_input = c.lift


## Throttle (0..1) that holds `speed_mps`.
func make_throttle_for(speed_mps: float) -> float:
	var lo := float(flight.params.min_speed) if flight is JetFlightModel else 0.0
	return clampf(inverse_lerp(lo, float(flight.params.max_speed), speed_mps), 0.0, 1.0)


func make_controls() -> FlightControls:
	return FlightControls.make(throttle, turn, Vector2(yaw_input, pitch_input), lift_input)


## Height above the ground (m).
func make_altitude() -> float:
	return global_position.y - _make_ground_height()


## Flyers with a cockpit or HUD layout (CockpitFit) start in it; the rest start in the chase view.
func prefers_chase_view() -> bool:
	return not CockpitFit.has_cockpit(def)


# ------------------------------------------------------------------ simulation

func _physics_process(delta: float) -> void:
	if is_puppet:
		_puppet_update(delta)
		return
	capacitor = minf(capacitor_max, capacitor + capacitor_rate * delta)
	if not alive:
		_crash(delta)
		return
	if not _started:
		_apply_first_state()
	if has_meta("disabled_until") and Time.get_ticks_msec() < int(get_meta("disabled_until")):
		_hold_controls()
	elif ai:
		ai.update(delta)
	_fly(delta)
	_animate(delta)


## In the air when spawned above the ground (AI flyers, player jets), else landed.
func _apply_first_state() -> void:
	_started = true
	flight.heading = rotation.y
	if make_altitude() > FlightModel.GROUND_CONTACT:
		flight.apply_flying_state(cruise)
	else:
		flight.apply_landed_state()


func _fly(delta: float) -> void:
	flight.step(make_controls(), make_altitude(), delta)
	_apply_hard_landing()
	velocity = flight.velocity
	rotation.y = flight.heading
	var moved_at := velocity
	move_and_slide()
	CollisionDamage.apply_contacts(self, moved_at)
	var ground := _make_ground_height()
	if global_position.y < ground:
		global_position.y = ground
	speed = flight.speed
	pitch = flight.pitch
	torso_yaw = flight.bank


func _apply_hard_landing() -> void:
	if flight.hard_landing <= 0.0:
		return
	var excess := flight.hard_landing - FlightModel.SAFE_SINK_RATE
	flight.hard_landing = 0.0
	KillText.apply_caused_hit(self, [0.0, maxf(excess, 0.0) * HARD_LANDING_DAMAGE, null, global_position], KillText.CAUSE_CRASH)


## Shot down: falls spinning and explodes on the ground.
func _crash(delta: float) -> void:
	velocity.y -= gravity * delta
	rotate_z(delta * CRASH_SPIN)
	move_and_slide()
	if (is_on_floor() or make_altitude() <= 0.0) and visible:
		_play_crash_blast()
		visible = false


## The wreck hits the ground: its game's death blast once more, where it lands (the first played when it was
## shot down, Herc._explode).
func _play_crash_blast() -> void:
	_big_blast_played = false
	_explode()


## Ground under the flyer: the map's height field, else a ray down, else 0.
func _make_ground_height() -> float:
	var p := global_position
	if not is_inside_tree():
		return 0.0
	var h := MapBuilder.ground_height(get_parent(), Vector3(p.x, NO_HEIGHT_FIELD, p.z))
	if h != NO_HEIGHT_FIELD:
		return h
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP, p + Vector3.DOWN * GROUND_PROBE)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return float(hit.position.y) if not hit.is_empty() else 0.0


# ------------------------------------------------------------------ aim / visuals

## Gunner: his turret aim; AI: straight at its target; player: along the nose.
func aim_basis() -> Basis:
	var crew := TurretCrew.find(self)
	if crew and crew.is_manned():   # a gunner works the belly turret (Thundersword)
		return crew.make_aim_basis()
	if ai and is_instance_valid(target) and target.alive:
		return Basis.looking_at(target.global_position + Vector3.UP * FlyerAI.TARGET_AIM_HEIGHT - global_position, Vector3.UP)
	return global_basis * Basis(Vector3.RIGHT, pitch)


## The view rides the pitched and banked model; the bank rolls about the nose, so the crosshair stays on aim_basis.
func sight_basis() -> Basis:
	return shape.global_basis.orthonormalized() if shape else aim_basis()


func cockpit_node() -> Node3D:
	return shape


## Pitch and bank on the visual model (the torso slot carries the bank).
func _animate(_delta: float) -> void:
	if shape:
		shape.quaternion = FlightModel.make_attitude(pitch, torso_yaw).get_rotation_quaternion()

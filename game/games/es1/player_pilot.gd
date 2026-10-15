class_name PlayerPilot
extends Node
## The local player's controls for a Herc, read through the SiegeInput actions
## (docs/CODING_STANDARDS.md §2): throttle, turn, torso aim (mouse / right stick), both fire groups,
## targeting and releasing the mouse (menu_pause). Flyers use PlayerFlightPilot (make_for()).
## While the pilot steers an Earthsiege EO missile (MissileSteering: its trigger held), the mouse / right stick
## steer the missile instead of the torso and the Herc does not turn; the throttle keeps working.

const THROTTLE_RATE := 0.6          # full throttle range per second while held
const AUTOFIRE_FLAG := "--autofire" # test aid: hold both fire groups
const FIRE_GROUP_ACTIONS := ["fire_group_1", "fire_group_2"]   # weapon.group 0 / 1

var herc: Herc
var _last_next_msec := -100000   ## ticks of the previous target_next press
var aim_yaw := 0.0
var aim_pitch := 0.0
var _autofire := false
## Mouse movement since the last physics step while a missile is steered (radians, x right, y down).
var _missile_look := Vector2.ZERO


## The pilot for the player's vehicle: flight controls for a Flyer, else walking controls.
static func make_for(h: Herc) -> PlayerPilot:
	var p: PlayerPilot = PlayerFlightPilot.new() if h is Flyer else PlayerPilot.new()
	p.herc = h
	return p


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_autofire = OS.get_cmdline_user_args().has(AUTOFIRE_FLAG)


func _unhandled_input(event: InputEvent) -> void:
	if herc == null:
		return
	if event is InputEventMouseMotion and herc.missile_steering.is_steering():
		if _is_mouse_captured():
			_missile_look += SiegeInput.make_mouse_look(event)
	elif event is InputEventMouseMotion:
		_apply_mouse_look(event)
	elif event.is_action_pressed("ui_click") and not _is_mouse_captured():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		_apply_command(event)


func _apply_command(event: InputEvent) -> void:
	if event.is_action_pressed("throttle_stop"):
		herc.throttle = 0.0
	elif event.is_action_pressed("torso_center"):
		_center_aim()
	elif event.is_action_pressed("target_next"):
		apply_target(next_enemy())
	elif event.is_action_pressed("target_nearest"):
		apply_target(nearest_enemy())
	elif event.is_action_pressed("menu_pause"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	if herc == null or not herc.alive:
		return
	_apply_drive(delta)
	_apply_triggers()
	if herc.target != null and (not is_instance_valid(herc.target) or not herc.target.alive):
		herc.target = null


## Throttle, turn and torso aim of a walking Herc (PlayerFlightPilot flies instead).
func _apply_drive(delta: float) -> void:
	herc.throttle = clampf(herc.throttle + SiegeInput.make_throttle_axis() * THROTTLE_RATE * delta, -1.0, 1.0)
	if herc.missile_steering.is_steering():
		_apply_missile_stick(delta)
		herc.turn = 0.0   # the original zeroes the turn / twist input while the missile flies by the stick (0x4cf2e)
	else:
		_missile_look = Vector2.ZERO
		_apply_aim(SiegeInput.make_stick_look(delta))
		herc.turn = SiegeInput.make_turn_axis()
	herc.torso_target = aim_yaw
	herc.pitch_target = aim_pitch


## The steered missile's stick: the right stick's deflection plus this step's mouse movement as a turn.
func _apply_missile_stick(delta: float) -> void:
	var steer := herc.missile_steering
	steer.apply_pilot_stick(SiegeInput.make_aim_axes() + steer.make_stick_from_look(_missile_look, delta))
	_missile_look = Vector2.ZERO


func _center_aim() -> void:
	aim_yaw = 0.0
	aim_pitch = 0.0


func _apply_mouse_look(event: InputEventMouseMotion) -> void:
	if _is_mouse_captured():
		_apply_aim(SiegeInput.make_mouse_look(event))


## Turns the torso aim by `look` (x = right, y = down), within the Herc's limits.
func _apply_aim(look: Vector2) -> void:
	if look == Vector2.ZERO:
		return
	aim_yaw = make_turned_yaw(aim_yaw - look.x, herc.torso_limit)
	aim_pitch = clampf(aim_pitch - look.y, herc.pitch_min, herc.pitch_max)


## `yaw` kept within a torso limit: wrapped for a turret that turns all the way round, else clamped.
static func make_turned_yaw(yaw: float, limit: float) -> float:
	if limit >= PI - Herc.TURRET_FULL_TURN_SLACK:
		return wrapf(yaw, -PI, PI)
	return clampf(yaw, -limit, limit)


func _apply_triggers() -> void:
	var may_fire := _is_mouse_captured() or SiegeInput.is_gamepad_active()
	var held := []
	for action in FIRE_GROUP_ACTIONS:
		held.append(_autofire or (may_fire and Input.is_action_pressed(action)))
	for w in herc.weapons:
		w.trigger = held[1] if w.group == 1 else held[0]


func apply_target(t: Node3D) -> void:
	herc.target = t
	Sfx.play_ui("target_select" if t else "target_unlock")


func _is_mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


## Living targets, best first (Targeting: nearest the crosshair, distance-weighted, in view).
func make_enemy_ranking() -> Array:
	return Targeting.make_ranking(herc)


## target_nearest: the target nearest the crosshair.
func nearest_enemy() -> Node3D:
	return Targeting.pick_best(herc)


## target_next: the first press locks the nearest target in the 45 deg cone ahead; presses within
## Targeting.REPEAT_WINDOW_S of the previous one cycle on through the cone (wraps round).
func next_enemy() -> Node3D:
	var now := Time.get_ticks_msec()
	var repeat := now - _last_next_msec <= int(Targeting.REPEAT_WINDOW_S * 1000.0)
	_last_next_msec = now
	return Targeting.pick_next(herc, herc.target if repeat else null)

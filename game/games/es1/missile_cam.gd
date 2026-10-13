class_name MissileCam
extends SubViewport
## The Earthsiege missile camera (docs/MISSILE_CAM.md): a view from just behind the pilot's newest missile
## (MissileSteering.tracked), looking along its flight. When the missile hits, the view stays on the blast for a
## moment while the frame flashes (ES1 0x36552, ES2 0x43fe38); when it times out the view simply ends.
## Shown on the cockpit's MFD MISSILE CAM page (CockpitMfd) and in the remake's MissileCamWindow.
## Renders only while there is something to show; it shares the battle's 3D world.

## 4 x the Earthsiege 1 MFD page (72 x 46 pixels): sharp in the larger window, scaled down on the MFD.
const RESOLUTION := Vector2i(288, 184)
## The original places the eye 500 units behind the missile on its heading (ES1 0x36632, ES2 0x43ff57).
const BEHIND_UNITS := 500.0
## Remake values: the original's field of view and blast hold time are not decoded (ES1 holds while the blast
## object exists, ES2 for 0x1e timer units).
const FOV_DEG := 62.0
const NEAR := 0.1
const FAR := 4000.0
const HIT_HOLD_SECONDS := 1.0
const FLASH_PERIOD := 0.15

var herc: Herc
var camera: Camera3D
var _missile: Projectile
var _hold_left := 0.0
var _time := 0.0


func _init(p_herc: Herc) -> void:
	herc = p_herc
	name = "MissileCam"
	size = RESOLUTION
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	camera = Camera3D.new()
	camera.fov = FOV_DEG
	camera.near = NEAR
	camera.far = FAR
	camera.cull_mask = BattleCameras.ALL_LAYERS & ~InfantryHeldWeapon.VIEW_MODEL_LAYER
	add_child(camera)


func _ready() -> void:
	camera.current = true


func _process(delta: float) -> void:
	_time += delta
	var m: Projectile = herc.missile_steering.tracked if is_instance_valid(herc) else null
	if is_instance_valid(m) and m != _missile:
		_follow(m)
	if is_flying():
		_place_behind(_missile)
	else:
		_hold_left = maxf(_hold_left - delta, 0.0)
	render_target_update_mode = SubViewport.UPDATE_ALWAYS if is_active() else SubViewport.UPDATE_DISABLED


func _follow(m: Projectile) -> void:
	if is_instance_valid(_missile) and _missile.impacted.is_connected(_on_impacted):
		_missile.impacted.disconnect(_on_impacted)
	_missile = m
	_hold_left = 0.0
	m.impacted.connect(_on_impacted)
	_place_behind(m)


func _on_impacted(_at: Vector3) -> void:
	_hold_left = HIT_HOLD_SECONDS


func _place_behind(m: Projectile) -> void:
	var heading := m.make_heading()
	var eye := m.global_position - heading * BEHIND_UNITS * Assets.UNIT
	camera.look_at_from_position(eye, eye + heading, Vector3.UP if absf(heading.y) < 0.99 else Vector3.RIGHT)


## True while a missile flies or its blast is still shown.
func is_active() -> bool:
	return is_flying() or _hold_left > 0.0


func is_flying() -> bool:
	return is_instance_valid(_missile)


## True during the hold after a hit.
func is_showing_hit() -> bool:
	return not is_flying() and _hold_left > 0.0


## The hit flash's phase (the frame alternates between two colours).
func is_flash_on() -> bool:
	return is_showing_hit() and fmod(_time, FLASH_PERIOD * 2.0) < FLASH_PERIOD


## The missile's distance from its pilot, metres (the last seen spot after a hit).
func make_range() -> float:
	return herc.global_position.distance_to(camera.global_position) if is_instance_valid(herc) else 0.0

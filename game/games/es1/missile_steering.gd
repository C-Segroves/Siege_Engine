class_name MissileSteering
extends Node
## A pilot's own missiles in flight, for the Earthsiege missile camera and the player-steered electro-optical
## (EO) missile (docs/MISSILE_CAM.md). Child of its Herc; one per vehicle.
##
## Tracked: the newest missile a player (not an AI) launched from an Earthsiege 1 / 2 rack, the games whose
## cockpit had a MISSILE CAM page (ES1 DBSIM 0x7843 / ES2 0x40aae1 store it for the camera).
## Steered: a tracked missile with EO guidance, while the trigger of its fire group stays held. The pilot's
## `stick` (-1..1, x right, y down) turns it by up to the missile's turn rate (ES1 0x70dc, ES2 0x40a488);
## releasing the trigger leaves it flying straight, unguided. While a missile is steered its fire group does
## not fire, and after the missile is gone that trigger must be released before the group fires again.
## Runs on every peer: the host steers the real missile, clients their visual copies (stick from the snapshot).

## The games whose cockpits had the missile camera (weapon id prefix).
const CAMERA_PACKS := ["es1", "es2"]
const STEERED_GUIDANCE := "eo"
const MISSILE_KIND := "missile"
const NO_GROUP := -1
## Pitch of the steered missile (Options > Controls, user://settings.json): what "up" (mouse up, stick up, the
## original's cursor up) does. The originals set it in DATA/KEYJOY.CFG "MISSILE = DEFAULT | REVERSE" (ES1 parser
## 0x4d918 -> [0x95814]; DEFAULT: up steers the missile up). The shipped files differ: Earthsiege 1 says REVERSE
## (up steers down, like an aircraft stick), Earthsiege 2 says Default; PITCH_GAME keeps each game's own.
const PITCH_KEY := "missile_pitch"
const PITCH_GAME := "game"
const PITCH_UP_IS_UP := "up_is_up"
const PITCH_UP_IS_DOWN := "up_is_down"
const PITCH_MODES := [PITCH_GAME, PITCH_UP_IS_UP, PITCH_UP_IS_DOWN]
const PITCH_LABELS := ["As the original game (ES1: up steers down, ES2: up steers up)", "Up steers the missile up",
	"Up steers the missile down"]
## The packs whose shipped KEYJOY.CFG reverses the missile pitch.
const REVERSED_PITCH_PACKS := ["es1"]

## Steering input: x = turn right, y = nose down, each -1..1 (a stick's deflection).
var stick := Vector2.ZERO
## The newest tracked missile (null when none is flying).
var tracked: Projectile = null
## The missile being steered now (null when none).
var steered: Projectile = null
## Fire group of the steered missile's weapon.
var steered_group := NO_GROUP

var herc: Herc
var _latched_group := NO_GROUP


func _init(p_herc: Herc) -> void:
	herc = p_herc
	name = "MissileSteering"


static func pitch_mode() -> String:
	var m := str(Assets.settings.get(PITCH_KEY, PITCH_GAME))
	return m if PITCH_MODES.has(m) else PITCH_GAME


static func apply_pitch_mode(mode: String) -> void:
	Assets.settings[PITCH_KEY] = mode if PITCH_MODES.has(mode) else PITCH_GAME
	Assets.save_settings()


## True when "up" steers a missile of pack `pack` down under pitch mode `mode`.
static func is_pitch_reversed(mode: String, pack: String) -> bool:
	if mode == PITCH_GAME:
		return REVERSED_PITCH_PACKS.has(pack)
	return mode == PITCH_UP_IS_DOWN


## Sets the steering stick from the pilot's input `input` (x right, y down = the mouse / stick pulled down),
## with the pitch setting applied to the steered missile's game.
func apply_pilot_stick(input: Vector2) -> void:
	var s := input.clamp(-Vector2.ONE, Vector2.ONE)
	if is_steering() and is_pitch_reversed(pitch_mode(), make_pack_of(steered.weapon_def)):
		s.y = -s.y
	stick = s


## True when weapon definition `d` fired by `shooter` gets the missile camera: a player's missile from an
## Earthsiege rack.
static func is_tracked_kind(d: Dictionary, shooter: Node) -> bool:
	return str(d.get("kind", "")) == MISSILE_KIND and CAMERA_PACKS.has(make_pack_of(d)) \
		and shooter is Herc and not shooter.has_meta("ai")


static func make_pack_of(d: Dictionary) -> String:
	return str(d.get("id", "")).get_slice(":", 0)


## Takes a just-launched projectile `p` of fire group `group` (Weapon / BattleFx): a missile the camera follows
## becomes the tracked one, an EO one the steered one (the newest missile takes the controls over).
func adopt(p: Projectile, group: int) -> void:
	if not is_tracked_kind(p.weapon_def, herc):
		return
	tracked = p
	if p.guidance != STEERED_GUIDANCE:
		return
	if is_instance_valid(steered):
		steered.drop_guidance()
	steered = p
	steered_group = group
	p.steering = self


func is_steering() -> bool:
	return is_instance_valid(steered)


## True while `p` is the missile the pilot steers.
func is_steering_missile(p: Projectile) -> bool:
	return is_steering() and p == steered


## True while fire group `group` must not fire: its trigger steers a missile, or is still held from that.
func is_group_blocked(group: int) -> bool:
	return (group == steered_group and is_steering()) or group == _latched_group


## The stick that turns the steered missile by `look` (radians, x right, y down: a mouse movement) in a
## physics step of `delta` seconds; zero when no missile is steered.
func make_stick_from_look(look: Vector2, delta: float) -> Vector2:
	if not is_steering() or steered.turn_rate <= 0.0 or delta <= 0.0:
		return Vector2.ZERO
	return look / (steered.turn_rate * delta)


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(tracked):
		tracked = null
	if steered_group != NO_GROUP and not is_steering():
		_end_steering(true)
	elif is_steering() and (not herc.alive or not is_group_held(steered_group)):
		steered.drop_guidance()   # trigger released (or pilot down): the missile flies on straight (ES1 0x717e)
		_end_steering(false)
	if _latched_group != NO_GROUP and not is_group_held(_latched_group):
		_latched_group = NO_GROUP


## Steering is over; `still_held`: the missile is gone while the trigger is held, which then must be released
## before the group fires again (ES1 0x73b4).
func _end_steering(still_held: bool) -> void:
	if still_held and is_group_held(steered_group):
		_latched_group = steered_group
	steered = null
	steered_group = NO_GROUP
	stick = Vector2.ZERO


## True while a weapon of fire group `group` has its trigger pulled.
func is_group_held(group: int) -> bool:
	for w in herc.weapons:
		if w.group == group and w.trigger:
			return true
	return false

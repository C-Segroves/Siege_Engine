class_name WeaponDuelShot
extends BattleShot
## Trailer shot of one game's weapon effects: the player's Herc (or soldier) stands facing a target dummy
## staged in front of it, fires scripted volleys at it and destroys it on cue, while a camera moves along
## the line of fire on keyframes so the muzzle, the shot in flight and the impacts are all in frame.
## Spec keys (beyond BattleShot's: herc, config, ai, stage, settle):
##   loadout    [weapon id, ...] the shooter carries (a soldier: its armour "armor" first, see below)
##   armor      soldier armour id when config "start" is "on_foot" (e.g. "tribes2:HEAVY")
##   fire       [[from s, to s, [weapon index, ...]], ...] triggers held (a soldier: the first index in hand)
##   aim_lift   metres above the target's middle the shooter aims at (lobbed shots), per weapon index {i: m}
##   target_shield  0..1 of the dummy's shields kept (shield hits first), target_height (aim point share)
##   kill_at    s: the dummy is destroyed then (its death explosion)
##   death_fx   [[effect, pack, delay s, [x, y, z] offset], ...] library effects played over the death
##   advance    [ahead, right] metres the shooter moves from its spawn before staging
##   camera     [[t, along, side, height, look_along, look_height], ...]: along / look_along are shares of
##              the shooter -> target line (0 shooter, 1 target), side metres to its right, heights metres
##   fov        camera field of view
##   slowmo     [[from s, to s, time scale], ...] game-time windows played slowed down
## Prints "weapon_duel: slowmo_frame=<n> scale=<k>" / "weapon_duel: normal_frame=<n>" at the speed changes.

const DEFAULT_FOV := 55.0
const TARGET_TOUGHNESS := 1000.0
const AIM_HEIGHT_SHARE := 0.55
const DEFAULT_TARGET_HEIGHT := 8.0  # metres, when the vehicle data has no height_m
const SHOOTER_ENERGY := 100000.0
const SLOWMO_MARKER := "weapon_duel: slowmo_frame=%d scale=%.2f"
const NORMAL_MARKER := "weapon_duel: normal_frame=%d"

var _dummy: Herc
var _camera: Camera3D
var _time_scale := 1.0


func prepare() -> void:
	await super.prepare()
	if battle.player == null:
		return
	_dummy = _find_dummy()
	_arm_shooter(battle.player)
	if _dummy:
		_make_dummy(_dummy)
	_release_pilot()


func play() -> void:
	_playing = true


func _process(delta: float) -> void:
	if battle == null or battle.overlay == null:
		return
	_clear_messages()
	battle.overlay.visible = false
	if not _playing:
		return
	_clock += delta
	_apply_time_scale(make_time_scale(_clock))
	_apply_camera(_clock)


func _physics_process(_delta: float) -> void:
	if not _playing or not is_instance_valid(battle.player):
		return
	# the dummy may have hit the shooter with a disabling weapon (EMP) while the battle settled
	battle.player.remove_meta("disabled_until")
	_apply_aim(battle.player)
	_apply_triggers(battle.player, make_fire_set(_clock))
	if _dummy and _dummy.alive and spec.has("kill_at") and _clock >= float(spec.kill_at):
		_destroy(_dummy)


func _exit_tree() -> void:
	Engine.time_scale = 1.0


# ------------------------------------------------------------------ setup

## The shooter moves `advance` [ahead, right] metres from its spawn onto the ground (out of a base, or up
## from under an Earthsiege 2 heightmap), the dummy goes to stage[0]; any other vehicle (the parked vehicle
## of a soldier) goes to stage_allies[0], out of the line of fire.
func _stage_vehicles() -> void:
	var p := battle.player
	var adv: Array = spec.get("advance", [0.0, 0.0])
	var at: Vector3 = p.global_position - p.global_basis.z * float(adv[0]) + p.global_basis.x * float(adv[1])
	at.y = _make_ground_height(at) + STAGE_DROP
	p.global_position = at
	p.velocity = Vector3.ZERO
	var dummy := _find_dummy()
	var others := battle.vehicles.values().filter(func(v): return v != p and v != dummy and not (v is Flyer))
	if dummy:
		_stage([dummy], spec.get("stage", []))
	var aside: Array = (spec.get("stage_allies", [[-40.0, -40.0]]) as Array)[0]
	_stage(others, others.map(func(_v): return aside))

## The staged target: the vehicle of the spec's first AI entry.
func _find_dummy() -> Herc:
	var wanted := Assets.qualify(String((spec.get("ai", [{}]) as Array)[0].get("vehicle", "")))
	for v in battle.vehicles.values():
		if v != battle.player and v.vehicle_id == wanted and v.alive and not (v is Flyer):
			return v
	return null


## The shooter carries the spec's weapons (a soldier first changes armour) with energy to spare.
func _arm_shooter(h: Herc) -> void:
	if h is Infantry and spec.has("armor"):
		(h as Infantry).apply_armor(String(spec.armor), spec.get("loadout", []))
	elif spec.has("loadout"):
		h.equip(spec.loadout)
	h.capacitor_max = SHOOTER_ENERGY
	h.capacitor = SHOOTER_ENERGY
	h.end_spawn_protection()


## The dummy stands still (no pilot), keeps `target_shield` of its shields and can't fall before kill_at.
func _make_dummy(h: Herc) -> void:
	for c in h.get_children():
		if c is AIPilot:
			c.queue_free()
	h.throttle = 0.0
	h.turn = 0.0
	for w in h.weapons:
		w.trigger = false
	_apply_toughness(h, TARGET_TOUGHNESS)
	var keep := float(spec.get("target_shield", 0.0))
	h.shield_front = h.shield_max * 0.5 * keep
	h.shield_rear = h.shield_max * 0.5 * keep
	h.shield_recharge = 0.0
	h.end_spawn_protection()


## The player's controls go: this shot aims and fires.
func _release_pilot() -> void:
	if is_instance_valid(battle.pilot):
		battle.pilot.queue_free()
	battle.player.throttle = float(spec.get("throttle", 0.0))
	battle.player.turn = 0.0


func _apply_view() -> void:
	battle.use_chase = true
	battle.overlay.hud.visible = false
	battle.overlay.visible = false
	_camera = battle.cameras.chase_cam
	_camera.fov = float(spec.get("fov", DEFAULT_FOV))


# ------------------------------------------------------------------ shooting

## Weapon indices whose triggers are held at `t`.
func make_fire_set(t: float) -> Array:
	var on := []
	for cue in spec.get("fire", []):
		if t >= float(cue[0]) and t < float(cue[1]):
			on.append_array(cue[2])
	return on


func _apply_triggers(h: Herc, on: Array) -> void:
	if h is Infantry and not on.is_empty() and (h as Infantry).weapon_slot != int(on[0]):
		(h as Infantry).apply_weapon_slot(int(on[0]))
	for i in h.weapons.size():
		h.weapons[i].trigger = on.has(i) and h.alive


## Torso (soldier: body) yaw and pitch toward the dummy's middle, lifted for lobbed weapons.
func _apply_aim(h: Herc) -> void:
	if _dummy == null:
		return
	var point := make_aim_point(h)
	var dir := point - h.aim_origin()
	var frame := Basis.IDENTITY if h is Infantry else h.global_basis.orthonormalized()
	var local := frame.inverse() * dir
	h.torso_target = atan2(-local.x, -local.z)
	h.pitch_target = atan2(local.y, Vector2(local.x, local.z).length())


func make_aim_point(h: Herc) -> Vector3:
	var height := float(_dummy.def.get("height_m", DEFAULT_TARGET_HEIGHT))
	var lift := 0.0
	var lifts: Dictionary = spec.get("aim_lift", {})
	for i in h.weapons.size():
		if h.weapons[i].trigger and lifts.has(str(i)):
			lift = float(lifts[str(i)])
	var share := float(spec.get("target_height", AIM_HEIGHT_SHARE))
	return _dummy.global_position + Vector3.UP * (height * share + lift)


## Breaks every component of `h` and lands one last hit, so it dies with its own explosion.
func _destroy(h: Herc) -> void:
	h.shield_front = 0.0
	h.shield_rear = 0.0
	for c in h.components:
		c.hp = 0.0
	h.integrity = HercDamage.integrity_of(h.components)
	h.apply_hit(0.0, 1.0, battle.player, h.global_position + Vector3.UP * 4.0)
	for e in spec.get("death_fx", []):
		_play_later(e, h.global_position + Vector3(float(e[3][0]), float(e[3][1]), float(e[3][2])))


## Plays death_fx entry [effect, pack, delay s, offset] at `at` after its delay.
func _play_later(entry: Array, at: Vector3) -> void:
	if float(entry[2]) > 0.0:
		await get_tree().create_timer(float(entry[2])).timeout
	Effects.fx.play_effect(battle, String(entry[0]), String(entry[1]), at)


# ------------------------------------------------------------------ time and camera

## The time scale at `t` (1 outside the slowmo windows).
func make_time_scale(t: float) -> float:
	for w in spec.get("slowmo", []):
		if t >= float(w[0]) and t < float(w[1]):
			return float(w[2])
	return 1.0


func _apply_time_scale(k: float) -> void:
	if is_equal_approx(k, _time_scale):
		return
	_time_scale = k
	Engine.time_scale = k
	if k < 1.0:
		print(SLOWMO_MARKER % [Engine.get_process_frames(), k])
	else:
		print(NORMAL_MARKER % Engine.get_process_frames())


func _apply_camera(t: float) -> void:
	var keys: Array = spec.get("camera", [])
	if keys.is_empty() or _dummy == null or not is_instance_valid(battle.player):
		return
	var k := make_camera_key(keys, t)
	var from := battle.player.global_position
	var to := _dummy.global_position
	var fwd := Vector3(to.x - from.x, 0.0, to.z - from.z).normalized()
	var right := fwd.cross(Vector3.UP)
	var pos: Vector3 = from.lerp(to, float(k[1])) + right * float(k[2]) + Vector3.UP * float(k[3])
	var look: Vector3 = from.lerp(to, float(k[4])) + Vector3.UP * float(k[5])
	_camera.global_position = pos
	if pos.distance_to(look) > 0.1:
		_camera.look_at(look, Vector3.UP)


## Keyframe values at `t`, eased between neighbouring keys (held before the first and after the last).
static func make_camera_key(keys: Array, t: float) -> Array:
	if t <= float(keys[0][0]):
		return keys[0]
	for i in range(1, keys.size()):
		var a: Array = keys[i - 1]
		var b: Array = keys[i]
		if t < float(b[0]):
			var u := smoothstep(float(a[0]), float(b[0]), t)
			var out := [t]
			for j in range(1, a.size()):
				out.append(lerpf(float(a[j]), float(b[j]), u))
			return out
	return keys[keys.size() - 1]

extends Node3D
## The Earthsiege missile camera and the player-steered EO missile (docs/MISSILE_CAM.md), headless:
##   steer    a player's EO missile follows the injected stick: its path bends and it hits a target well off its
##            launch line; its fire group does not refire while it is steered; after the missile is gone the held
##            trigger must be released first
##   release  letting go of the trigger leaves the EO missile flying straight, unguided
##   ignore   a non-steerable missile (SARH without a target) and an AI pilot's EO missile ignore the stick
##   camera   the camera follows only Earthsiege missiles of a player, not another game's weapons; it ends on impact
##            (after the hit hold) and is inactive with no missile
##   net      the steering stick travels in the client controls and in the snapshot (appended at index 16)
##   godot --headless --audio-driver Dummy --path game res://tests/missile_cam_check.tscn

const PILOT_ID := "es1:RAPTOR"
const TARGET_ID := "es1:APOLLO"
const EO_RACK := "es1:MLRS6_EO"
const SARH_RACK := "es1:MLRS6_SARH"
const FOREIGN_MISSILE := "starsiege:SPR6"
## Target: 150 m out, 40 m to the right of the launch line (15 degrees off), so a straight missile misses it.
const TARGET_AT := Vector3(40, 0, -150)
const STEER_GAIN := 4.0
const MAX_FRAMES := 600
const STRAIGHT_FRAMES := 30
const MIN_BEND_DEG := 8.0
const STRAIGHT_TOLERANCE_DEG := 0.5

var _failures := 0


func _ready() -> void:
	_build_floor()
	await _check_steering()
	await _check_release()
	await _check_ignored()
	await _check_camera()
	_check_net()
	_check_pitch()
	await _check_placement()
	print("missile_cam_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


## The battle's effect channel as Weapon calls it (nothing to show headless).
func fx(_kind: String, _args: Array, _reliable := false) -> void:
	pass


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _build_floor() -> void:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 1, 4000)
	col.shape = box
	body.add_child(col)
	add_child(body)
	body.global_position = Vector3(0, -0.5, 0)


func _spawn(id: String, at: Vector3, team: int, loadout: Array, ai := false) -> Herc:
	var h := Herc.new()
	h.vehicle_id = id
	h.team = team
	h.position = at
	if ai:
		h.set_meta("ai", true)
	add_child(h)
	h.set_physics_process(false)
	h.equip(loadout)
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	for p in get_tree().get_nodes_in_group("projectiles"):
		p.queue_free()
	await get_tree().physics_frame


## Pulls `w`'s trigger and fires one missile; returns it (null when none flew).
func _launch(w: Weapon) -> Projectile:
	w.trigger = true
	w.fire()
	var shots := get_tree().get_nodes_in_group("projectiles")
	return shots.back() as Projectile if not shots.is_empty() else null


## The stick that turns heading `h` toward world point `at` from `from` (x right, y nose down).
static func _make_stick_toward(h: Vector3, from: Vector3, at: Vector3) -> Vector2:
	var want := (at - from).normalized()
	var turn := -h.cross(want).y
	return Vector2(clampf(turn * STEER_GAIN, -1, 1), clampf(-(want.y - h.y) * STEER_GAIN, -1, 1))


static func _angle_deg(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.angle_to(b))


# ------------------------------------------------------------------ steer

func _check_steering() -> void:
	var pilot := _spawn(PILOT_ID, Vector3.ZERO, 0, [EO_RACK])
	var target := _spawn(TARGET_ID, TARGET_AT, 1, [], true)
	await get_tree().physics_frame
	_expect(not pilot.weapons.is_empty() and pilot.weapons[0].weapon_id == EO_RACK, "the pilot carries the EO rack")
	if pilot.weapons.is_empty():
		return
	var w: Weapon = pilot.weapons[0]
	var m := _launch(w)
	_expect(m != null and m.guidance == "eo", "an EO missile flies")
	if m == null:
		return
	var steer := pilot.missile_steering
	_expect(steer.is_steering_missile(m) and steer.tracked == m, "the player's EO missile is tracked and steered")
	var start := m.make_heading()
	var health := target.shield_front + target.shield_rear + target.integrity
	var bend := 0.0
	var refired := false
	for i in MAX_FRAMES:
		if not is_instance_valid(m):
			break
		steer.stick = _make_stick_toward(m.make_heading(), m.global_position, target.global_position + Vector3.UP * 4.0)
		bend = maxf(bend, _angle_deg(start, m.make_heading()))
		w.cooldown = 0.0
		refired = refired or w.ready_to_fire()
		await get_tree().physics_frame
	_expect(bend >= MIN_BEND_DEG, "the steered path bends (%.1f degrees)" % bend)
	_expect(target.shield_front + target.shield_rear + target.integrity < health, "the steered missile hits the off-axis target")
	_expect(not refired, "the rack does not refire while its missile is steered")
	await get_tree().physics_frame
	_expect(not steer.is_steering() and steer.is_group_blocked(w.group), "after the hit the held trigger stays latched")
	w.trigger = false
	await get_tree().physics_frame
	_expect(not steer.is_group_blocked(w.group), "releasing the trigger frees the rack")
	await _clear([pilot, target])


# ------------------------------------------------------------------ release

func _check_release() -> void:
	var pilot := _spawn(PILOT_ID, Vector3.ZERO, 0, [EO_RACK])
	await get_tree().physics_frame
	var w: Weapon = pilot.weapons[0]
	var m := _launch(w)
	await get_tree().physics_frame
	w.trigger = false
	await get_tree().physics_frame
	_expect(is_instance_valid(m) and m.guidance == "none" and not pilot.missile_steering.is_steering(),
		"letting go of the trigger leaves the EO missile unguided")
	var h := m.make_heading()
	pilot.missile_steering.stick = Vector2(1, -1)
	for i in STRAIGHT_FRAMES:
		await get_tree().physics_frame
	_expect(is_instance_valid(m) and _angle_deg(h, m.make_heading()) < STRAIGHT_TOLERANCE_DEG, "the released missile flies straight")
	await _clear([pilot])


# ------------------------------------------------------------------ ignore

func _check_ignored() -> void:
	var pilot := _spawn(PILOT_ID, Vector3.ZERO, 0, [SARH_RACK])
	var ai := _spawn(PILOT_ID, Vector3(-200, 0, 0), 0, [EO_RACK], true)
	await get_tree().physics_frame
	var m := _launch(pilot.weapons[0])
	var am := _launch(ai.weapons[0])
	_expect(m != null and not pilot.missile_steering.is_steering(), "a SARH missile is not steered")
	_expect(am != null and am.guidance == "eo" and not ai.missile_steering.is_steering() and ai.missile_steering.tracked == null,
		"an AI pilot's EO missile is neither steered nor tracked")
	var h := m.make_heading()
	var ah := am.make_heading()
	pilot.missile_steering.stick = Vector2(1, 1)
	ai.missile_steering.stick = Vector2(-1, -1)
	for i in STRAIGHT_FRAMES:
		await get_tree().physics_frame
	_expect(is_instance_valid(m) and _angle_deg(h, m.make_heading()) < STRAIGHT_TOLERANCE_DEG, "the SARH missile ignores the stick")
	_expect(is_instance_valid(am) and _angle_deg(ah, am.make_heading()) < STRAIGHT_TOLERANCE_DEG, "the AI's EO missile ignores the stick")
	await _clear([pilot, ai])


# ------------------------------------------------------------------ camera

func _check_camera() -> void:
	var pilot := _spawn(PILOT_ID, Vector3.ZERO, 0, [SARH_RACK])
	var wall := _spawn(TARGET_ID, Vector3(0, 0, -60), 1, [], true)
	var cam := MissileCam.new(pilot)
	add_child(cam)
	await get_tree().physics_frame
	_expect(not cam.is_active(), "no missile: the camera is off")
	var foreign := Packs.weapon(FOREIGN_MISSILE)
	_expect(not foreign.is_empty() and not MissileSteering.is_tracked_kind(foreign, pilot), "a Starsiege missile gets no camera")
	_expect(not MissileSteering.is_tracked_kind(Packs.weapon("bd:EAGLE_5"), pilot), "a Battledrome missile gets no camera")
	var fp := Weapon.make_projectile(foreign, pilot, Vector3(0, 3, 0), Vector3.FORWARD, null)
	add_child(fp)
	pilot.missile_steering.adopt(fp, 1)
	await get_tree().process_frame
	_expect(pilot.missile_steering.tracked == null and not cam.is_active(), "the camera ignores another game's missile")
	if is_instance_valid(fp):
		fp.queue_free()
	var m := _launch(pilot.weapons[0])
	await get_tree().process_frame
	_expect(cam.is_flying() and pilot.missile_steering.tracked == m, "an Earthsiege missile starts the camera (any guidance)")
	var to_missile := m.global_position - cam.camera.global_position
	var off_line := _angle_deg(-cam.camera.global_basis.z, to_missile)
	_expect(off_line < 1.0 and to_missile.length() >= MissileCam.BEHIND_UNITS * Assets.UNIT - 0.01,
		"the eye sits behind the missile, looking along its flight (%.2f deg off)" % off_line)
	var hit := false
	for i in MAX_FRAMES:
		await get_tree().physics_frame
		if not is_instance_valid(m):
			hit = true
			break
	await get_tree().process_frame
	_expect(hit and not cam.is_flying() and cam.is_showing_hit(), "on impact the camera stops following and holds the hit")
	await get_tree().create_timer(MissileCam.HIT_HOLD_SECONDS + 0.3).timeout
	_expect(not cam.is_active(), "after the hit hold the camera ends")
	cam.queue_free()
	await _clear([pilot, wall])


# ------------------------------------------------------------------ net

func _check_net() -> void:
	var pilot := Herc.new()
	pilot.missile_steering.stick = Vector2(0.5, -0.25)
	var c := BattleNetSync.make_controls(pilot)
	_expect(not c.has("missile_steer"), "no steering in the controls without a steered missile")
	var p := Projectile.new()
	p.guidance = "eo"
	p.weapon_def = Packs.weapon(EO_RACK)
	pilot.missile_steering.adopt(p, 1)
	pilot.missile_steering.stick = Vector2(0.5, -0.25)
	c = BattleNetSync.make_controls(pilot)
	_expect(c.get("missile_steer") == Vector2(0.5, -0.25), "the client sends the stick while steering")
	_expect(HercSnapshots.SNAP_MISSILE_STEER == HercSnapshots.SNAP_DAMAGE + 2 and Infantry.SNAP_INFANTRY == HercSnapshots.SNAP_DAMAGE + 1,
		"snapshot: steering appended after the damage and soldier fields")
	p.free()
	pilot.missile_steering.free()
	pilot.free()


# ------------------------------------------------------------------ pitch setting / window placement

func _check_pitch() -> void:
	_expect(MissileSteering.is_pitch_reversed(MissileSteering.PITCH_GAME, "es1")
		and not MissileSteering.is_pitch_reversed(MissileSteering.PITCH_GAME, "es2"),
		"as the original: ES1 up steers down (KEYJOY.CFG REVERSE), ES2 up steers up")
	_expect(not MissileSteering.is_pitch_reversed(MissileSteering.PITCH_UP_IS_UP, "es1")
		and MissileSteering.is_pitch_reversed(MissileSteering.PITCH_UP_IS_DOWN, "es2"), "the explicit pitch modes")


func _check_placement() -> void:
	var pilot := _spawn(PILOT_ID, Vector3.ZERO, 0, [EO_RACK])
	var overlay := BattleOverlay.new()
	add_child(overlay)
	var screen := [Vector2.ZERO]
	overlay.occupied_provider = func() -> Array:
		var c := overlay.cockpit
		return ChatPlacement.make_screen_rects(CockpitOccupancy.make_rects(c), c.canvas_size, screen[0])
	overlay.build_cockpit(pilot, self)
	await get_tree().process_frame
	var win := overlay.missile_cam_window
	for sz in [Vector2(1280, 800), Vector2(1920, 1080), Vector2(1024, 768)]:
		screen[0] = sz
		win.apply_placement(sz)
		var r := win.placed_rect
		_expect(ChatPlacement.is_clear(r, overlay.make_occupied_rects()) and Rect2(Vector2.ZERO, sz).encloses(r),
			"at %dx%d the window %s keeps clear of the cockpit panels" % [sz.x, sz.y, r])
	overlay.queue_free()
	await _clear([pilot])

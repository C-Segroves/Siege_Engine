extends Node
## The cheap body step of far AI soldiers (engine/infantry/infantry_cheap_step.gd): a soldier with far_lod follows the
## ground by rays, stops at a wall, jumps and lands (fall damage included), and the real body takes over again at
## promotion without a jump.
##   godot --headless --audio-driver Dummy --path game res://tests/infantry_cheap_step_check.tscn
## Prints "infantry_cheap_step_check: OK" or "FAILED"; exit code 0 / 1.

const MAP := "tribes:Raindance"
const SETTLE_FRAMES := 20
const STEP := 1.0 / 30.0
const RUN_STEPS := 60
const WALL_AT := 12.0
const COST_STEPS := 1000

var _failures := 0
var _battle: Battle
var _soldier: Infantry


func _ready() -> void:
	await get_tree().process_frame
	await _start_battle()
	_check_follows_ground()
	await _check_wall()
	await _check_jump_and_landing()
	await _check_promotion()
	_report_cost()
	print("infantry_cheap_step_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _start_battle() -> void:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": []}, true)
	_battle = load("res://games/es1/battle.tscn").instantiate()
	_battle.config = config
	get_tree().root.add_child(_battle)
	get_tree().current_scene = _battle
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	_battle.bounds.set_physics_process(false)
	_soldier = _battle.player as Infantry
	_soldier.set_physics_process(false)   # the check steps him by hand
	_soldier.far_lod = true
	_place(Vector3(0.0, 0.0, 0.0))


func _place(at: Vector3) -> void:
	at.y = MapBuilder.ground_height(_battle, at) + 0.3
	_soldier.global_position = at
	_soldier.velocity = Vector3.ZERO
	_soldier.cheap_floor = false


func _step(n: int) -> void:
	for i in n:
		_soldier._drive(STEP)


func _ground_offset() -> float:
	return _soldier.global_position.y - MapBuilder.ground_height(_battle, _soldier.global_position)


func _check_follows_ground() -> void:
	print("follows the ground:")
	_soldier.throttle = 1.0
	_soldier.torso_target = -PI / 2.0   # facing +x
	var from := _soldier.global_position
	_step(RUN_STEPS)
	var run := Vector2(_soldier.global_position.x - from.x, _soldier.global_position.z - from.z).length()
	_expect(run > 8.0, "he ran %.1f m in 2 s" % run)
	_expect(absf(_ground_offset()) < 0.35, "he stands on the terrain (%.2f m off)" % _ground_offset())
	_expect(_soldier.cheap_floor, "the cheap step knows he is on the floor")
	_soldier.throttle = 0.0


func _check_wall() -> void:
	print("wall:")
	_place(Vector3(100.0, 0.0, 100.0))
	var wall := StaticBody3D.new()
	var box := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.0, 30.0, 40.0)
	box.shape = shape
	wall.add_child(box)
	_battle.add_child(wall)
	wall.global_position = _soldier.global_position + Vector3(WALL_AT, 0.0, 0.0)
	await get_tree().physics_frame
	_soldier.throttle = 1.0
	_soldier.torso_target = -PI / 2.0
	var start_x := _soldier.global_position.x
	_step(RUN_STEPS * 2)
	var reached := _soldier.global_position.x - start_x
	_expect(reached > WALL_AT - 3.0 and reached < WALL_AT - 0.4, "he stopped %.1f m before the wall's face (%.1f m away)" % [WALL_AT - 0.5 - reached, WALL_AT - 0.5])
	_soldier.throttle = 0.0
	wall.queue_free()


func _check_jump_and_landing() -> void:
	print("jump and landing:")
	_place(Vector3(200.0, 0.0, 200.0))
	_step(15)
	var base := _soldier.global_position.y
	_soldier.jump_input = true
	_step(1)
	_soldier.jump_input = false
	_expect(not _soldier.cheap_floor and _soldier.global_position.y > base, "a jump leaves the floor")
	var peak := base
	for i in 60:
		_step(1)
		peak = maxf(peak, _soldier.global_position.y)
		if _soldier.cheap_floor:
			break
	_expect(peak > base + 0.8, "he rose %.1f m" % (peak - base))
	_expect(_soldier.cheap_floor and absf(_ground_offset()) < 0.35, "he landed on the ground")
	await _check_fall_damage()


## Dropped from high above he lands hard: the armour's fall rule hurts him as move_and_slide would.
func _check_fall_damage() -> void:
	_soldier.end_spawn_protection()
	var hp := _soldier.integrity
	var at := _soldier.global_position
	at.y += 60.0
	_soldier.global_position = at
	_soldier.cheap_floor = false
	_soldier.velocity = Vector3(0.0, -5.0, 0.0)
	_step(120)
	_expect(_soldier.cheap_floor and absf(_ground_offset()) < 0.35, "after a 60 m drop he is on the ground again")
	_expect(_soldier.integrity < hp or not _soldier.alive, "the fall hurt him (integrity %.2f -> %.2f)" % [hp, _soldier.integrity])
	if not _soldier.alive:
		_soldier.respawn(Transform3D(Basis(), _soldier.global_position))


func _check_promotion() -> void:
	print("promotion:")
	_soldier.integrity = 1.0
	_place(Vector3(300.0, 0.0, 300.0))
	_step(10)
	var before := _soldier.global_position
	_soldier.far_lod = false
	_step(3)
	_expect((_soldier.global_position - before).length() < 0.5, "promoted: no jump (moved %.2f m)" % (_soldier.global_position - before).length())
	_expect(_soldier.is_on_floor() and absf(_ground_offset()) < 0.35, "the real body is on the floor")


## Microseconds per cheap step including _drive (printed, not asserted; move_and_slide cannot be timed this way: the
## teleports between runs make the physics server rebuild its state).
func _report_cost() -> void:
	_soldier.far_lod = true
	_soldier.throttle = 1.0
	_soldier.torso_target = -PI / 2.0
	_place(Vector3(400.0, 0.0, 400.0))
	_step(5)
	var t0 := Time.get_ticks_usec()
	_step(COST_STEPS)
	print("cost: cheap step %.1f us per _drive" % (float(Time.get_ticks_usec() - t0) / COST_STEPS))

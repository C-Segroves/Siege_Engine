extends Node3D
## FarBots (docs/DEDICATED_SERVER_SCALING.md chunk L): the proxy of a far unit interpolates between low-rate poses,
## slots are reused when units are promoted (removed), and 200 proxies fill the instance buffers.
##   godot --headless --audio-driver Dummy --path game res://tests/far_bots_check.tscn
## Prints "far_bots_check: OK|FAILED (<n> failures)"; exit code 0 / 1.

const BOT_COUNT := 200
const POSE_SECONDS := 0.4
const STEP_M := 10.0

var _failures := 0
var _bots: FarBots


func _ready() -> void:
	_bots = FarBots.new()
	add_child(_bots)
	_check_interpolation()
	_check_promotion_slots()
	_check_many()
	print("far_bots_check: %s" % ("OK" if _failures == 0 else "FAILED (%d failures)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		printerr("far_bots_check FAIL: ", what)


func _check_interpolation() -> void:
	_bots.apply_pose(1, FarBots.Kind.SOLDIER, Vector3.ZERO, 0.0, POSE_SECONDS)
	_bots.advance(0.0)
	_bots.apply_pose(1, FarBots.Kind.SOLDIER, Vector3(STEP_M, 0.0, 0.0), 1.0, POSE_SECONDS)
	_bots.advance(POSE_SECONDS * 0.5)
	var half := _bots.make_pose(1)
	_expect(absf(half.pos.x - STEP_M * 0.5) < 0.01, "halfway between two poses, got %s" % half.pos)
	_bots.advance(POSE_SECONDS)
	_expect(absf(_bots.make_pose(1).pos.x - STEP_M) < 0.01, "arrives at the newest pose and stays there")
	_bots.apply_alive(1, false)
	_expect(not _bots.make_pose(1).alive, "a dead unit is flagged")
	_bots.remove(1)
	_expect(_bots.count() == 0 and _bots.make_pose(1).is_empty(), "removed")


func _check_promotion_slots() -> void:
	for id in range(10, 14):
		_bots.apply_pose(id, FarBots.Kind.VEHICLE, Vector3(id, 0.0, 0.0), 0.0, POSE_SECONDS)
	_bots.remove(10)
	_bots.remove(13)
	_expect(_bots.count() == 2 and _bots.has(11) and _bots.has(12), "two left after promoting two")
	_expect(absf(_bots.make_pose(12).pos.x - 12.0) < 0.01, "a moved slot keeps its own pose")
	_bots.remove(11)
	_bots.remove(12)


func _check_many() -> void:
	for id in BOT_COUNT:
		var kind := FarBots.Kind.SOLDIER if id % 2 == 0 else FarBots.Kind.VEHICLE
		_bots.apply_pose(id, kind, Vector3(id * 5.0, 0.0, 0.0), 0.0, POSE_SECONDS)
	_bots.advance(0.016)
	_expect(_bots.count() == BOT_COUNT, "200 proxies")
	var drawn := 0
	for child in _bots.get_children():
		drawn += (child as MultiMeshInstance3D).multimesh.visible_instance_count
	_expect(drawn == BOT_COUNT, "all drawn through the multimeshes (%d)" % drawn)
	for id in BOT_COUNT:
		_bots.remove(id)
	_bots.advance(0.016)
	_expect(_bots.count() == 0, "all promoted")

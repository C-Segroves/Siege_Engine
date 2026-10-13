extends Node3D
## Death effects of every installed pack (docs/formats/weapon_fx.md section 9, engine/fx/death_fx.gd), headless:
##   1. the pack's library describes a unit death and a structure death, and every step names a known effect;
##   2. each case (unit death, component, structure, turret, soldier, grenade burst: DeathFxStage) plays the
##      pack's own library effects (Effects.fx.effects_played) when its entry has steps, none when the game
##      shows nothing (Tribes soldiers), and never the generic explosion (Effects.fx.generic_explosions);
##   3. no engine / script errors.
## godot --headless --audio-driver Dummy --path game res://tests/death_fx_check.tscn [-- --pack=es1]

const Stage := preload("res://tests/death_fx_stage.gd")
## Seconds a case is watched (the longest step delay of the shipped data is the ES1 base sequence, 0.7 s).
const WATCH_S := 1.2
const CASE_SPACING := 60.0
const REQUIRED_KINDS := [DeathFx.KIND_VEHICLE, DeathFx.KIND_STRUCTURE]

var _failures := 0
var _cases := 0
var _errors := ErrorCounter.new()
var _only_pack := ""


## Counts engine and script errors (any is a failure).
class ErrorCounter extends Logger:
	var count := 0

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_WARNING:
			count += 1


func _ready() -> void:
	OS.add_logger(_errors)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pack="):
			_only_pack = a.substr(7)
	var cam := Camera3D.new()
	add_child(cam)
	for pack in Assets.installed_packs():
		if _only_pack == "" or pack == _only_pack:
			_check_data(pack)
			await _check_cases(pack)
	_expect(Effects.fx.generic_explosions == 0, "the generic explosion was never used (%d)" % Effects.fx.generic_explosions)
	_expect(_errors.count == 0, "no engine / script errors (%d)" % _errors.count)
	OS.remove_logger(_errors)
	print("death_fx_check: %d cases, %s (%d failures)" % [_cases, "OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _check_data(pack: String) -> void:
	print("pack %s" % pack)
	for kind in REQUIRED_KINDS:
		var entry := FxLibrary.death(pack, kind)
		_expect(not entry.get("steps", []).is_empty(), "%s %s death has steps (%s)" % [pack, kind, entry.get("source", "none")])
	var deaths: Dictionary = FxLibrary.library(pack).get("deaths", {})
	var unknown := []
	for entry in _entries(deaths):
		for step in entry.get("steps", []):
			for ref in step.get("effects", []):
				if FxLibrary.effect(str(ref), pack).is_empty():
					unknown.append(ref)
	_expect(unknown.is_empty(), "%s death steps name known effects %s" % [pack, unknown])


static func _entries(deaths: Dictionary) -> Array:
	var out := []
	for key in deaths:
		var v = deaths[key]
		if not (v is Dictionary):
			continue
		if v.has("steps"):
			out.append(v)
		else:
			out.append_array(v.values().filter(func(e): return e is Dictionary))
	return out


func _check_cases(pack: String) -> void:
	var cases := Stage.make_cases(pack)
	for i in cases.size():
		await _run_case(pack, cases[i], Vector3(i * CASE_SPACING, 0, 0))


func _run_case(pack: String, c: Dictionary, at: Vector3) -> void:
	_cases += 1
	var stage := Node3D.new()
	add_child(stage)
	var generic_before := Effects.fx.generic_explosions
	var played_before := Effects.fx.effects_played
	c.run.call(stage, at)
	await _wait(WATCH_S)
	var played := Effects.fx.effects_played - played_before
	if _expects_effects(pack, c):
		_expect(played > 0, "%s plays %d %s library effects" % [c.label, played, pack])
	else:
		_expect(played == 0, "%s plays nothing, as the original (%d)" % [c.label, played])
	_expect(Effects.fx.generic_explosions == generic_before, "%s: no generic explosion" % c.label)
	stage.queue_free()
	await get_tree().process_frame


## Whether the case's data names effects: its death entry has steps (a burst: the item names one).
func _expects_effects(pack: String, c: Dictionary) -> bool:
	if str(c.kind) == "burst":
		return true
	return not FxLibrary.death(pack, str(c.kind)).get("steps", []).is_empty()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

extends Node
## TargetSelector (engine/targeting/target_selector.gd) against an independent brute-force reference, on a fixed
## layout of stub units (no pack needed):
##   godot --headless --audio-driver Dummy --path game res://tests/target_selector_check.tscn
## Golden style: the layout is built from a seeded generator and the picks of 24 shooters are compared with the
## reference's, then the same picks must repeat on a second run. Plus the rules one at a time: hostility, strict range,
## dormant / dead, signature weighting, the jam radius and the arc veto, stickiness. Prints "target_selector_check: OK".

const SEED := 20261022
const UNITS := 40
const SHOOTERS := 24
const FIELD_M := 600.0


class Stub extends Node3D:
	var alive := true
	var team := 1


var _failures := 0


func _ready() -> void:
	var units := _make_units()
	var first := _pick_all(units)
	_expect(first == _reference_all(units), "the picks equal the brute-force nearest hostile")
	_expect(first == _pick_all(units), "the same layout picks the same targets again")
	_expect(first.count(-1) < SHOOTERS, "the golden layout finds targets")
	_check_rules()
	print("target_selector_check: %s" % ("OK" if _failures == 0 else "FAILED (%d)" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _make_units() -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var out := []
	for i in UNITS:
		var u := Stub.new()
		u.team = 1 + i % 3
		u.position = Vector3(rng.randf_range(-FIELD_M, FIELD_M), 0.0, rng.randf_range(-FIELD_M, FIELD_M))
		u.add_to_group(TargetSelector.VEHICLES)
		add_child(u)
		out.append(u)
	return out


func _shooter_at(i: int) -> Vector3:
	return Vector3(sin(i * 1.7) * 400.0, 0.0, cos(i * 2.3) * 400.0)


func _profile(range_m: float) -> TargetProfile:
	return TargetProfile.make_turret().with_range(range_m)


func _pick_all(units: Array) -> Array:
	var out := []
	for i in SHOOTERS:
		var t := TargetSelector.pick(get_tree(), _profile(300.0), {"from": _shooter_at(i), "team": 1 + i % 3})
		out.append(units.find(t))
	return out


func _reference_all(units: Array) -> Array:
	var out := []
	for i in SHOOTERS:
		var best := -1
		var best_d := 300.0
		for k in units.size():
			var d := _shooter_at(i).distance_to(units[k].position)
			if units[k].team != 1 + i % 3 and d < best_d:
				best_d = d
				best = k
		out.append(best)
	return out


func _stub(pos: Vector3, team := 2) -> Stub:
	var u := Stub.new()
	u.team = team
	u.position = pos
	u.add_to_group(TargetSelector.VEHICLES)
	add_child(u)
	return u


func _clear(units: Array) -> void:
	for u in units:
		u.remove_from_group(TargetSelector.VEHICLES)
		u.queue_free()


func _check_rules() -> void:
	var existing := get_tree().get_nodes_in_group(TargetSelector.VEHICLES)
	for u in existing:
		u.remove_from_group(TargetSelector.VEHICLES)
	var ctx := {"from": Vector3.ZERO, "team": 1}
	var near := _stub(Vector3(50, 0, 0))
	var far := _stub(Vector3(90, 0, 0))
	var friend := _stub(Vector3(10, 0, 0), 1)
	var pick := func(profile: TargetProfile) -> Node3D: return TargetSelector.pick(get_tree(), profile, ctx)
	_expect(pick.call(_profile(100.0)) == near, "nearest hostile wins, a teammate is never picked")
	_expect(pick.call(_profile(50.0)) == null, "range is strict: a unit exactly at range is out")
	_expect(pick.call(_profile(INF)) == near, "unlimited range works")
	TeamRelations.apply_neutral(1, 2)
	_expect(pick.call(_profile(100.0)) == null, "a neutral team is left alone (TeamRelations)")
	TeamRelations.clear()
	near.set_meta("dormant", true)
	_expect(pick.call(_profile(100.0)) == far, "a dormant unit is skipped")
	near.remove_meta("dormant")
	near.alive = false
	_expect(pick.call(_profile(100.0)) == far, "a dead unit is skipped")
	near.alive = true
	var passive := _profile(100.0)
	passive.weigh_signature = true
	RadarMode.apply_emitting(near, false)
	_expect(pick.call(passive) == far, "a passive unit is seen from half as far (50 m / 0.5 = 100 m, out)")
	RadarMode.apply_emitting(near, true)
	var eyes := _profile(100.0)
	eyes.visibility = TargetProfile.Visibility.EYES
	near.set_meta(InfantryPack.META_JAM_RADIUS, 30.0)
	_expect(pick.call(eyes) == far, "a jamming unit hides beyond its jam radius")
	near.remove_meta(InfantryPack.META_JAM_RADIUS)
	var veto := func(v: Node3D, _p: Vector3) -> bool: return v == far
	ctx.accepts = veto
	_expect(pick.call(_profile(100.0)) == far, "the arc / sight veto passes the nearest unit that survives it")
	ctx.erase("accepts")
	var held := _profile(60.0)
	held.keep_buffer = 40.0
	_expect(TargetSelector.keeps(held, ctx, far), "a held target is kept inside range + buffer")
	_expect(not TargetSelector.keeps(held, ctx, _stub(Vector3(101, 0, 0))), "and dropped beyond it")
	_expect(not TargetSelector.keeps(held, ctx, friend), "and dropped when it is not hostile")
	_clear(get_tree().get_nodes_in_group(TargetSelector.VEHICLES))


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		printerr("target_selector_check FAIL: %s" % what)

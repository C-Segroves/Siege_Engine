extends Node
## 3Space damage components (headless): every ES1 / ES2 Herc and Cybrid names each DMG row by its
## index (docs/formats/gameplay.md section 5), so Cybrid legs count as legs and the leg speed cap
## applies to them; the 1-hp placeholder rows (rear legs of a biped) never cap the speed.
##   godot --headless --audio-driver Dummy --path game res://tests/damage_component_check.tscn

const PACKS := ["es1", "es2"]
## DMG index of the left quadriceps (tools/units.py BODY_COMPONENTS).
const LEFT_QUAD := 7
## DMG index of the first extra (rear leg) part.
const REAR_LEFT_QUAD := 13

var _failures := 0


func _ready() -> void:
	_check_every_component_named()
	_check_cybrid_leg_cap("es1:APOLLO")
	_check_cybrid_leg_cap("es2:HYPERION")
	_check_placeholder_never_caps("es1:RAPTOR")
	_check_quadruped_rear_leg_caps("es1:BULLDOG")
	print("damage_component_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _check_every_component_named() -> void:
	print("component names:")
	for id in Packs.vehicles:
		var v: Dictionary = Packs.vehicles[id]
		if not str(v.get("pack", "")) in PACKS or v.get("flyer", false):
			continue
		var unnamed := []
		for c in v.get("damage", {}).get("components", []):
			if str(c.get("name", "")) == "":
				unnamed.append(int(c.get("index", -1)))
		if not unnamed.is_empty():
			_expect(false, "%s names every DMG row (unnamed %s)" % [id, unnamed])
			return
	_expect(true, "every ES1 / ES2 mech names every DMG row")


func _check_cybrid_leg_cap(id: String) -> void:
	var comps := HercDamage.make_components(Packs.vehicle(id))
	_expect(comps.size() > LEFT_QUAD and str(comps[LEFT_QUAD].name) == "LEFT_QUAD", "%s row %d is LEFT_QUAD" % [id, LEFT_QUAD])
	comps[LEFT_QUAD].hp = 0.0
	_expect(HercDamage.leg_speed_factor(comps) == HercDamage.LEG_DESTROYED_SPEED, "%s destroyed leg caps the speed" % id)


func _check_placeholder_never_caps(id: String) -> void:
	var comps := HercDamage.make_components(Packs.vehicle(id))
	comps[REAR_LEFT_QUAD].hp = 0.0
	_expect(HercDamage.leg_speed_factor(comps) == 1.0, "%s 1-hp placeholder %s does not cap the speed"
		% [id, comps[REAR_LEFT_QUAD].name])


func _check_quadruped_rear_leg_caps(id: String) -> void:
	var comps := HercDamage.make_components(Packs.vehicle(id))
	comps[REAR_LEFT_QUAD].hp = 0.0
	_expect(HercDamage.leg_speed_factor(comps) == HercDamage.LEG_DESTROYED_SPEED, "%s destroyed rear leg caps the speed" % id)

extends Node
## Infantry damage probe (PLAYTEST_2026-10-11b G2: deaths from what felt like small drops). Logs every damage
## event and death of every soldier and vehicle - who, how much, the damage type, the kill cause, the attacker,
## where, how fast, on the floor or not - through scripted scenarios on a Tribes and a Tribes 2 map:
##   idle        standing at the spawn
##   slope       running / skiing at speed into and along a slope
##   drop        drops of 5, 10, 15 and 20 m onto terrain, and onto a building's roof
##   ceiling     jetting up into a building from below its roof
##   vehicle     boarding a parked Herc, driving it, getting out at speed; standing next to it
##   bots        a short match with infantry bots
## A surprise is damage or a death from the world (no attacker, or a fall / collision / bounds / stuck cause) that
## the scenario did not mean (its own drop above the armour's threshold); the probe fails on one. Weapon hits in the
## bots' fight (own splash included) are logged, not surprises.
##   godot --headless --audio-driver Dummy --path game res://tests/damage_probe.tscn [-- <map ids>]

const MAPS := ["tribes:Raindance", "tribes2:Katabatic"]
const SETTLE_FRAMES := 30
const DROPS_M := [5.0, 10.0, 15.0, 20.0]

var _events: Array[Dictionary] = []
var _hp := {}                  # unit -> last hp
var _watched := {}             # unit -> true
var _scenario := ""
## Scenarios whose damage to the probed soldier is expected (a fall from above the armour's threshold).
var _expected_damage := false
var _probe: Infantry
var _surprises := 0


func _ready() -> void:
	await get_tree().process_frame
	var maps: Array = Array(OS.get_cmdline_user_args()).filter(func(a: String) -> bool: return not a.begins_with("--"))
	for map in (maps if not maps.is_empty() else MAPS):
		await _run_map(str(map))
	print("damage_probe: %s (%d surprise events)" % ["OK" if _surprises == 0 else "FAILED", _surprises])
	get_tree().quit(1 if _surprises > 0 else 0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	await get_tree().create_timer(s, true, true).timeout


# ------------------------------------------------------------------ logging

func _process(_delta: float) -> void:
	var battle := get_tree().current_scene as Battle
	if battle == null:
		return
	for v in battle.vehicles.values():
		if is_instance_valid(v) and not _watched.has(v):
			_watched[v] = true
			_hp[v] = _total_hp(v)
			(v as Herc).damaged.connect(_on_damaged)
			(v as Herc).destroyed.connect(_on_destroyed)


static func _total_hp(h: Herc) -> float:
	var t := 0.0
	for c in h.components:
		t += float(c.hp)
	return t


func _on_damaged(h: Herc, attacker: Node) -> void:
	var now := _total_hp(h)
	var lost := float(_hp.get(h, now)) - now
	_hp[h] = now
	if lost > 0.0:
		_record(h, attacker, "hit", lost)


func _on_destroyed(h: Herc, killer: Node) -> void:
	_record(h, killer, "DEATH", 0.0)
	_hp[h] = _total_hp(h)


func _record(h: Herc, other: Node, what: String, lost: float) -> void:
	var e := {"scenario": _scenario, "unit": KillText.make_unit_label(h), "what": what, "lost": lost,
		"type": DamageTypes.current, "cause": str(h.get_meta(KillText.CAUSE_META, "")),
		"by": KillText.make_unit_label(other) if other else "-", "pos": h.global_position, "vel": h.velocity,
		"floor": h.is_on_floor(), "text": KillText.make_kill_text(h, other) if what == "DEATH" else ""}
	# expected: the probe soldier's own scenario hit, or any hit a named weapon / vehicle dealt (a fight)
	# a bot's fall after jetting high is the game's own rule (impact above the threshold, logged with its speed)
	var bot_fall: bool = h != _probe and e.cause == KillText.CAUSE_FALL
	e["expected"] = (_expected_damage and h == _probe) or bot_fall or (other != null and is_instance_valid(other) and e.cause == "")
	_events.append(e)
	print("  [%s] %s %s %.0f type=%s cause=%s by=%s pos=%s vel=%s floor=%s %s %s" % [e.scenario, e.unit, what, lost,
		e.type, e.cause, e.by, e.pos.snapped(Vector3.ONE * 0.1), e.vel.snapped(Vector3.ONE * 0.1), e.floor, e.text,
		"(expected)" if e.expected else "SURPRISE"])
	if not e.expected and h is Infantry:
		_surprises += 1


# ------------------------------------------------------------------ scenarios

func _run_map(map: String) -> void:
	print("== ", map)
	var battle := await _start_battle(map, 0)
	_probe = battle.player as Infantry
	if _probe == null:
		print("  no soldier: skipped")
		battle.queue_free()
		return
	_probe.end_spawn_protection()
	battle.pilot.set_physics_process(false)
	await _idle(battle)
	await _slope(battle)
	await _drops(battle)
	await _roof(battle)
	await _ceiling(battle)
	await _vehicle(battle)
	battle.queue_free()
	await _frames(4)
	_watched.clear()
	battle = await _start_battle(map, 6)
	_probe = battle.player as Infantry
	_scenario = "bots"
	battle.pilot.set_physics_process(false)
	await _seconds(45.0)
	battle.queue_free()
	await _frames(4)
	_watched.clear()


func _start_battle(map: String, bots: int) -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": map, "start": BattleInfantry.START_ON_FOOT,
		"ai": [], InfantryBots.CONFIG_KEY: bots, "frag_limit": 500}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _reset(battle: Battle, p: Vector3) -> void:
	if not _probe.alive:
		_probe.respawn(Transform3D(Basis(), p))
	_probe.end_spawn_protection()
	var c: Dictionary = _probe.components[0]
	c.hp = float(c.max)
	_probe.integrity = 1.0
	_hp[_probe] = _total_hp(_probe)
	_probe.global_position = p
	_probe.velocity = Vector3.ZERO
	_probe.throttle = 0.0
	_probe.jet_input = false
	_probe.jump_input = false
	await _frames(2)


func _ground(battle: Battle, p: Vector3) -> Vector3:
	return Vector3(p.x, MapBuilder.ground_height(battle, p) + 0.3, p.z)


func _idle(battle: Battle) -> void:
	_scenario = "idle"
	await _reset(battle, _probe.global_position)
	await _seconds(3.0)


## Into the steepest nearby slope at 30 m/s (above T1's 25 m/s threshold), then skiing down it.
func _slope(battle: Battle) -> void:
	_scenario = "slope"
	var base := _probe.global_position
	var best := Vector3.FORWARD
	var rise := -INF
	for k in 16:
		var d := Basis(Vector3.UP, TAU * k / 16.0) * Vector3.FORWARD
		var r := MapBuilder.ground_height(battle, base + d * 10.0) - MapBuilder.ground_height(battle, base)
		if r > rise:
			rise = r
			best = d
	print("  slope: rise %.1f m over 10 m" % rise)
	await _reset(battle, _ground(battle, base))
	_probe.velocity = best * 30.0
	await _seconds(1.5)
	await _reset(battle, _ground(battle, base + best * 10.0))
	_probe.rotation.y = atan2(best.x, best.z)
	_probe.jump_input = true
	_probe.velocity = -best * 30.0
	await _seconds(2.0)
	_probe.jump_input = false


func _drops(battle: Battle) -> void:
	var base := _probe.global_position
	var least := float(_probe.armor.fall_min_speed)
	for h in DROPS_M:
		_scenario = "drop %.0f m" % h
		_expected_damage = sqrt(2.0 * Infantry.TRIBES_GRAVITY * h) > least
		await _reset(battle, _ground(battle, base) + Vector3.UP * h)
		await _seconds(2.0)
	_expected_damage = false


## The highest building near the spawn: a drop from 6 m onto its roof.
func _roof(battle: Battle) -> void:
	_scenario = "roof"
	var box := _nearest_building(battle)
	if box.size == Vector3.ZERO:
		print("  no building")
		return
	var top := box.get_center()
	top.y = box.end.y + 6.0
	await _reset(battle, top)
	await _seconds(3.0)


## Jetting up from inside a building's box into its roof.
func _ceiling(battle: Battle) -> void:
	_scenario = "ceiling"
	var box := _nearest_building(battle)
	if box.size == Vector3.ZERO:
		return
	var inside := box.get_center()
	await _reset(battle, inside)
	_probe.capacitor = _probe.capacitor_max
	_probe.jet_input = true
	await _seconds(2.5)
	_probe.jet_input = false
	await _seconds(2.0)


func _nearest_building(battle: Battle) -> AABB:
	var best := AABB()
	var best_d := INF
	for b in battle.find_children("*", "StaticBody3D", true, false):
		if b.is_in_group("terrain"):
			continue
		var box := _box_of(b)
		var d := box.get_center().distance_to(_probe.global_position)
		if box.size.y > 4.0 and d < best_d:
			best_d = d
			best = box
	return best


static func _box_of(body: Node) -> AABB:
	var box := AABB()
	var first := true
	for mi in body.find_children("*", "MeshInstance3D", true, false):
		var b: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _vehicle(battle: Battle) -> void:
	_scenario = "vehicle"
	var me := battle.multiplayer.get_unique_id()
	var herc := battle.occupancy.vehicle_of(me)
	if herc == null:
		for h in battle.vehicles.values():
			if not (h is Infantry) and h.team == _probe.team and VehicleOccupancy.of(h).is_empty():
				herc = h
	if herc == null:
		print("  no vehicle")
		return
	await _reset(battle, _ground(battle, herc.global_position + herc.global_basis.x * 6.0))
	await _seconds(2.0)
	battle.occupancy.apply_board(me, herc, VehicleOccupancy.PILOT_SEAT)
	await _frames(3)
	herc.throttle = 1.0
	await _seconds(4.0)
	print("  vehicle speed %.1f m/s" % herc.velocity.length())
	battle.occupancy.apply_exit(me, herc)
	await _seconds(0.5)
	herc.throttle = 0.0
	await _seconds(4.0)

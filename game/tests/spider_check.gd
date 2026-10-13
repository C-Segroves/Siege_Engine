extends Node3D
## Spiders and chasing mines against their games' own data and code (docs/formats/gameplay.md section 2, DAT 0x4a;
## tools/self_destruct_rules.py; bd_weapons.md mine rules; Starsiege datProjectile.cs newMine):
##   Earthsiege 1 Spider / Earthsiege 2 Arachnitron: catalog stats = the unit data; contact radius; walk / lunge cycle;
##     detonation exactly at contact; blast damage at the centre and the edge; shields (ES1 bypassed, ES2 absorb
##     first); about half the components hit; Earthsiege 2 skips itself; killed by gunfire: no blast;
##   Starsiege ARAC spider mine: contact trigger, crawls at its target, goes off on contact;
##   Battledrome mines: GATOR stays put, BLOODHND / PITBULL chase within their detect radius, trigger distance,
##     arm delay, go off when shot.
##   godot --headless --audio-driver Dummy --path game res://tests/spider_check.tscn

const SPIDERS := {"es1": "es1:SPIDER", "es2": "es2:SPIDER"}
const VICTIM := {"es1": "es1:RAPTOR", "es2": "es2:OUTLAW"}
const TOLERANCE := 0.01
const SPLASH_TRIALS := 400
const SPLASH_SHARE_TOLERANCE := 0.06
const MINE_FRAMES := 240
const FRAME := 1.0 / 60.0

var _failures := 0


func _ready() -> void:
	_build_floor()
	for game in SPIDERS:
		await _check_spider(game)
	await _check_starsiege_arac()
	await _check_bd_mines()
	print("spider_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
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


func _spawn(id: String, at: Vector3, team: int) -> Herc:
	var h := Herc.new()
	h.vehicle_id = id
	h.team = team
	h.position = at
	add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	for w in h.weapons:
		w.set_physics_process(false)
	return h


static func _data(game: String) -> Dictionary:
	var j = Assets.load_json("gameplay/hercs.json", game)
	return j.get("SPIDER", {}) if j is Dictionary else {}


# ------------------------------------------------------------------ Earthsiege 1 / 2 Spider

func _check_spider(game: String) -> void:
	var id: String = SPIDERS[game]
	var v := Packs.vehicle(id)
	var raw := _data(game)
	_expect(not v.is_empty() and not raw.is_empty(), "%s: in the catalog and the unit data" % id)
	if v.is_empty() or raw.is_empty():
		return
	_check_stats(id, v, raw, game)
	var spider := _spawn(id, Vector3.ZERO, 1)
	var charge: SelfDestructCharge = spider.get_node_or_null("SelfDestructCharge")
	_expect(charge != null, "%s: carries its self-destruct charge" % id)
	if charge == null:
		spider.free()
		return
	_check_cycle(id, charge, spider)
	_check_contact(id, game, charge, spider)
	_check_falloff(id, charge)
	await _check_blast(id, game)
	_check_splash_share(id, game)
	_check_gunfire(id, game)
	spider.free()


func _check_stats(id: String, v: Dictionary, raw: Dictionary, game: String) -> void:
	var mpu := Packs.metres_per_unit(game)
	_expect(is_equal_approx(float(v.shield_max), float(raw.shield_max)), "%s: shields %s = data %s" % [id, v.shield_max, raw.shield_max])
	_expect(is_equal_approx(float(v.mass), float(raw.mass)), "%s: mass = data (%s)" % [id, raw.mass])
	_expect(absf(float(v.collision_radius) - float(raw.unknown_6e) * mpu) < TOLERANCE, "%s: contact radius = DAT 0x6e" % id)
	_expect(int(v.torso_node) == -1, "%s: no torso twist (DAT torso node -1)" % id)
	var hp: Array = raw.damage.components.map(func(c): return float(c.hp))
	var comps: Array = HercDamage.make_components(v).map(func(c): return float(c.hp))
	_expect(hp == comps, "%s: component hit points = DMG" % id)
	var r: Dictionary = raw.self_destruct_rules
	var sd: Dictionary = v.self_destruct
	_expect(absf(float(sd.blast_radius_m) - float(r.blast_radius) * mpu) < TOLERANCE and float(sd.blast_damage) == float(r.blast_damage),
		"%s: blast %s m / %s = the simulator's %s units / %s" % [id, sd.blast_radius_m, sd.blast_damage, r.blast_radius, r.blast_damage])
	_expect(bool(sd.shields_absorb) == (game == "es2") and bool(sd.skips_self) == (game == "es2"),
		"%s: shields / self rules of its game" % id)
	_expect(float(sd.self_damage) >= HercDamage.make_components(v).reduce(func(m, c): return maxf(m, float(c.hp)), 0.0),
		"%s: the self damage destroys every own component" % id)


func _check_cycle(id: String, charge: SelfDestructCharge, spider: Herc) -> void:
	charge.apply_state_step(FRAME)
	_expect(charge.lunging and spider.move_steps == int(charge.rules.lunge_steps), "%s: starts with a lunge at %d steps a tick" % [id, spider.move_steps])
	var t := 0.0
	while charge.lunging and t < 10.0:
		charge.apply_state_step(FRAME)
		t += FRAME
	var span: Array = charge.rules.lunge_s
	_expect(t >= float(span[0]) - FRAME * 2.0 and t <= float(span[1]) + FRAME * 2.0 and spider.move_steps == 1,
		"%s: lunge lasts %.2f s (%s), then walks" % [id, t, span])


func _check_contact(id: String, game: String, charge: SelfDestructCharge, spider: Herc) -> void:
	var victim := _spawn(VICTIM[game], Vector3.ZERO, 0)
	var touch := spider.make_contact_radius() + victim.make_contact_radius()
	victim.position = Vector3(0, 0, -(touch + 0.1))
	_expect(charge.make_contact() == null, "%s: no detonation just beyond contact (%.2f m)" % [id, touch])
	victim.position = Vector3(0, 0, -(touch - 0.1))
	_expect(charge.make_contact() == victim, "%s: detonates at contact" % id)
	victim.free()


func _check_falloff(id: String, charge: SelfDestructCharge) -> void:
	var dmg := float(charge.rules.blast_damage)
	var r := charge.make_blast_radius()
	_expect(is_equal_approx(charge.make_component_damage(dmg, 0.0), dmg), "%s: full damage at the centre" % id)
	_expect(is_equal_approx(charge.make_component_damage(dmg, r * 0.5), dmg * 0.5), "%s: half damage at half the radius" % id)
	_expect(charge.make_component_damage(dmg, r) == 0.0, "%s: nothing at the edge" % id)


## A detonation next to a shielded victim: Earthsiege 1 leaves its shields alone, Earthsiege 2 drains the facing bank.
func _check_blast(id: String, game: String) -> void:
	var spider := _spawn(id, Vector3.ZERO, 1)
	var charge: SelfDestructCharge = spider.get_node("SelfDestructCharge")
	var victim := _spawn(VICTIM[game], Vector3(0, 0, -4.0), 0)
	victim.rotation.y = PI   # facing the Spider: the blast comes from the front
	var far := _spawn(VICTIM[game], Vector3(0, 0, -(charge.make_blast_radius() + victim.make_contact_radius() + 5.0)), 0)
	var front := victim.shield_front
	var integrity := victim.integrity
	seed(7)
	charge.detonate()
	_expect(not spider.alive, "%s: destroys itself" % id)
	_expect(victim.integrity < integrity, "%s: the blast wounds the unit beside it" % id)
	_expect(is_equal_approx(far.integrity, 1.0), "%s: nothing beyond the blast radius" % id)
	if game == "es2":
		_expect(victim.shield_front < front, "%s: the facing shield bank absorbs first (%.0f -> %.0f)" % [id, front, victim.shield_front])
	else:
		_expect(is_equal_approx(victim.shield_front, front), "%s: shields are not asked" % id)
	for n in [spider, victim, far]:
		n.free()


## About half the living components of a unit in reach are hit (0x802 / 0x1000).
func _check_splash_share(id: String, game: String) -> void:
	var spider := _spawn(id, Vector3(0, 0, 0), 1)
	var charge: SelfDestructCharge = spider.get_node("SelfDestructCharge")
	var victim := _spawn(VICTIM[game], Vector3(0, 0, -2.0), 0)
	var hits := 0
	var tries := 0
	seed(11)
	for t in SPLASH_TRIALS:
		victim.shield_front = 0.0
		victim.shield_rear = 0.0
		for c in victim.components:
			c.hp = 100000.0
		var before: Array = victim.components.map(func(c): return float(c.hp))
		charge.apply_blast_to(victim, spider.global_position)
		for i in victim.components.size():
			if charge.make_component_damage(1.0, spider.global_position.distance_to(victim.make_component_position(i))) > 0.0:
				tries += 1
				if float(victim.components[i].hp) < float(before[i]):
					hits += 1
	var share := float(hits) / maxf(float(tries), 1.0)
	var want := float(charge.rules.component_hit_chance)
	_expect(absf(share - want) < SPLASH_SHARE_TOLERANCE, "%s: %.3f of the components in reach hit (want %.3f)" % [id, share, want])
	spider.free()
	victim.free()


## Shot dead, a Spider dies without a blast.
func _check_gunfire(id: String, game: String) -> void:
	var spider := _spawn(id, Vector3.ZERO, 1)
	var victim := _spawn(VICTIM[game], Vector3(0, 0, -4.0), 0)
	for i in spider.components.size():
		spider.apply_component_hit(i, 1.0e6, victim)
	_expect(not spider.alive, "%s: shot dead" % id)
	_expect(is_equal_approx(victim.integrity, 1.0), "%s: killed by gunfire it does not blast" % id)
	spider.free()
	victim.free()


# ------------------------------------------------------------------ mines

## A mine of weapon `wid` laid at `at` by `layer` (team 1), aimed at `target`.
func _lay(wid: String, layer: Herc, at: Vector3, target: Herc) -> Projectile:
	var d := Packs.weapon(wid)
	var p := Weapon.make_projectile(d, layer, at, Vector3.DOWN, target)
	add_child(p)
	p.global_position = at
	return p


## Runs physics until the mine is gone or `frames` pass; true when it went off.
func _run(p: Projectile, frames: int) -> bool:
	for i in frames:
		await get_tree().physics_frame
		if not is_instance_valid(p) or p.is_queued_for_deletion():
			return true
	return false


func _check_starsiege_arac() -> void:
	var d := Packs.weapon("starsiege:ARA4")
	if d.is_empty():
		print("  starsiege not installed: ARAC skipped")
		return
	var pr: Dictionary = d.projectile
	_expect(str(pr.get("trigger", "")) == "contact" and float(pr.proximity) == 0.0, "ARAC: contact trigger (newMine proximity 0)")
	_expect(is_equal_approx(float(pr.speed), 50.0) and is_equal_approx(float(pr.accel), 10.0) and is_equal_approx(float(pr.lifetime), 30.0),
		"ARAC: term speed 50, accel 10, duration 30 (newMine)")
	var layer := _spawn("es1:APOLLO", Vector3(0, 0, 0), 1)
	var target := _spawn("es1:RAPTOR", Vector3(0, 0, -60), 0)
	var mine := _lay("starsiege:ARA4", layer, Vector3(0, 1, 6), target)
	_expect(mine.mine.tracking, "ARAC: a tracking mine")
	var start := mine.global_position.distance_to(target.global_position)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_expect(not is_instance_valid(mine) or mine.global_position.distance_to(target.global_position) < start, "ARAC: crawls at its target")
	_expect(await _run(mine, MINE_FRAMES), "ARAC: goes off at contact")
	_expect(target.integrity < 1.0 or target.shield_front + target.shield_rear < target.shield_max, "ARAC: its blast hits the target")
	layer.free()
	target.free()


func _check_bd_mines() -> void:
	if Packs.weapon("bd:GATOR_10").is_empty():
		print("  battledrome not installed: mines skipped")
		return
	var layer := _spawn("es1:APOLLO", Vector3(200, 0, 200), 1)
	# GATOR: stays put, trigger distance 21.5 m
	var near := _spawn("es1:RAPTOR", Vector3(0, 0, -30), 0)
	var gator := _lay("bd:GATOR_10", layer, Vector3(0, 2, 0), null)
	var gator_at := gator.global_position
	_expect(not await _run(gator, 180), "GATOR: no trigger at 30 m (trigger 21.5 m)")
	_expect(Vector2(gator.global_position.x, gator.global_position.z).distance_to(Vector2(gator_at.x, gator_at.z)) < TOLERANCE,
		"GATOR: never moves")
	_expect(absf(gator.global_position.y - float(Packs.weapon("bd:GATOR_10").projectile.hover_height)) < 0.05, "GATOR: hovers at its height")
	near.position = Vector3(0, 0, -20)
	_expect(await _run(gator, 10), "GATOR: goes off inside 21.5 m")
	# BLOODHND: chases inside its detect radius (43 m), not beyond
	near.position = Vector3(0, 0, -60)
	var hound := _lay("bd:BLOODHND_5", layer, Vector3(0, 2, 0), null)
	_expect(not await _run(hound, 180), "BLOODHND: an enemy beyond 43 m is left alone")
	_expect(Vector2(hound.global_position.x, hound.global_position.z).length() < TOLERANCE, "BLOODHND: waits without a quarry")
	near.position = Vector3(0, 0, -35)
	_expect(await _run(hound, MINE_FRAMES), "BLOODHND: chases an enemy within 43 m and goes off")
	# PITBULL: shot, it goes off
	var pit := _lay("bd:PITBULL_5", layer, Vector3(-100, 2, -100), null)
	var body: MineBody = pit.get_node_or_null("MineBody")
	_expect(body != null and body.collision_layer & 1 == 0, "PITBULL: a shootable body vehicles walk through")
	if body:
		body.apply_hit(0.0, 1.0, layer, pit.global_position)
		_expect(await _run(pit, 3), "PITBULL: goes off when shot")
	for n in [layer, near]:
		n.free()

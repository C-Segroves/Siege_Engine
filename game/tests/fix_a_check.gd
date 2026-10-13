extends Node3D
## Playtest 2026-10-11 group A (docs/PLAYTEST_2026-10-11.md), headless; A1 has its own aim_convergence_check:
##   A2 targeting prefers what is in front of the sight (Targeting): nearest the crosshair, distance-weighted, in view;
##      target_next cycles within the front set; targetable structures count; nothing behind or hidden first;
##   A3 every ground vehicle's torso / turret follows the aim input within its limits; full-turn turrets wrap;
##   A4 AI pilots hold fire without line of sight (terrain / buildings) and fire with it;
##   A5 friend-or-foe words and colours; name plates over teammates only, faded with distance;
##   A6 every radar (plain HUD, Earthsiege MFD scanner, Starsiege scope) puts known placements where they are,
##      under chassis turn, torso twist and a flyer's bank;
##   A7 every vehicle view and the soldier's HUD shows a compass with the waypoint marker at its bearing;
##   A8 the Earthsiege Spider detonates on contact (decoded radii) and not before, damaging what is near.
##   godot --headless --audio-driver Dummy --path game res://tests/fix_a_check.tscn

const VIEWER_ID := "es1:RAPTOR"
const ENEMY_ID := "es1:APOLLO"
const SPIDER_ID := "es1:SPIDER"
const FRAME := 1.0 / 60.0
const TOLERANCE := 0.01
const AI_FRAMES := 150
const SPIDER_FRAMES := 600

## A targetable structure as group B builds them (group "targetables", Herc-like fields).
class FakeStructure extends StaticBody3D:
	var alive := true
	var team := 1
	var display_name := "Bunker"
	var integrity := 0.5

## The battle as Nameplates sees it.
class FakeBattle extends Node:
	var player: Herc

var _failures := 0
var _floor: StaticBody3D


func _ready() -> void:
	_floor = _build_box(Vector3(4000, 1, 4000), Vector3(0, -0.5, 0))
	await _check_targeting()
	_check_torso_control()
	await _check_ai_line_of_sight()
	_check_team_marking()
	await _check_radars()
	_check_compasses()
	await _check_spider()
	_check_hit_side_and_stubs()
	print("fix_a_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
		_failures += 1


func _spawn(id: String, at: Vector3, team := 0, yaw := 0.0) -> Herc:
	var h: Herc = Flyer.new() if Packs.vehicle(id).get("flyer", false) else Herc.new()
	h.vehicle_id = id
	h.team = team
	h.position = at
	h.rotation.y = yaw
	add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _build_box(size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	body.add_child(col)
	add_child(body)
	body.global_position = at
	return body


func _settle_physics() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame


# ------------------------------------------------------------------ A2 targeting

func _check_targeting() -> void:
	var viewer := _spawn(VIEWER_ID, Vector3.ZERO)
	var ahead := _spawn(ENEMY_ID, Vector3(0, 0, -200), 1)
	var right := _spawn(ENEMY_ID, Vector3(40, 0, -100), 1)
	var behind := _spawn(ENEMY_ID, Vector3(0, 0, 50), 1)
	var far_left := _spawn(ENEMY_ID, Vector3(-300, 0, -10), 1)
	var friend := _spawn(ENEMY_ID, Vector3(5, 0, -60), 0)
	var bunker := FakeStructure.new()
	bunker.add_to_group(Targeting.TARGETABLES)
	add_child(bunker)
	bunker.global_position = Vector3(-30, 0, -150)
	await _settle_physics()
	var best := Targeting.pick_best(viewer)
	_expect(best == ahead, "A2: target_nearest picks the enemy under the crosshair, not the nearest one behind (%s)" % _name(best))
	var cycle := {}
	var t: Node3D = null
	for i in 6:
		t = Targeting.pick_next(viewer, t)
		cycle[t] = true
	_expect(cycle.size() == 3 and cycle.has(ahead) and cycle.has(right) and cycle.has(bunker),
		"A2: target_next cycles through the three in front only (%s)" % [cycle.keys().map(_name)])
	_expect(not cycle.has(behind) and not cycle.has(far_left) and not cycle.has(friend), "A2: nothing behind, aside or friendly in the cycle")
	var wall := _build_box(Vector3(30, 30, 2), Vector3(0, 10, -170))
	await _settle_physics()
	_expect(Targeting.pick_best(viewer) != ahead, "A2: an enemy hidden behind a wall is not the first pick")
	_expect(not Targeting.make_front_set(viewer).has(ahead), "A2: a hidden enemy is not in the front set")
	wall.free()
	viewer.rotation.y = PI
	_expect(Targeting.pick_best(viewer) == behind, "A2: turning round brings the enemy now in front first")
	for n in [viewer, ahead, right, behind, far_left, friend, bunker]:
		n.free()


static func _name(n: Object) -> String:
	return str(n.name) if n != null else "none"


# ------------------------------------------------------------------ A3 torso / turret control

func _check_torso_control() -> void:
	var checked := 0
	for v in Packs.pilotable():
		if bool(v.get("flyer", false)):
			continue
		_check_vehicle_torso(str(v.id))
		checked += 1
	_expect(checked > 50, "A3: ground vehicles checked (%d)" % checked)
	_expect(is_equal_approx(Herc.make_torso_yaw_step(3.0, -3.0, PI, 0.1), 3.1), "A3: a full-turn turret turns the short way past 180")
	_expect(is_equal_approx(PlayerPilot.make_turned_yaw(PI + 0.2, PI), -PI + 0.2), "A3: a full-turn turret's aim wraps")
	_expect(is_equal_approx(PlayerPilot.make_turned_yaw(2.0, 1.0), 1.0), "A3: a limited torso's aim stops at its limit")


## Mouse right (look.x > 0) turns the torso right (negative yaw), up to the limit, and the sight turns with it.
func _check_vehicle_torso(id: String) -> void:
	var h := _spawn(id, Vector3.ZERO)
	var pilot := PlayerPilot.make_for(h)
	var heading_before := HeadingFrame.make_heading(h)
	pilot._apply_aim(Vector2(0.4, -0.1))
	h.torso_target = pilot.aim_yaw
	h.pitch_target = pilot.aim_pitch
	for i in 240:
		h.apply_torso_step(FRAME)
	var want := maxf(-0.4, -h.torso_limit)
	_expect(absf(h.torso_yaw - want) < TOLERANCE, "A3 %s: torso follows the aim (%.3f, want %.3f)" % [id, h.torso_yaw, want])
	_expect(h.pitch > 0.0 or h.pitch_max <= 0.0, "A3 %s: mouse up pitches up" % id)
	var turned := wrapf(HeadingFrame.make_heading(h) - heading_before, -PI, PI)
	_expect(absf(turned - h.torso_yaw) < TOLERANCE, "A3 %s: the sight turns with the torso" % id)
	pilot.free()
	h.free()


# ------------------------------------------------------------------ A4 AI line of sight

func _check_ai_line_of_sight() -> void:
	_expect(await _ai_fires(true) == false, "A4: an AI pilot never fires through a wall")
	_expect(await _ai_fires(false) == true, "A4: an AI pilot fires with a clear line of sight")
	var a := _spawn(VIEWER_ID, Vector3.ZERO)
	var b := _spawn(ENEMY_ID, Vector3(0, 0, -80), 1)
	await _settle_physics()
	_expect(LineOfSight.is_clear(a, a.aim_origin(), b, Targeting.make_centre(b)), "A4: clear line reaches the target")
	var wall := _build_box(Vector3(30, 30, 2), Vector3(0, 10, -40))
	await _settle_physics()
	_expect(not LineOfSight.is_clear(a, a.aim_origin(), b, Targeting.make_centre(b)), "A4: a wall blocks the line")
	for n in [a, b, wall]:
		n.free()


## True when an AI pilot pulled a trigger within AI_FRAMES against a target 120 m ahead (`walled`: a wall between).
func _ai_fires(walled: bool) -> bool:
	var shooter := _spawn(VIEWER_ID, Vector3.ZERO)
	var target := _spawn(ENEMY_ID, Vector3(0, 0, -120), 1)
	shooter.set_physics_process(true)
	var wall: StaticBody3D = _build_box(Vector3(60, 40, 2), Vector3(0, 20, -60)) if walled else null
	await _settle_physics()
	var ai := AIPilot.new()
	ai.herc = shooter
	ai.order = AIPilot.Order.GUARD
	ai.skill = 1.0
	add_child(ai)
	ai.wake(target)
	var fired := false
	for i in AI_FRAMES:
		await get_tree().physics_frame
		for w in shooter.weapons:
			fired = fired or w.trigger
	for n in [ai, shooter, target, wall]:
		if n != null:
			n.free()
	return fired


# ------------------------------------------------------------------ A5 team marking

func _check_team_marking() -> void:
	var me := _spawn(VIEWER_ID, Vector3.ZERO, 0)
	var mate := _spawn(ENEMY_ID, Vector3(0, 0, -50), 0)
	var far_mate := _spawn(ENEMY_ID, Vector3(0, 0, -900), 0)
	var foe := _spawn(ENEMY_ID, Vector3(20, 0, -50), 1)
	var other := _spawn(ENEMY_ID, Vector3(-20, 0, -50), 2)
	mate.display_name = "Lan Player 2"
	_expect(TargetInfo.make_iff_text(me, mate) == TargetInfo.IFF_FRIEND, "A5: a teammate reads FRIEND")
	_expect(TargetInfo.make_iff_text(me, foe) == TargetInfo.IFF_ENEMY, "A5: an enemy reads ENEMY")
	TeamRelations.apply_neutral(0, 2)
	_expect(TargetInfo.make_iff_text(me, other) == TargetInfo.IFF_NEUTRAL, "A5: a neutral team reads NEUTRAL")
	TeamRelations.clear()
	_expect(TargetInfo.make_iff_color(me, mate) != TargetInfo.make_iff_color(me, foe), "A5: friends and foes differ in colour")
	var battle := FakeBattle.new()
	battle.player = me
	add_child(battle)
	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = me.aim_origin()
	cam.current = true
	var plates := Nameplates.new(battle)
	add_child(plates)
	plates.apply_plates()
	var plate := plates.plate_of(mate)
	_expect(not plate.is_empty() and plate.text == "Lan Player 2", "A5: a teammate carries its (LAN) name")
	var top: float = mate.make_body_size().y
	var anchor := plates.make_anchor(mate)
	_expect(anchor.y > mate.global_position.y + top and anchor.y < mate.global_position.y + top + 1.0,
		"A5: the plate sits just above the model's top (%.2f over a %.2f m model)" % [anchor.y - mate.global_position.y, top])
	_expect(not plate.is_empty() and (plate.rect as Rect2).end.y <= cam.unproject_position(anchor).y,
		"A5: the text sits above its anchor point")
	_expect(not plate.is_empty() and is_equal_approx(plate.alpha, 1.0), "A5: near plates are opaque")
	_expect(not plate.is_empty() and int(plate.font_size) <= Nameplates.MAX_FONT_SIZE, "A5: a near plate's font is clamped")
	_expect(Nameplates.make_font_size(2.0) == Nameplates.MAX_FONT_SIZE and Nameplates.make_font_size(600.0) == Nameplates.MIN_FONT_SIZE,
		"A5: plate font between its limits, smaller far away")
	_expect(plates.plate_of(foe).is_empty() and plates.plate_of(other).is_empty() and plates.plate_of(me).is_empty(),
		"A5: no plates over enemies or yourself")
	_expect(plates.plate_of(far_mate).is_empty(), "A5: a teammate beyond the fade range shows no plate")
	_expect(plates.layer < BattleOverlay.new().layer, "A5: plates draw below the battle overlay's HUD")
	if not plate.is_empty():
		var covering: Rect2 = (plate.rect as Rect2).grow(2.0)
		plates.occupied_provider = func(): return [covering]
		plates.apply_plates()
		_expect(plates.plate_of(mate).is_empty(), "A5: a plate under a HUD window is not drawn")
		plates.occupied_provider = Callable()
	mate.alive = false
	plates.apply_plates()
	_expect(plates.plate_of(mate).is_empty(), "A5: a dead teammate loses the plate")
	cam.free()
	for n in [plates, battle, me, mate, far_mate, foe, other]:
		n.free()


# ------------------------------------------------------------------ A6 radars

## Placements relative to the view: [right m, ahead m]; each must appear at (right, -ahead) on a heading-up scope.
const PLACEMENTS := [Vector2(0, 100), Vector2(80, 0), Vector2(-60, -40), Vector2(30, 70)]
const POSES := [Vector3(0.0, 0.0, 0.0), Vector3(1.1, 0.5, 0.0), Vector3(-2.5, -0.9, 0.0), Vector3(0.7, 0.0, 0.6)]


func _check_radars() -> void:
	for id in [VIEWER_ID, "starsiege:cy_prom", "es2:RAZOR"]:
		if Packs.vehicle(id).is_empty():
			continue
		for pose in POSES:
			await _check_radar_pose(id, pose)
	var soldier := _spawn_soldier()
	if soldier:
		soldier.rotation.y = 0.8
		var want := Vector3(-sin(0.8), 0, -cos(0.8)) * 50.0
		var hud := HUD.new()
		hud.herc = soldier
		add_child(hud)
		var p := hud.make_radar_point(soldier.global_position + want, HUD.RADAR_RANGE)
		_expect(p.distance_to(Vector2(0, -50)) < 0.1, "A6: the soldier's radar shows what is ahead at the top (%s)" % p)
		hud.free()
		soldier.free()


## pose: x = chassis yaw, y = torso twist (a flyer: none), z = flyer bank.
func _check_radar_pose(id: String, pose: Vector3) -> void:
	var h := _spawn(id, Vector3(30, 0, -20), 0, pose.x)
	if h is Flyer:
		h.torso_yaw = pose.z
		h._animate(0.0)
	else:
		h.torso_yaw = clampf(pose.y, -h.torso_limit, h.torso_limit)
		h.torso.apply(h.torso_yaw, 0.0, h.animator.animates)
	var view_yaw := pose.x + (0.0 if h is Flyer else h.torso_yaw)
	var right := Vector3(cos(view_yaw), 0, -sin(view_yaw))
	var ahead := Vector3(-sin(view_yaw), 0, -cos(view_yaw))
	var hud := HUD.new()
	hud.herc = h
	add_child(hud)
	var cockpit := CockpitDisplay.create(h, self)
	if cockpit:
		add_child(cockpit)
		cockpit.set_process(false)
	for pl in PLACEMENTS:
		var at: Vector3 = h.global_position + right * pl.x + ahead * pl.y
		var want := Vector2(pl.x, -pl.y)
		var where := "%s pose %s placement %s" % [id, pose, pl]
		var p := hud.make_radar_point(at, HUD.RADAR_RANGE)
		_expect(p.distance_to(want) < 0.1, "A6 %s: plain HUD radar %s, want %s" % [where, p, want])
		if cockpit:
			_check_cockpit_radar(cockpit, at, want, where)
	if cockpit:
		cockpit.free()
	hud.free()
	h.free()


func _check_cockpit_radar(cockpit: CockpitDisplay, at: Vector3, want: Vector2, where: String) -> void:
	for p in cockpit._painters:
		if p is CockpitMfd:
			var scan: Vector2 = p.make_radar_point(at, true) / p._radar_radius() \
				* (CockpitMfd.RADAR_RANGES[cockpit.radar_range_i] * Assets.UNIT)
			_expect(scan.distance_to(want) < 0.1, "A6 %s: MFD scanner %s" % [where, scan])
		if p is CockpitMeters:
			var share: Vector2 = (p as CockpitMeters)._radar.make_scope_share(at, 1.0)
			_expect(share.distance_to(want) < 0.1, "A6 %s: HUD scope %s" % [where, share])


func _spawn_soldier() -> Infantry:
	var pack := InfantryCatalog.make_default_pack()
	if pack == "":
		return null
	var s := Infantry.new()
	s.armor_id = InfantryCatalog.light_armor_id(pack)
	add_child(s)
	s.set_physics_process(false)
	return s


# ------------------------------------------------------------------ A7 compasses

func _check_compasses() -> void:
	var nav := Node3D.new()
	nav.set_meta("label", "3")
	nav.add_to_group("nav_points")
	add_child(nav)
	nav.global_position = Vector3(100, 0, 0)   # due east of the origin
	var h := _spawn(VIEWER_ID, Vector3.ZERO)
	var wp := HeadingFrame.make_current_waypoint(h, null)
	_expect(not wp.is_empty() and str(wp.label) == "3", "A7: the nav marker is the waypoint")
	_expect(is_equal_approx(HeadingFrame.make_heading_deg(h), 0.0), "A7: facing -Z reads north")
	_expect(is_equal_approx(HeadingFrame.make_relative_bearing_deg(h, nav.global_position), 90.0), "A7: an eastern waypoint is 90 deg right")
	h.torso_yaw = -PI * 0.5
	_expect(absf(HeadingFrame.make_relative_bearing_deg(h, nav.global_position)) < 0.01, "A7: twisting the torso right to it centres it")
	var band := Rect2(0, 0, 240, 20)
	_expect(is_equal_approx(HudCompass.make_marker_x(band, 0.0), 120.0), "A7: centred waypoint marks the tape's middle")
	_expect(is_equal_approx(HudCompass.make_marker_x(band, 170.0), 240.0), "A7: a waypoint behind pins to the tape's end")
	h.free()
	nav.free()
	for v in Packs.pilotable():
		var host := _spawn(str(v.id), Vector3.ZERO)
		var cockpit := CockpitDisplay.create(host, self)
		_expect(cockpit == null or cockpit.has_compass(), "A7 %s: its cockpit shows a compass" % v.id)
		if cockpit:
			cockpit.free()
		host.free()


# ------------------------------------------------------------------ A8 Spider

func _check_spider() -> void:
	var spider := _spawn(SPIDER_ID, Vector3.ZERO, 1)
	var charge: SelfDestructCharge = spider.get_node_or_null("SelfDestructCharge")
	_expect(charge != null, "A8: the Spider carries its self-destruct charge")
	if charge == null:
		spider.free()
		return
	_expect(absf(spider.make_contact_radius() - 750.0 / 256.0) < TOLERANCE, "A8: contact radius 750 units (DAT 0x6e)")
	_expect(absf(charge.make_blast_radius() - 3000.0 / 256.0) < TOLERANCE, "A8: blast radius 3000 units")
	var victim := _spawn(VIEWER_ID, Vector3(0, 0, -7.0), 0)
	_expect(charge.make_contact() == null, "A8: no detonation 7 m away (contact at %.2f m)" % (spider.make_contact_radius() + victim.make_contact_radius()))
	victim.position = Vector3(0, 0, -5.0)
	_expect(charge.make_contact() == victim, "A8: contact 5 m away")
	var integrity := victim.integrity
	charge.detonate()
	_expect(not spider.alive, "A8: the Spider destroys itself")
	_expect(victim.integrity < integrity, "A8: the blast damages the vehicle it touched")
	spider.free()
	victim.free()
	await _check_spider_run()


## An AI Spider runs at its target and blows up on contact.
func _check_spider_run() -> void:
	var spider := _spawn(SPIDER_ID, Vector3.ZERO, 1)
	var victim := _spawn(VIEWER_ID, Vector3(0, 0, -40), 0)
	spider.set_physics_process(true)
	for w in spider.weapons:
		w.set_physics_process(true)
	var ai := AIPilot.new()
	ai.herc = spider
	ai.order = AIPilot.Order.SEARCH
	add_child(ai)
	ai.wake(victim)
	var frames := 0
	while spider.alive and frames < SPIDER_FRAMES:
		await get_tree().physics_frame
		frames += 1
	_expect(not spider.alive, "A8: the AI Spider reached its target and detonated (%d frames)" % frames)
	_expect(victim.integrity < 1.0, "A8: its target took the blast")
	for n in [ai, spider, victim]:
		n.free()


# ------------------------------------------------------------------ shots after the A1 sight change (ttk_check)

## A level shot from the eye lands on the top of the hull, behind the target's centre: it still takes the front
## shield bank (the side it comes from, DBSIM 0xfca8), and it never wastes itself on a component without collision
## spheres (3Space placeholder / weapon rows, DBSIM 0x9064).
func _check_hit_side_and_stubs() -> void:
	var target := _spawn(ENEMY_ID, Vector3.ZERO, 1)
	var shooter := _spawn(VIEWER_ID, Vector3(0, 0, -150), 0)
	var on_top_behind := target.global_transform * Vector3(0, 6.5, 0.3)
	_expect(target.is_front_hit(on_top_behind, shooter), "ttk: a shot from the front landing behind the centre hits the front bank")
	_expect(not target.is_front_hit(target.global_transform * Vector3(0, 4, 1.5)), "ttk: without an attacker the hit side decides")
	var comps := HercDamage.make_components(target.def)
	var stubs := comps.filter(func(c): return not bool(c.get("hittable", true)))
	var one_hp := comps.filter(func(c): return float(c.max) <= 1.0)
	_expect(not stubs.is_empty() and one_hp.all(func(c): return stubs.has(c)) and bool(comps[0].get("hittable", false)),
		"ttk: the 1 hp stub rows have no COL spheres, the cockpit has (%d stubs)" % stubs.size())
	seed(3)
	var picked_stub := false
	for i in 500:
		var k := HercDamage.pick_component(comps, Vector3(0, 6.5 if i % 2 == 0 else 2.0, 0))
		picked_stub = picked_stub or not bool(comps[k].get("hittable", true))
	_expect(not picked_stub, "ttk: a hit never lands on a component without collision spheres")
	target.free()
	shooter.free()

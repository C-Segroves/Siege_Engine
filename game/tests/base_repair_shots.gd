extends Node
## Windowed renders of base repair for checking by eye (needs a window and the Tribes pack):
##   BASE_REPAIR_SHOT_DIR=<folder> godot --audio-driver Dummy --path game res://tests/base_repair_shots.tscn
## repair_generator.png (a downed generator being repaired through the repair beam), captured_turret.png (a turret the
## player took by repairing it, firing at its old faction), repair_teammate.png, repair_herc_structure.png.
const MAP_ID := "tribes:Raindance"
const SETTLE_FRAMES := 30
const PLAYER_TEAM := 7
const OWNER_TEAM := 0
const SPOT_SHARES := [0.3, 0.5, 0.7]
const SPOT_BEARINGS := 12
const TARGET_VEHICLE := "es1:SCORPION"


func _ready() -> void:
	get_tree().create_timer(240.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	var dir := OS.get_environment("BASE_REPAIR_SHOT_DIR")
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP_ID, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": []}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	_battle = battle
	battle.overlay.visible = false
	await _frames(SETTLE_FRAMES)
	battle.cameras.apply_view(true)
	var base := TribesBase.of(battle)
	var s := battle.player as Infantry
	s.spawn_protection = 100000.0
	s.apply_spawn_protection()
	var pack_id := ""
	for id in InfantryGear.packs_of(s.armor):
		if str(InfantryGear.pack(id).get("effect", "")) == "repair":
			pack_id = str(id)
	s.kit.pack_id = pack_id
	var cam := Camera3D.new()
	cam.far = 3000.0
	battle.add_child(cam)
	# 1: a downed generator, repaired by the owner's soldier
	var turret := _find_turret(base)
	var gen: TribesBaseObject = base.objects_of(TribesBaseObject.KIND_GENERATOR)[0]
	for i in 6:
		gen.apply_hit(0.0, gen.max_hp, null)
	gen.apply_repair(gen.max_hp * 0.25)
	s.team = gen.team
	var side := gen.global_basis.x.normalized()
	s.global_position = gen.global_position + side * 4.0 + Vector3.UP * 1.0
	s.velocity = Vector3.ZERO
	s.kit.pack_active = true
	s.capacitor = s.capacitor_max
	await _seconds(0.8)
	_aim_camera(cam, gen.global_position + Vector3.UP * 2.0, gen.global_position + side * 9.0 + gen.global_basis.z * 7.0 + Vector3.UP * 4.0)
	await _shot(dir.path_join("repair_generator.png"))
	s.kit.pack_active = false
	gen.apply_repair(gen.max_hp)
	# 2: a captured turret firing at its old faction
	for i in 6:
		turret.apply_hit(0.0, turret.max_hp, null)
	var enemy := _make_enemy(battle, turret)
	s.team = PLAYER_TEAM
	s.global_position = turret.global_position + Vector3.UP * 0.5
	s.kit.pack_active = true
	var t := 0.0
	while t < 30.0 and not (turret.is_captured() and turret.is_enabled()):
		await _seconds(0.25)
		t += 0.25
	s.kit.pack_active = false
	s.global_position += Vector3(5.0, 0, 0)
	turret.energy = turret.energy_max
	var shots := turret.shots_fired
	t = 0.0
	while t < 10.0 and turret.shots_fired <= shots:
		await _seconds(0.25)
		t += 0.25
	var between := (turret.global_position + enemy.global_position) * 0.5
	var across := (enemy.global_position - turret.global_position).normalized().cross(Vector3.UP)
	_aim_camera(cam, between + Vector3.UP * 3.0, between + across * 22.0 + Vector3.UP * 8.0)
	await _shot(dir.path_join("captured_turret.png"))
	print("captured=%s team=%d shots=%d" % [turret.is_captured(), turret.team, turret.shots_fired - shots])
	await _shoot_units(battle, s, cam, dir)
	get_tree().quit()


## repair_teammate.png (the pack's beam on a hurt teammate), repair_herc_structure.png (a Herc holding the repair action
## next to a hurt Earthsiege structure).
func _shoot_units(battle: Battle, s: Infantry, cam: Camera3D, dir: String) -> void:
	s.team = OWNER_TEAM
	s.global_position = s.global_position + Vector3(0, 0, 60)
	s.velocity = Vector3.ZERO
	var spec := battle.infantry.bots.make_bot_spec(battle.infantry.pack, 0)
	spec.team = OWNER_TEAM
	spec.xf = Transform3D(Basis(), s.global_position + Vector3(2.5, 0, 0))
	var brain := battle.infantry.bots.spawn_bot(spec, 0.5)
	brain.set_physics_process(false)
	brain.soldier.components[0].hp = float(brain.soldier.components[0].max) * 0.4
	brain.soldier.integrity = HercDamage.integrity_of(brain.soldier.components)
	s.kit.pack_active = true
	s.capacitor = s.capacitor_max
	await _seconds(0.6)
	var mid := (s.global_position + brain.soldier.global_position) * 0.5
	_aim_camera(cam, mid + Vector3.UP * 1.3, mid + Vector3(0, 2.5, 7.0))
	await _shot(dir.path_join("repair_teammate.png"))
	s.kit.pack_active = false
	var herc := battle.spawn_ai(TARGET_VEHICLE, OWNER_TEAM, Transform3D(Basis(), s.global_position + Vector3(0, 0, 60)), [], "Mender", {"skill": 0.0})
	for c in herc.get_children():
		if c is AIPilot:
			(c as AIPilot).set_physics_process(false)
	herc.owner_peer = 99
	await _seconds(1.0)
	var st := Structure.create(battle, "es1:BASES_0", Transform3D(Basis(), herc.global_position + Vector3(14, 0, 0)), battle.palette_id, OWNER_TEAM, 15000.0)
	st.hp = st.max_hp * 0.3
	st.integrity = 0.3
	battle.infantry.repair._apply_hold(99, true)
	await _seconds(1.5)
	var at := (herc.global_position + st.global_position) * 0.5
	_aim_camera(cam, at + Vector3.UP * 3.0, at + Vector3(0, 6.0, 26.0))
	await _shot(dir.path_join("repair_herc_structure.png"))
	print("herc structure hp %.0f / %.0f" % [st.hp, st.max_hp])


var _battle: Battle
var _xf := Transform3D.IDENTITY
var _cam: Camera3D


## The battle's chase camera is the one shown: hold it at the wanted place every frame.
func _aim_camera(cam: Camera3D, look_at_point: Vector3, from: Vector3) -> void:
	_cam = cam
	cam.global_position = from
	cam.look_at(look_at_point, Vector3.UP)
	_xf = cam.global_transform


func _enter_tree() -> void:
	RenderingServer.frame_pre_draw.connect(_apply_camera)


## Just before every frame is drawn, after the battle's own cameras have had their say.
func _apply_camera() -> void:
	if _battle != null and _xf != Transform3D.IDENTITY:
		_cam.far = 3000.0
		_cam.global_transform = _xf
		_cam.current = true


func _find_turret(base: TribesBase) -> TribesTurret:
	var best: TribesTurret = null
	for o in base.objects_of(TribesBaseObject.KIND_TURRET):
		var t := o as TribesTurret
		if t and t.team == OWNER_TEAM and t.is_armed() and t.is_working() and (best == null or t.engage_range > best.engage_range):
			best = t
	return best


func _make_enemy(battle: Battle, turret: TribesTurret) -> Herc:
	var enemy := battle.spawn_ai(TARGET_VEHICLE, OWNER_TEAM, Transform3D(Basis(), turret.global_position + Vector3(0, 500, 0)), [], "Target", {"skill": 0.0})
	for c in enemy.get_children():
		if c is AIPilot:
			(c as AIPilot).set_physics_process(false)
	enemy.end_spawn_protection()
	for share in SPOT_SHARES:
		for k in SPOT_BEARINGS:
			var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * k / SPOT_BEARINGS)
			var p := turret.global_position + dir * turret.engage_range * float(share)
			p.y = MapBuilder.ground_height(battle, p) + 0.5
			enemy.global_position = p
			if turret.is_in_arc(p + Vector3.UP * TribesTurret.VEHICLE_AIM_HEIGHT - turret.make_muzzle()) and turret.has_line_of_sight(enemy):
				return enemy
	return enemy


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _seconds(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(path: String) -> void:
	for _f in 5:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)

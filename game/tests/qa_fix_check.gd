extends Node
## Regression checks for the QA pass fixes (docs/QA_REPORT.md):
##   #1  positional sound pool survives battles (two battles in a row)
##   #2  Tribes 2 vehicle pads: spawns lifted out of the pad, walkers start off the pads, flyers lift off
##   #4  null projectile numbers fall back (Beowulf mortar data has a lifetime)
##   #7  map spawns keep opposing teams apart; spawn protection
##   #11 Starsiege say3D ambient sounds print no "0" lines
##   P3  HUD weapon display names, chase camera spring arm, LAN RPC after the battle left the tree,
##       launcher automation runs once per process
##   godot --headless --audio-driver Dummy --path game res://tests/qa_fix_check.tscn -- --page=options

const CALDERA := "tribes2:Caldera"
## Caldera's vehicle pad deck (station shape top, measured from its collision mesh).
const CALDERA_PAD_DECK_Y := 151.3
const PAD_MAPS := ["tribes2:Caldera", "tribes2:Katabatic", "tribes2:IceBound"]
const BROADSIDE := "tribes:Broadside"
const DRIVE_SECONDS := 6.0
const MIN_FLY_DISTANCE := 50.0
const MIN_WALK_DISTANCE := 40.0
const WALL_DISTANCE := 12.0

var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	await _check_launcher_automation_once()
	_check_weapon_numbers()
	_check_display_names()
	_check_spawn_choice()
	await _check_sound_pool_across_battles()
	await _check_pad_spawns()
	await _check_pad_driving("tribes2:SHRIKE", MIN_FLY_DISTANCE)
	await _check_pad_driving("es2:OUTLAW", MIN_WALK_DISTANCE)
	await _check_broadside_spawns()
	await _check_chase_camera()
	await _check_net_sync_after_exit()
	await _check_starsiege_say()
	print("qa_fix_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


# ------------------------------------------------------------------ battles

func _start_battle(config: Dictionary) -> Battle:
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	for i in 10:
		await get_tree().physics_frame
	return battle


func _end_battle(battle: Battle) -> void:
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _map_config(vehicle: String, map_id: String) -> Dictionary:
	var config := BattleSetup.make_default_config(vehicle)
	config.mode = "vs"
	config.respawn = true
	config.map = map_id
	config.ai = BattleSetup.MAP_AI.duplicate(true)
	return config


# ------------------------------------------------------------------ Tooling: launcher automation

func _check_launcher_automation_once() -> void:
	print("launcher automation (--page=options):")
	if ScreenRouter.arg_value("page") != "options":
		_expect(false, "run with -- --page=options")
		return
	var pages := []
	for i in 2:
		var launcher: Launcher = load("res://launcher.tscn").instantiate()
		get_tree().root.add_child(launcher)
		await get_tree().process_frame
		pages.append(launcher.current_name)
		launcher.queue_free()
		await get_tree().process_frame
	_expect(pages[0] == "options" and pages[1] != "options", "only the first launcher opens --page (%s)" % [pages])


# ------------------------------------------------------------------ #4 weapon data

func _check_weapon_numbers() -> void:
	print("projectile numbers (#4):")
	var broken: Dictionary = Packs.weapon("tribes2:TANK_MORTAR").duplicate(true)
	broken.projectile.lifetime = null
	var p := Weapon.make_projectile(broken, null, Vector3.ZERO, Vector3.FORWARD, null)
	_expect(p != null and p.lifetime == Weapon.LIFETIME_FROM_RANGE, "a null lifetime falls back to the range-derived one")
	if p:
		p.free()
	var mortar := Packs.weapon("tribes2:TANK_MORTAR")
	var lifetime = mortar.get("projectile", {}).get("lifetime")
	_expect(lifetime is float and float(lifetime) > 0.0, "tribes2:TANK_MORTAR has a projectile lifetime (%s)" % [lifetime])


# ------------------------------------------------------------------ P3 HUD names

func _check_display_names() -> void:
	print("HUD weapon names (P3):")
	var mortar := Weapon.from_def(Packs.weapon("tribes2:TANK_MORTAR"))
	var laser := Weapon.from_def(Packs.weapon("es1:LAS100"))
	_expect(mortar.display_name == "Turret mortar", "tribes2:TANK_MORTAR shows '%s'" % mortar.display_name)
	_expect(laser.display_name == "LAS100", "es1:LAS100 keeps its original short name '%s'" % laser.display_name)
	mortar.free()
	laser.free()


# ------------------------------------------------------------------ #7 spawn choice

func _check_spawn_choice() -> void:
	print("spawn choice (#7):")
	var points: Array[Transform3D] = []
	for x in [0.0, 20.0, 40.0, 400.0]:
		points.append(Transform3D(Basis(), Vector3(x, 0, 0)))
	var first := BattleSpawner.make_spawn_choice(points, [], 0)
	var mate := BattleSpawner.make_spawn_choice(points, [{"pos": first.origin, "team": 0}], 0)
	var enemy := BattleSpawner.make_spawn_choice(points, [{"pos": first.origin, "team": 0}], 1)
	_expect(first.origin.x == 0.0, "the first vehicle takes the map's first spawn")
	_expect(mate.origin.x == 20.0, "a team mate takes the next free spawn")
	_expect(enemy.origin.x == 400.0, "an opponent skips spawns closer than %d m" % BattleSpawner.MIN_OPPONENT_SEPARATION)


# ------------------------------------------------------------------ #1 sound pool

func _check_sound_pool_across_battles() -> void:
	print("positional sound pool (#1):")
	for round in 2:
		var battle := await _start_battle(_map_config("es1:RAPTOR", BROADSIDE))
		for i in 4:
			Sfx.play_at("explosion", battle.player.global_position)
		await _end_battle(battle)
	var pool := Sfx.positional_pool()
	_expect(not pool.is_empty() and pool.all(func(p): return is_instance_valid(p) and p.get_parent() == Sfx),
		"after two battles all %d pooled players are alive and owned by Sfx" % pool.size())


# ------------------------------------------------------------------ #2 Tribes 2 pads

func _check_pad_spawns() -> void:
	print("vehicle pad spawns (#2):")
	for map_id in PAD_MAPS:
		var root := Node3D.new()
		add_child(root)
		var built := MapBuilder.build(root, map_id)
		var pads: Array = built.get("pad_spawns", [])
		var ground: Array = built.get("herc_spawns", [])
		var on_pad := ground.filter(func(t): return pads.any(func(p): return p.origin.distance_to(t.origin) < MapBuilder.SPAWN_MERGE_DISTANCE))
		_expect(not pads.is_empty() and not ground.is_empty() and on_pad.is_empty(),
			"%s: %d pad spawns, %d Herc spawns, none on a pad" % [map_id, pads.size(), ground.size()])
		if map_id == CALDERA and not pads.is_empty():
			_expect(pads[0].origin.y > CALDERA_PAD_DECK_Y, "Caldera's pad spawn is above the deck (y %.2f)" % pads[0].origin.y)
		root.queue_free()
		await get_tree().process_frame


## Full throttle (and lift) for DRIVE_SECONDS from the start on Caldera.
func _check_pad_driving(vehicle: String, min_distance: float) -> void:
	var battle := await _start_battle(_map_config(vehicle, CALDERA))
	var p := battle.player
	var start := p.global_position
	p.throttle = 1.0
	if p is Flyer:
		(p as Flyer).lift_input = 0.6
	await get_tree().create_timer(DRIVE_SECONDS).timeout
	var moved := p.global_position.distance_to(start)
	_expect(moved > min_distance, "%s on Caldera moves %.0f m in %.0f s" % [vehicle, moved, DRIVE_SECONDS])
	await _end_battle(battle)


# ------------------------------------------------------------------ #7 Broadside

func _check_broadside_spawns() -> void:
	print("Broadside spawns (#7):")
	var battle := await _start_battle(_map_config("es1:RAPTOR", BROADSIDE))
	var p := battle.player
	var nearest := INF
	for h in battle.vehicles.values():
		if h != p and h.team != p.team:
			nearest = minf(nearest, h.global_position.distance_to(p.global_position))
	_expect(nearest >= BattleSpawner.MIN_OPPONENT_SEPARATION, "nearest opponent starts %.0f m away" % nearest)
	_expect(p.is_spawn_protected(), "the player is spawn protected")
	var before := p.shield_front + p.shield_rear
	p.apply_hit(500.0, 500.0, null, p.global_position)
	_expect(p.shield_front + p.shield_rear == before, "a hit during spawn protection does nothing")
	p.weapons[0].fire()
	_expect(not p.is_spawn_protected(), "firing ends spawn protection")
	await _end_battle(battle)


# ------------------------------------------------------------------ P3 chase camera

func _check_chase_camera() -> void:
	print("chase camera (P3):")
	var battle := await _start_battle(_map_config("es1:RAPTOR", BROADSIDE))
	var p := battle.player
	var wall := _build_wall_behind(battle, p)
	for i in 3:
		await get_tree().physics_frame
	for i in 60:
		battle.cameras.apply_follow(p, 1.0 / 60.0)
	var pivot := p.global_position + Vector3.UP * BattleCameras.CHASE_LOOK_HEIGHT
	var cam := battle.cameras.chase_cam.global_position
	var q := PhysicsRayQueryParameters3D.create(pivot, cam, 0xFFFFFFFF, [p.get_rid()])
	var blocked := p.get_world_3d().direct_space_state.intersect_ray(q)
	_expect(blocked.is_empty() or blocked.collider != wall, "the camera stays in front of a wall behind the Herc (%.1f m from the pivot)" % pivot.distance_to(cam))
	await _end_battle(battle)


func _build_wall_behind(battle: Battle, p: Herc) -> StaticBody3D:
	var wall := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 60, 2)
	col.shape = box
	wall.add_child(col)
	battle.add_child(wall)
	wall.global_transform = Transform3D(p.aim_basis(), p.global_position + p.aim_basis().z * WALL_DISTANCE)
	return wall


# ------------------------------------------------------------------ P3 LAN match end

func _check_net_sync_after_exit() -> void:
	print("net sync after the battle left the tree (P3):")
	var battle := await _start_battle(_map_config("es1:RAPTOR", BROADSIDE))
	var sync: BattleNetSync = battle.get_node("NetSync")
	battle.get_parent().remove_child(battle)
	_expect(not sync.is_receiving(), "a detached battle drops incoming RPCs")
	sync._client_input({"throttle": 1.0})
	sync._snapshot(0, [])
	battle.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------------ #11 Starsiege say3D

func _check_starsiege_say() -> void:
	print("Starsiege messages (#11):")
	var battle := await _start_battle({"mode": "mission", "mission_name": "starsiege:HA0", "respawn": false,
		"roster": {1: {"name": "Tester", "vehicle": "starsiege:pi_eman", "team": 0, "loadout": []}}})
	var ms = battle.get("mission")
	if ms == null:
		_expect(false, "HA0 loads")
		return
	var hud := battle.overlay.hud
	hud.messages.clear()
	ms.ss_builtin("say3d", [0, 0, "", "sfx_windgust.wav", "IDPRF_2D", 0, 0, 0.0])
	ms.ss_builtin("say", [0, 1, "QA message", "qa.wav"])
	await get_tree().process_frame
	var texts := hud.messages.map(func(m): return str(m[0]))
	_expect(texts.has("QA message") and not texts.has("0") and not texts.has(""),
		"say shows its text, an ambient say3D shows nothing %s" % [texts])
	await _end_battle(battle)

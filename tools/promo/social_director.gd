extends Node
## Social video capture (promo tooling, tools/promo). Runs one segment under Movie Maker:
##   godot --audio-driver Dummy --path game --write-movie x.avi --fixed-fps 60 -s boot.gd -- --test-store
##         --driver=<this file> --seg=<menus|ctf|dm|missile|cmdmap|riders>
## Prints "social: mark <name> frame=<n>" at the points the edit cuts on.

const BATTLE_SCENE := "res://games/es1/battle.tscn"
const LIBRARY_SCENE := "res://library.tscn"

var _seg := ""
var _cam: Camera3D
var _follow: Node3D
var _follow_dir := Vector3.FORWARD
var _lock_dir := false
var _dir_from_basis := false
var _cam_params := {"distance": 9.0, "height": 3.5, "side": 2.5, "look": 1.6}
var _battle: Battle
var _shot: BattleShot
var _steer: Array = []        # [pilot, missile, target] while steering an EO missile
var _home := Vector3.ZERO
var _ctf_map := "tribes2:Katabatic"
var _herc := "es1:RAPTOR"
var _foes := ""
var _ipack := ""
var _arena := 0
var _secs := 12.0
var _force: Array = []        # [bot brain, flag] while the grabber is sent for the flag


func _ready() -> void:
	process_priority = 1000
	process_physics_priority = 1000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seg="):
			_seg = a.substr(6)
		if a.begins_with("--map="):
			_ctf_map = a.substr(6)
		if a.begins_with("--herc="):
			_herc = a.substr(7)
		if a.begins_with("--foes="):
			_foes = a.substr(7)
		if a.begins_with("--ipack="):
			_ipack = a.substr(8)
		if a.begins_with("--arena="):
			_arena = int(a.substr(8))
		if a.begins_with("--secs="):
			_secs = float(a.substr(7))
	Sfx.music_volume_db = -80.0
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		push_error("social: segment timed out")
		get_tree().quit(1))
	match _seg:
		"menus":
			await _menus()
		"ctf":
			await _ctf()
		"dm":
			await _dm()
		"missile":
			await _missile()
		"cmdmap":
			await _cmdmap()
		"riders":
			await _riders()
		"hgame":
			await _hgame()
		"mixed":
			await _mixed()
		"ss":
			var spec := VideoShots.make_spec("starsiege_chase")
			var sh := await _make_shot(spec)
			mark("action")
			sh.play()
			await _wait(8.0)
			mark("end")
		_:
			push_error("social: unknown segment " + _seg)
	get_tree().quit()


func mark(name: String) -> void:
	print("social: mark %s frame=%d" % [name, Engine.get_process_frames()])


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _process(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # never hold the user's mouse
	if _battle and is_instance_valid(_battle) and _battle.overlay:
		_battle.overlay.hud.messages.clear()
		if _battle.overlay.cockpit:
			_battle.overlay.cockpit.messages.clear()
		if _battle.chat and _battle.chat.panel:
			_battle.chat.panel.visible = false
		if _battle.overlay.objectives:
			_battle.overlay.objectives.visible = false
		if _battle.overlay.scoreboard:
			_battle.overlay.scoreboard.visible = false
	if _cam and is_instance_valid(_follow):
		_update_follow(delta)


func _physics_process(_delta: float) -> void:
	if _force.size() == 2:
		var brain = _force[0]
		var fl: ModeObject = _force[1]
		if not is_instance_valid(brain):
			_force = []
		elif fl.state == ModeObject.CARRIED and _home != Vector3.ZERO:
			brain.objective = {"point": _home, "urgent": true, "radius": 2.0}
		elif fl.state != ModeObject.CARRIED:
			brain.objective = {"point": fl.pos, "urgent": true, "radius": 2.0}
	if _steer.size() == 3:
		var pilot: Herc = _steer[0]
		var m = pilot.missile_steering.steered if pilot.missile_steering.is_steering() else _steer[1]
		_steer[1] = m
		var target: Herc = _steer[2]
		if not is_instance_valid(m) or not is_instance_valid(target):
			_steer = []
			return
		var want: Vector3 = (target.global_position + Vector3.UP * 4.0 - m.global_position).normalized()
		var h: Vector3 = m.make_heading()
		pilot.missile_steering.stick = Vector2(clampf(-h.cross(want).y * 4.0, -1, 1), clampf(-(want.y - h.y) * 4.0, -1, 1))


# ------------------------------------------------------------------ follow camera

func _make_camera(parent: Node) -> Camera3D:
	var c := Camera3D.new()
	c.fov = 62.0
	c.far = 4000.0
	parent.add_child(c)
	c.current = true
	return c


func _update_follow(delta: float) -> void:
	var v: Vector3 = _follow.get("velocity") if _follow.get("velocity") != null else Vector3.ZERO
	var flat := Vector3(v.x, 0, v.z)
	if _dir_from_basis:
		var fz: Vector3 = -_follow.global_basis.z
		flat = Vector3(fz.x, 0, fz.z) * 5.0
	if flat.length() > 1.0 and not _lock_dir:
		_follow_dir = _follow_dir.lerp(flat.normalized(), clampf(delta * 1.5, 0, 1)).normalized()
	var right := _follow_dir.cross(Vector3.UP).normalized()
	var want: Vector3 = _follow.global_position - _follow_dir * float(_cam_params.distance) + Vector3.UP * float(_cam_params.height) + right * float(_cam_params.side)
	var eye: Vector3 = _follow.global_position + Vector3.UP * 1.5
	var q := PhysicsRayQueryParameters3D.create(eye, want)
	if _battle:
		q.exclude = _battle.vehicles.values().map(func(x): return x.get_rid())
	var hit := _follow.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		want = eye + (hit.position - eye) * 0.85
	var k := clampf(delta * 4.0, 0, 1)
	_cam.global_position = want if _cam.global_position == Vector3.ZERO else _cam.global_position.lerp(want, k)
	_cam.look_at(_follow.global_position + Vector3.UP * float(_cam_params.look) + _follow_dir * 6.0, Vector3.UP)
	_cam.current = true


# ------------------------------------------------------------------ menus

func _menus() -> void:
	PlayerProfile.apply_name("Pilot")
	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	win.content_scale_size = Vector2i(1280, 720)
	var lib: Node = load(LIBRARY_SCENE).instantiate()
	get_tree().root.add_child(lib)
	get_tree().current_scene = lib
	await _wait(1.0)
	mark("home")
	await _wait(3.0)
	lib.call("open_launcher", "vs")
	await _frames(4)
	var launcher: Node = get_tree().current_scene
	var host: Node = launcher.get("current")
	mark("host")
	await _wait(1.2)
	host.call("select_map", "Dust to Dust")
	await _wait(1.0)
	var gm: OptionButton = host.get("_game_mode")
	gm.grab_focus()
	gm.show_popup()
	mark("dropdown")
	var pop := gm.get_popup()
	for i in pop.item_count:
		await _wait(0.35)
		pop.set_focused_item(i)
	await _wait(0.6)
	pop.set_focused_item(2)
	await _wait(0.5)
	pop.hide()
	host.call("select_game_mode", "ctf")
	mark("ctf_picked")
	await _wait(0.8)
	var bots: HSlider = host.get("_bots")
	var ai: HSlider = host.get("_ai")
	for v in range(int(bots.value), 9):
		bots.value = v
		await _wait(0.08)
	ai.value = 4
	await _wait(0.4)
	var teams: Control = host.get("_teams")
	teams.assign_all_requested.emit()
	var scroll := _find_scroll(teams)
	if scroll:
		var tw := create_tween()
		tw.tween_property(scroll, "scroll_vertical", int(scroll.get_v_scroll_bar().max_value), 1.2).set_trans(Tween.TRANS_SINE)
	mark("teams")
	await _wait(3.5)
	mark("end")


func _find_scroll(n: Node) -> ScrollContainer:
	var p := n.get_parent()
	while p:
		if p is ScrollContainer:
			return p
		p = p.get_parent()
	return null


# ------------------------------------------------------------------ battles

func _start_battle(herc: String, extra: Dictionary) -> Battle:
	var config := BattleSetup.make_default_config(herc)
	config.merge(extra, true)
	var b: Battle = load(BATTLE_SCENE).instantiate()
	b.config = config
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	for i in 30:
		await get_tree().physics_frame
	_battle = b
	return b


func _ctf() -> void:
	var ai: Array = []
	if _foes == "":
		ai = [{"vehicle": "es1:RAPTOR", "team": 0, "skill": 0.6}, {"vehicle": "starsiege:kn_basl", "team": 1, "skill": 0.6},
			{"vehicle": "es2:OGRE", "team": 1, "skill": 0.6}]
	elif _foes != "none":
		var t := 0
		for f in _foes.split(","):
			ai.append({"vehicle": f, "team": t % 2, "skill": 0.6})
			t += 1
	var cfg := {"map": _ctf_map, "game_mode": "ctf", "team_count": 2, "teams": true, "start": "on_foot",
		InfantryBots.CONFIG_KEY: 8, "ai": ai}
	if _ipack != "":
		cfg["infantry_pack"] = _ipack
	var b := await _start_battle(_herc, cfg)
	b.overlay.visible = false
	var director: GameModeDirector = b.game_mode
	director.brains.apply_goals()
	var grabber: Infantry = null
	var west: Array = director.rules.objects_of(ModeObject.KIND_FLAG).filter(func(f: ModeObject) -> bool: return f.pos.x < 0.0)
	var west_team: int = west[0].team if not west.is_empty() else -99
	for s in b.infantry.bots.make_bot_soldiers():
		if grabber == null and s.team != west_team and s.get_node_or_null("Bot"):
			grabber = s
	if grabber == null:
		push_error("social: no flag grabber")
		return
	var flag: ModeObject = director.rules.objects_of(ModeObject.KIND_FLAG).filter(func(f: ModeObject) -> bool: return f.team != grabber.team)[0]
	var start := _make_clear_start(b, flag.pos, 30.0)
	var dir := Vector3(flag.pos.x - start.x, 0, flag.pos.z - start.z).normalized()
	grabber.global_position = start
	grabber.velocity = Vector3.ZERO
	grabber.look_at(Vector3(flag.pos.x, start.y, flag.pos.z), Vector3.UP)
	_follow_dir = dir
	_force = [grabber.get_node("Bot"), flag]
	var own: Array = director.rules.objects_of(ModeObject.KIND_FLAG).filter(func(f: ModeObject) -> bool: return f.team == grabber.team)
	if not own.is_empty():
		_home = own[0].home
	print("social: grabber %s flag at %s start %s" % [grabber.display_name, flag.pos, start])
	# Hercs on both sides of the run, tough enough to outlast the base turrets for the shot.
	var hercs := b.vehicles.values().filter(func(v) -> bool: return not (v is Infantry) and v != b.player and v.alive)
	var k := 0
	var right := dir.cross(Vector3.UP).normalized()
	for h in hercs:
		var at: Vector3 = flag.pos + dir * (35.0 + 12.0 * k) + right * (-30.0 if k % 2 == 0 else 30.0)
		at.y = MapBuilder.ground_height(b, at) + 1.0
		h.global_position = at
		h.velocity = Vector3.ZERO
		BattleShot._apply_toughness(h, 8.0)
		k += 1
	_cam = _make_camera(b)
	_follow = grabber
	_cam_params = {"distance": 9.0, "height": 4.5, "side": 4.0, "look": 1.0}
	_lock_dir = true
	await _wait(0.2)
	mark("action")
	var took := false
	var t := 0.0
	var after := 0.0
	while t < 16.0 and after < 6.0:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		if took:
			after += dt
		if not took and flag.state == ModeObject.CARRIED:
			took = true
			mark("grab")
			var carrier = b.vehicles.get(flag.carrier)
			print("social: flag taken by %s" % (carrier.display_name if carrier else str(flag.carrier)))
			if carrier and carrier != _follow:
				_follow = carrier
			_lock_dir = false
	print("social: took=%s" % took)
	mark("end")


## A spot up to `dist` m from `goal` reached over a flat walkway at the goal's level (buildings included) with a
## clear line to it: the longest such run out of 36 directions.
func _make_clear_start(b: Battle, goal: Vector3, dist: float) -> Vector3:
	var space := b.get_world_3d().direct_space_state
	var ex: Array = b.vehicles.values().map(func(v): return v.get_rid())
	var best := goal
	var best_len := 0.0
	for i in 36:
		var d := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 36.0)
		var run := 0.0
		var r := 3.0
		while r <= dist:
			var at := goal + d * r
			var q := PhysicsRayQueryParameters3D.create(Vector3(at.x, goal.y + 6.0, at.z), Vector3(at.x, goal.y - 4.0, at.z))
			q.exclude = ex
			var hit := space.intersect_ray(q)
			if hit.is_empty() or absf((hit.position as Vector3).y - goal.y) > 1.2:
				break
			var los := PhysicsRayQueryParameters3D.create(Vector3(at.x, goal.y + 1.5, at.z), goal + Vector3.UP * 1.5)
			los.exclude = ex
			var block := space.intersect_ray(los)
			if not block.is_empty() and (block.position as Vector3).distance_to(goal) > 2.5:
				break
			run = r
			r += 2.0
		if run > best_len:
			best_len = run
			best = goal + d * run
	print("social: walkway %.0f m" % best_len)
	var q2 := PhysicsRayQueryParameters3D.create(Vector3(best.x, goal.y + 6.0, best.z), Vector3(best.x, goal.y - 4.0, best.z))
	q2.exclude = ex
	var h2 := space.intersect_ray(q2)
	best.y = ((h2.position as Vector3).y if not h2.is_empty() else goal.y) + 1.0
	return best


func _dm_config() -> Dictionary:
	return {"mode": "vs", "map": "es1:desert_day", "game_mode": "team_deathmatch", "teams": true, "team_count": 2,
		"respawn": false}


func _make_shot(spec: Dictionary) -> BattleShot:
	var s := BattleShot.new()
	s.spec = spec
	add_child(s)
	await s.prepare()
	_battle = s.battle
	_shot = s
	return s


func _dm() -> void:
	var s := await _make_shot({"kind": "battle", "herc": "es1:RAPTOR", "view": "cockpit", "pilot": "ai",
		"config": _dm_config(),
		"ai": [{"vehicle": "es1:PANTHER", "team": 0, "skill": 0.7}, {"vehicle": "es1:SCORPION", "team": 1, "skill": 0.5},
			{"vehicle": "es1:MONGOOSE", "team": 1, "skill": 0.5}, {"vehicle": "es1:BULLDOG", "team": 1, "skill": 0.5},
			{"vehicle": "es1:SCORPION", "team": 1, "skill": 0.5}, {"vehicle": "es1:APOLLO", "team": 1, "skill": 0.5}],
		"stage": [[110, -15], [150, 30], [190, -40], [230, 20], [260, -10]], "stage_allies": [[20, -35]],
		"enemy_health": [0.25, 0.45, 0.6, 0.7, 0.7],
		"settle": 1.0, "chase": {"distance": 24.0, "height": 8.0, "side": 8.0}})
	mark("action")
	s.play()
	await _wait(5.0)
	mark("chase")
	var b := s.battle
	b.overlay.visible = false
	_follow_dir = -Vector3(b.player.global_basis.z.x, 0, b.player.global_basis.z.z).normalized()
	_dir_from_basis = true
	_cam_params = {"distance": 22.0, "height": 8.0, "side": 8.0, "look": 6.0}
	_cam = _make_camera(b)
	_follow = b.player
	await _wait(7.0)
	mark("end")


func _missile() -> void:
	var s := await _make_shot({"kind": "battle", "herc": "es1:RAPTOR", "view": "cockpit", "pilot": "inputs",
		"inputs": [],
		"config": _dm_config(), "ai": [{"vehicle": "es1:APOLLO", "team": 1, "skill": 0.0}],
		"stage": [[150, 0]], "enemy_health": [0.05], "settle": 1.0})
	var b := s.battle
	var p := b.player
	p.equip(["es1:MLRS6_EO"])
	await _frames(3)
	var target: Herc = null
	for v in b.vehicles.values():
		if v != p and v.team != p.team:
			target = v
	var cockpit = b.overlay.cockpit
	if cockpit:
		cockpit.mfd_mode = CockpitMfd.MODE_MISSILE
	s.play()
	mark("action")
	await _wait(0.8)
	b.pilot.set("_autofire", true)
	var t := 0.0
	while t < 2.0 and not p.missile_steering.is_steering():
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	if not p.missile_steering.is_steering() or target == null:
		push_error("social: no steered missile")
		return
	mark("fire")
	_steer = [p, p.missile_steering.steered, target]
	t = 0.0
	var dbg := 0
	while t < 8.0 and _steer.size() == 3:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		dbg += 1
		if dbg % 30 == 0 and is_instance_valid(_steer[1]):
			print("social: dbg steering=%s stick=%s m=%s tgt=%s guidance=%s tr=%s v=%s same=%s" % [p.missile_steering.is_steering(), p.missile_steering.stick, _steer[1].global_position.snapped(Vector3.ONE), target.global_position.snapped(Vector3.ONE), _steer[1].get("guidance"), _steer[1].turn_rate, _steer[1].make_heading().snapped(Vector3.ONE*0.01), _steer[1] == p.missile_steering.steered])
	mark("hit")
	b.pilot.set("_autofire", false)
	print("social: target alive=%s integrity=%.2f" % [target.alive, target.integrity])
	await _wait(1.8)
	mark("end")


func _cmdmap() -> void:
	var s := await _make_shot({"kind": "battle", "herc": "es1:RAPTOR", "view": "cockpit", "pilot": "inputs", "inputs": [],
		"config": _dm_config(),
		"ai": [{"vehicle": "es1:PANTHER", "team": 0, "skill": 0.5}, {"vehicle": "es1:RAPTOR", "team": 0, "skill": 0.5},
			{"vehicle": "es1:SCORPION", "team": 1, "skill": 0.4}, {"vehicle": "es1:BULLDOG", "team": 1, "skill": 0.4}],
		"stage": [[300, -40], [330, 60]], "stage_allies": [[25, -30], [25, 30]], "settle": 1.0})
	var b := s.battle
	s.play()
	mark("action")
	await _wait(0.8)
	var input := b.get_node(CommandMapInput.NODE_NAME) as CommandMapInput
	input.apply_toggle()
	await _frames(3)
	var map := CommandMap.find_open(b)
	if map == null:
		push_error("social: no command map")
		return
	mark("open")
	await _wait(1.6)
	var orders := map.orders
	var entry := {}
	for kind in [CommandGoal.MOVE, CommandGoal.DEFEND]:
		for menu in ["location", "nav"]:
			for e in orders.make_menu(menu):
				if entry.is_empty() and str(e.kind) == kind:
					entry = e
	var spot: Vector3 = b.player.global_position - b.player.global_basis.z * 220.0 + b.player.global_basis.x * 60.0
	spot.y = MapBuilder.ground_height(b, spot)
	var mp := map.view.to_map(spot)
	map.view.set("cursor", mp)
	map._on_picked(map.view.make_pick(mp))
	mark("picked")
	await _wait(1.4)
	if not entry.is_empty():
		for e in orders.make_menu(str(map.pick.menu)):
			if str(e.kind) == str(entry.kind):
				entry = e
		map.give(entry)
		print("social: order %s" % entry.label)
	mark("ordered")
	await _wait(2.2)
	map.close()
	mark("closed")
	await _wait(1.5)
	mark("end")


func _riders() -> void:
	var b := await _start_battle("es1:RAPTOR", {"map": "tribes2:Katabatic", "ai": [], "infantry_pack": "tribes2"})
	b.overlay.visible = false
	var vid := "tribes2:HAVOC"
	var site := b.player.global_position + Vector3(60, 0, 60)
	site.y = MapBuilder.ground_height(b, site) + 40.0
	var id := b.spawner.allocate_id()
	b.send_spawn({"net_id": id, "vehicle": vid, "team": 0, "owner": 0, "xf": Transform3D(Basis(), site),
		"loadout": [], "name": vid, "ai": {}, "parked": true})
	var v: Herc = b.vehicles.get(id)
	var seats := InfantryGear.seats_of(vid)
	var peer := 1001
	for i in seats.size():
		var spec := b.infantry.make_soldier_spec(peer, 0, "Rider %d" % i, v.global_transform)
		spec.merge({"vehicle": "tribes2:LIGHT", "armor": "tribes2:LIGHT", "spawn_armor": "tribes2:LIGHT",
			"loadout": InfantryCatalog.armor("tribes2:LIGHT").get("default_loadout", [])}, true)
		b.send_spawn(spec)
		var sol := b.vehicles.get(spec.net_id) as Infantry
		var occ := VehicleOccupancy.of(v)
		occ.apply_seat(i, peer)
		b.occupancy._apply_state(v.net_id, occ.seats.duplicate(), sol.net_id, true, sol.global_transform, peer)
		peer += 1
	v.set_physics_process(false)
	_cam = _make_camera(b)
	await _frames(10)
	mark("action")
	var t := 0.0
	var heading := 0.0
	var pos := site
	while t < 7.0:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		heading += dt * 0.12
		var fwd := Vector3(sin(heading), 0, cos(heading)) * -1.0
		pos += fwd * 22.0 * dt
		var ground := MapBuilder.ground_height(b, pos)
		pos.y = lerpf(pos.y, maxf(pos.y, ground + 30.0), clampf(dt * 2.0, 0, 1))
		v.global_transform = Transform3D(Basis(Vector3.UP, heading).rotated(fwd.cross(Vector3.UP).normalized(), -0.05), pos)
		var side := fwd.cross(Vector3.UP).normalized()
		var orbit := lerpf(-0.9, 0.9, t / 7.0)
		var off := (-fwd * cos(orbit) + side * sin(orbit)).normalized() * 18.0 + Vector3.UP * 5.0
		_cam.global_position = pos + off
		_cam.look_at(pos + Vector3.UP * 1.0, Vector3.UP)
		_cam.current = true
	mark("end")


func _hgame() -> void:
	var cfg := {"mode": "vs", "game_mode": "team_deathmatch", "teams": true, "team_count": 2, "respawn": false}
	if _arena > 0:
		cfg = {"mode": "vs", "game_mode": "deathmatch", "respawn": true,
			"arena": {"obstacles": "SEVERAL", "turrets": "FEW", "lighting": "BRIGHT", "size": _arena}}
	else:
		cfg["map"] = _ctf_map
	var ai := []
	var t := 0
	for f in _foes.split(","):
		ai.append({"vehicle": f, "team": 1 if _arena == 0 else t, "skill": 0.55})
		t += 1
	if _arena == 0:
		ai[0].team = 0
	var s := await _make_shot({"kind": "battle", "herc": _herc, "view": "cockpit", "pilot": "ai", "config": cfg, "ai": ai,
		"settle": 1.0, "chase": {"distance": 24.0, "height": 8.0, "side": 8.0}})
	mark("action")
	s.play()
	if _arena > 0:
		await _wait(_secs)
		mark("end")
		return
	await _wait(3.0)
	var b := s.battle
	b.overlay.visible = false
	_follow_dir = -Vector3(b.player.global_basis.z.x, 0, b.player.global_basis.z.z).normalized()
	_dir_from_basis = true
	_cam_params = {"distance": 22.0, "height": 8.0, "side": 8.0, "look": 6.0}
	_cam = _make_camera(b)
	_follow = b.player
	await _wait(_secs)
	mark("end")


func _mixed() -> void:
	# Varuna's Fall: Hercs of three games + a Tribes 2 flyer + infantry
	var ai := [
		{"vehicle": "es1:APOLLO", "team": 1, "skill": 0.6}, {"vehicle": "es2:OGRE", "team": 1, "skill": 0.6},
		{"vehicle": "starsiege:kn_apoc", "team": 0, "skill": 0.6}, {"vehicle": "starsiege:cy_adju", "team": 1, "skill": 0.6},
		{"vehicle": "bd:STRYDER", "team": 0, "skill": 0.6}, {"vehicle": "tribes2:SHRIKE", "team": 0, "skill": 0.6, "flyer": true},
		{"vehicle": "tribes2:BEOWULF", "team": 1, "skill": 0.6}]
	if _foes == "none":
		ai = []
	elif _foes != "":
		ai = []
		var tt := 0
		for f in _foes.split(","):
			ai.append({"vehicle": f, "team": tt % 2, "skill": 0.6})
			tt += 1
	var b := await _start_battle(_herc, {"map": _ctf_map, "game_mode": "team_deathmatch", "team_count": 2, "teams": true,
		"start": "on_foot", InfantryBots.CONFIG_KEY: 10, "infantry_pack": _ipack if _ipack != "" else "tribes2", "ai": ai})
	b.overlay.visible = false
	var director: GameModeDirector = b.game_mode
	director.brains.apply_goals()
	var soldiers: Array = b.infantry.bots.make_bot_soldiers()
	print("social: mixed soldiers=%d vehicles=%d" % [soldiers.size(), b.vehicles.size()])
	var lead: Node3D = null
	for s in soldiers:
		if lead == null:
			lead = s
	if lead == null:
		push_error("social: no soldier")
		return
	# gather everything around the lead soldier on open ground
	var k := 0
	var at0: Vector3 = lead.global_position
	for v in b.vehicles.values():
		if v is Infantry or v == b.player or not v.alive:
			continue
		var ang := TAU * float(k) / 7.0
		var at: Vector3 = at0 + Vector3(sin(ang), 0, cos(ang)) * (28.0 + 5.0 * k)
		at.y = MapBuilder.ground_height(b, at) + (14.0 if v.get("flyer") else 1.0)
		v.global_position = at
		v.velocity = Vector3.ZERO
		BattleShot._apply_toughness(v, 8.0)
		k += 1
	_cam = _make_camera(b)
	_follow = lead
	_cam_params = {"distance": 14.0, "height": 6.0, "side": 3.0, "look": 2.0}
	await _wait(0.2)
	mark("action")
	await _wait(_secs)
	mark("end")

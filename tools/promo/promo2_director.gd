extends Node
## Promo capture: --seg=choose | cloak | aa | aa2 | train | veng
const LAUNCHER := "res://launcher.tscn"
var _seg := ""
var _secs := 10.0
var _cam: Camera3D
var _battle: Battle
var _launcher: Launcher
var _lobby: LobbyScreen
var _setup: OperatorSetup
var _host: Control
var _xf := Transform3D.IDENTITY
var _override := false
var _mission_name := ""
var _wave := false
var _pack := ""
var _index := 0
var _overlay := false
var _focus: Node3D
var _orbit := Vector4(6.0, 2.2, 0.0, 0.0)   # radius, height, start angle, rad/s
var _look_h := 1.4
var _t := 0.0
var _focus_mode := "player"
var _cluster: Node3D
var _cam_on := true
var _walk := false
var _clear := true
var _behind := false
var _jet_at := -1.0
var _seed: Node3D
var _map := "tribes2:Katabatic"
var _cloak_off := 99.0
var _site_dx := 0.0
var _site_dz := 0.0
var _heading := 0.0
var _cam_ang := 0.9


func _ready() -> void:
	process_priority = 1000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seg="): _seg = a.substr(6)
		if a.begins_with("--secs="): _secs = float(a.substr(7))
		if a.begins_with("--mission="): _mission_name = a.substr(10)
		if a.begins_with("--map="): _map = a.substr(6)
		if a.begins_with("--cloakoff="): _cloak_off = float(a.substr(11))
		if a.begins_with("--sitedx="): _site_dx = float(a.substr(9))
		if a.begins_with("--sitedz="): _site_dz = float(a.substr(9))
		if a.begins_with("--heading="): _heading = float(a.substr(10))
		if a.begins_with("--camang="): _cam_ang = float(a.substr(9))
		if a.begins_with("--pack="): _pack = a.substr(7)
		if a.begins_with("--index="): _index = int(a.substr(8))
		if a.begins_with("--overlay="): _overlay = a.substr(10) == "1"
		if a.begins_with("--cam="): _cam_on = a.substr(6) == "1"
		if a.begins_with("--clear="): _clear = a.substr(8) == "1"
		if a.begins_with("--walk="): _walk = a.substr(7) == "1"
		if a.begins_with("--behind="): _behind = a.substr(9) == "1"
		if a.begins_with("--jet="): _jet_at = float(a.substr(6))
		if a.begins_with("--wave="): _wave = a.substr(7) == "1"
		if a.begins_with("--orbit="):
			var p := a.substr(8).split(",")
			_orbit = Vector4(float(p[0]), float(p[1]), float(p[2]), float(p[3]))
		if a.begins_with("--focus="): _focus_mode = a.substr(8)
		if a.begins_with("--lookh="): _look_h = float(a.substr(8))
	Sfx.music_volume_db = -80.0
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		push_error("promo2: segment timed out")
		get_tree().quit(1))
	match _seg:
		"choose": await _choose()
		"mission": await _mission()
		"aav": await _aav()
		"cloak": await _cloak()
		_: push_error("promo2: unknown seg " + _seg)
	get_tree().quit()


func mark(n: String) -> void:
	print("social: mark %s frame=%d t=%d" % [n, Engine.get_process_frames(), Time.get_ticks_msec()])

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _process(_d: float) -> void:
	if _setup != null and _setup.tooltip != null:
		_setup.tooltip.visible = false
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _battle != null and is_instance_valid(_battle) and _overlay and _clear and _battle.overlay and _battle.overlay.hud:
		_battle.overlay.hud.messages.clear()
	if _jet_at >= 0.0 and _override and _t >= _jet_at:
		Input.action_press("jet")
	if _battle != null and is_instance_valid(_battle) and not _overlay:
		for n in _battle.find_children("*", "CanvasLayer", true, false):
			(n as CanvasLayer).visible = false
	if _override and _battle != null and _battle.cameras != null:
		_t += _d
		if _cluster != null and is_instance_valid(_seed) and _battle != null:
			var sum := Vector3.ZERO
			var n := 0
			var rt = _battle.mission
			for e in rt.enemies:
				if is_instance_valid(e) and is_instance_valid(e.soldier) and e.soldier.global_position.distance_to(_seed.global_position) < 30.0:
					sum += e.soldier.global_position
					n += 1
			if n > 0:
				_cluster.global_position = _cluster.global_position.lerp(sum / n, clampf(_d * 4.0, 0.0, 1.0))
		if _focus != null and is_instance_valid(_focus):
			var ang := _orbit.z + _orbit.w * _t
			if _behind:
				var bz := _focus.global_basis.z
				ang += atan2(bz.x, bz.z)
			var tgt := _focus.global_position + Vector3(0, _look_h, 0)
			var xf0 := Transform3D(Basis.IDENTITY, tgt + Vector3(sin(ang) * _orbit.x, _orbit.y - _look_h, cos(ang) * _orbit.x))
			_xf = xf0.looking_at(tgt, Vector3.UP)
		var c: Camera3D = _battle.cameras.chase_cam
		c.far = 6000.0
		c.current = true
		c.global_transform = _xf


func _fake(peer: int, nm: String, team: int, armor: String, veh: String, ready := true) -> void:
	Net.roster[peer] = {"name": nm, "vehicle": veh, "team": team, "ready": ready, "loadout": [], "infantry_armor": armor}


func _choose() -> void:
	var nm := "Marrow"
	PlayerProfile.apply_name(nm)
	var prof := OperatorProfile.new()
	prof.apply_new(nm)
	prof.credits = 40000
	prof.save()
	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	win.content_scale_size = Vector2i(1366, 768)
	Net.host_offline()
	var s := GameOptionsModel.make_default_settings("vs", false)
	s = GameOptionsModel.make_with_game_mode(s, "team_deathmatch")
	s["ai"] = 0
	s[InfantryBots.CONFIG_KEY] = 0
	Net.set_settings(s)
	_launcher = load(LAUNCHER).instantiate()
	get_tree().root.add_child(_launcher)
	await _frames(6)
	_lobby = _launcher.go("lobby", {"kind": "vs", "solo": false}) as LobbyScreen
	await _frames(6)
	Net.roster[1].team = 0
	_fake(4001, "Kira", 0, "tribes2:MEDIUM", "starsiege:kn_apoc")
	_fake(4002, "Dax", 0, "tribes2:HEAVY", "es2:OGRE")
	_fake(4003, "Nyx", 0, "tribes2:LIGHT", "es1:RAPTOR")
	_fake(4004, "Pike", 0, "tribes2:MEDIUM", "starsiege:cy_adju")
	_fake(4005, "Vesper", 1, "tribes2:LIGHT", "es1:PANTHER")
	_fake(4006, "Tolliver", 1, "tribes2:HEAVY", "bd:STRYDER", false)
	Net.roster_changed.emit()
	await _wait(1.2)
	get_viewport().warp_mouse(Vector2(3, 3))
	mark("lobby")
	var car: TeamCarousel = _lobby.carousel
	await _wait(2.0)
	car.step(1)
	await _wait(2.2)
	car.step(1)
	await _wait(2.2)
	car.toggle_mode()
	mark("vehicles")
	await _wait(2.4)
	car.step(1)
	await _wait(2.2)
	car.toggle_mode()
	mark("infantry")
	await _wait(1.4)
	# right-drag orbit, eased
	var ring: TeamRing = car.ring
	mark("orbit")
	var t := 0.0
	while t < 3.2:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		ring.orbit(-dt * 0.9 * (1.0 if t < 2.2 else -1.5), dt * 0.05 * (1.0 if t < 1.6 else -1.0))
	await _wait(0.8)
	ring.reset_orbit()
	await _wait(1.0)
	mark("setup_click")
	_lobby.setup.setup_button.pressed.emit()
	await _wait(1.6)
	mark("setup")
	_setup = _find_setup(_launcher)
	if _setup == null:
		push_error("promo2: no OperatorSetup found")
		return
	_hide_lobby_around(_setup.sheet)
	get_viewport().warp_mouse(Vector2(3, 3))
	await _wait(2.0)
	_setup.store.apply_category("weapons")
	await _wait(1.4)
	_setup.store.apply_category("armour")
	await _wait(1.2)
	var wrow: StoreRow = null
	for r in _setup.store.make_controls():
		if r is StoreRow and str(r.entry.name) == "Medium Armor":
			wrow = r
	if wrow != null:
		wrow.pressed.emit()
	mark("equip_free")
	await _wait(1.8)
	_setup.tabs.make_tabs()[1].pressed.emit()
	mark("tab2")
	await _wait(1.6)
	_setup.tabs.make_tabs()[0].pressed.emit()
	await _wait(0.8)
	for cat in ["vehicles"]:
		await _wait(0.6)
		_setup.store.apply_category(cat)
		await _wait(1.0)
		var st := {}
		for r in _setup.store.make_controls():
			if r is StoreRow:
				st[r.entry.state] = int(st.get(r.entry.state, 0)) + 1
		print("social: cat %s %s" % [cat, st])
		var row := _first_row("for_sale")
		if cat == "packs":
			for r in _setup.store.make_controls():
				if r is StoreRow and str(r.entry.name) == "Energy Pack":
					row = r
		if row != null:
			row.pressed.emit()
			await _wait(1.5)
			mark("buy_" + cat)
			var d := _find_dialog(_launcher)
			if d != null:
				d.confirm_button.pressed.emit()
			print("social: row %s dialog=%s" % [row.entry.name, d != null])
			await _wait(2.2)
	_setup.store.apply_category("skins")
	await _wait(2.0)
	mark("end")


func _find_setup(n: Node) -> OperatorSetup:
	for c in n.find_children("*", "", true, false):
		if c is OperatorSetup:
			return c
	return null

func _find_dialog(n: Node) -> ConfirmDialog:
	for c in n.find_children("*", "", true, false):
		if c is ConfirmDialog:
			return c
	return null

func _first_row(state: String, skip := 0) -> StoreRow:
	for r in _setup.store.make_controls():
		if r is StoreRow and r.entry.state == state:
			if skip <= 0:
				return r
			skip -= 1
	return null


func _hide_lobby_around(keep: Node) -> void:
	var n: Node = keep
	while n != null and n != _lobby:
		var p := n.get_parent()
		for c in p.get_children():
			if c != n and c is CanvasItem:
				c.visible = false
		n = p


func _mission() -> void:
	Session.start_stage_campaign(_pack)
	var c: Object = Session.campaign
	c.index = _index
	var herc := MatchFlow.make_issued_soldier()
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = MatchFlow.make_mission_config(str(herc.vehicle), [], {})
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	_battle = b
	await _frames(45)
	var rt = b.mission
	if b.overlay:
		b.overlay.visible = _overlay
	if _wave and rt is AAMissionRuntime:
		rt._spawn_wave(0)
		rt._spawn_wave(1)
	_focus = b.player
	if _focus_mode == "enemy":
		await _frames(60)
		for b2 in rt.enemies:
			if is_instance_valid(b2) and is_instance_valid(b2.soldier):
				_focus = b2.soldier
				break
		_cluster = Node3D.new()
		add_child(_cluster)
		_cluster.global_position = _focus.global_position
		_seed = _focus
		_focus = _cluster
	if rt is AAMissionRuntime:
		await _frames(100)
		print("social: player %s" % b.player.global_position)
		for e in rt.enemies:
			if is_instance_valid(e) and is_instance_valid(e.soldier):
				print("social: enemy %s" % e.soldier.global_position)
		for e in rt.allies:
			if is_instance_valid(e) and is_instance_valid(e.soldier):
				print("social: ally %s" % e.soldier.global_position)
	_override = _cam_on
	await _frames(20)
	mark("action")
	if _walk:
		Input.action_press("throttle_up")
	await _wait(_secs)
	Input.action_release("throttle_up")
	Input.action_release("jet")
	mark("end")


func _start_battle(cfg_extra: Dictionary, herc := "es1:RAPTOR") -> Battle:
	var config := BattleSetup.make_default_config(herc)
	config.merge(cfg_extra, true)
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = config
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	await _frames(40)
	_battle = b
	return b


func _find_vehicle(b: Battle, id_part: String) -> Node3D:
	for v in b.vehicles.values():
		if v != b.player and is_instance_valid(v) and str(v.def.get("id", "")).to_lower().contains(id_part.to_lower()):
			return v
	return null


func _aav() -> void:
	var ai := [{"vehicle": "tribes_aa:AA_SCOUT", "team": 0, "skill": 0.6, "flyer": true},
		{"vehicle": "tribes_aa:AA_TRANSPORT", "team": 0, "skill": 0.6, "flyer": true},
		{"vehicle": "tribes_aa:AA_BOMBSCOUT", "team": 1, "skill": 0.6, "flyer": true}]
	var b := await _start_battle({"map": "tribes2:Katabatic", "game_mode": "team_deathmatch", "team_count": 2, "teams": true,
		"start": "on_foot", InfantryBots.CONFIG_KEY: 0, "ai": ai})
	b.overlay.visible = false
	var target := _find_vehicle(b, _mission_name)
	if target == null:
		for v in b.vehicles.values():
			print("social: veh %s %s" % [v.display_name, v.def.get("id", "")])
		push_error("promo2: vehicle not found")
		return
	for v in b.vehicles.values():
		if v != b.player:
			BattleShot._apply_toughness(v, 20.0)
	_focus = target
	_battle = b
	_override = true
	await _wait(0.3)
	mark("action")
	await _wait(_secs)
	mark("end")


func _cloak() -> void:
	var b := await _start_battle({"mode": "vs", "respawn": true, "teams": true, "map": _map, "start": "on_foot",
		"frag_limit": 500, "ai": [], InfantryBots.CONFIG_KEY: 0})
	b.overlay.visible = false
	b.set_process(false)
	var site := _find_site(b) + Vector3(_site_dx, 0, _site_dz)
	site.y = MapBuilder.ground_height(b, site)
	var s := b.spawn_soldier_for(90, 2, "Scout", Transform3D(Basis(), site + Vector3(0, 0.3, 0)))
	s.apply_armor("tribes2:LIGHT", ["tribes2:CHAINGUN"], "", "tribes2:CLOAKING_PACK")
	s.end_spawn_protection()
	(b.player as Node3D).global_position = site + Vector3(0, 0, 400)
	await _frames(30)
	var cam := Camera3D.new()
	b.add_child(cam)
	cam.current = true
	cam.fov = 55.0
	mark("action")
	var t := 0.0
	var toggled := false
	var back := false
	var wdir := Vector3(sin(_heading), 0, -cos(_heading))
	while t < _secs:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		if t > 1.6 and not toggled:
			toggled = true
			s.cloak.apply_wanted(true, s)
			mark("cloak_on")
		if t > _cloak_off and not back:
			back = true
			s.cloak.apply_wanted(false, s)
			mark("cloak_off")
		s.velocity = wdir * 4.0
		s.global_position += wdir * 4.0 * dt
		s.global_position.y = MapBuilder.ground_height(b, s.global_position) + 0.1
		var ang := _cam_ang + _heading + t * 0.05
		var tgt: Vector3 = s.global_position + Vector3(0, 1.1, 0)
		cam.global_position = tgt + Vector3(sin(ang) * 7.5, 0.8, cos(ang) * 7.5)
		cam.look_at(tgt)
	mark("end")


func _find_site(battle: Battle) -> Vector3:
	var origin := (battle.player as Infantry).global_position + Vector3(0, 0, 300)
	for ring in [0, 1, 2, 3, 4, 5, 6]:
		for k in 8:
			var a := TAU * float(k) / 8.0
			var p: Vector3 = origin + Vector3(cos(a), 0, sin(a)) * ring * 25.0
			if not battle.bounds.bounds.is_outside(p) and _is_level(battle, p):
				p.y = MapBuilder.ground_height(battle, p)
				return p
	origin.y = MapBuilder.ground_height(battle, origin)
	return origin


func _is_level(battle: Battle, p: Vector3) -> bool:
	var h0 := MapBuilder.ground_height(battle, p)
	for step in range(-60, 61, 10):
		if absf(MapBuilder.ground_height(battle, p + Vector3(0, 0, step)) - h0) > 1.5:
			return false
	return true

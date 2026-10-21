extends Node
## Promo video 2 (call-ins) capture on Varuna's Fall: --seg=intro | laser | pod | dropship | bomb | strafe | map | scope
const BOUGHT_VEHICLE := "es1:RAPTOR"
const RIFLE := "tribes2:LASER_RIFLE"
const FACTION_TEAM := 399
const PILOT := "Promo Callin"
var SKY_MAP := "Katabatic"
var _seg := ""
var _secs := 12.0
var _map_id := VarunaMap.MAP_ID
var _overlay := false
var _battle: Battle
var _rig: Camera3D
var _cam_fn := Callable()     # () -> [pos, look] each frame (smoothed)
var _smooth := 4.0
var _cut := true
var _cp := Vector3.ZERO
var _cl := Vector3.ZERO
var _t := 0.0
var _fov := 70.0
var _seed := 4242
var _game_t := 0.0
var _pod_order: CallinOrder = null
var _pod_c: CallinDirector = null
var _pod_t0 := -1.0


func _ready() -> void:
	process_priority = 1000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seg="): _seg = a.substr(6)
		if a.begins_with("--secs="): _secs = float(a.substr(7))
		if a.begins_with("--map="): _map_id = a.substr(6)
		if a.begins_with("--seed="): _seed = int(a.substr(7))
		if a.begins_with("--sky="): SKY_MAP = a.substr(6)
	Sfx.music_volume_db = -80.0
	Net.player_name = PILOT
	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		push_error("promo2c: segment timed out")
		get_tree().quit(1))
	await get_tree().process_frame
	match _seg:
		"intro": await _intro()
		"laser": await _laser()
		"pod": await _pod()
		"dropship": await _dropship()
		"bomb": await _bomb()
		"strafe": await _strafe()
		"map": await _map()
		"scope": await _scope()
		"probe": await _probe()
		_: push_error("promo2c: unknown seg " + _seg)
	get_tree().quit()


func mark(n: String) -> void:
	print("social: mark %s frame=%d t=%d" % [n, Engine.get_process_frames(), Time.get_ticks_msec()])

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()


func _process(d: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_game_t += d
	if _battle == null or not is_instance_valid(_battle):
		return
	# The falling pod animates on the wall clock; a movie render is slower than real time, so drive it from game time.
	if _pod_order != null and _pod_c != null:
		if _pod_t0 < 0.0 and _pod_order.state == CallinOrder.State.INBOUND:
			_pod_t0 = _game_t
		var m = _pod_c.fx.markers.get(_pod_order.id)
		if m != null and m.pod != null and _pod_t0 >= 0.0:
			m.fall_end = Time.get_ticks_msec() + int(maxf(_pod_order.fall_s - (_game_t - _pod_t0), 0.0) * 1000.0)
	if _overlay:
		if _battle.overlay and _battle.overlay.hud:
			_battle.overlay.hud.messages.clear()
		if _seg == "scope":
			for n in _battle.find_children("*", "Label", true, false):
				var txt := (n as Label).text
				if txt.begins_with("On foot") or txt.begins_with("Passenger") or txt.begins_with("Hostile") or txt.begins_with("OBJECTIVES") or txt.begins_with("[") :
					var par := n.get_parent()
					(n as Label).visible = false
					if par is Control and par != _battle.overlay:
						(par as Control).visible = false
	else:
		for n in _battle.find_children("*", "CanvasLayer", true, false):
			(n as CanvasLayer).visible = false
	if _rig != null and is_instance_valid(_rig) and _cam_fn.is_valid():
		_t += d
		var r: Array = _cam_fn.call()
		if _cut:
			_cp = r[0]
			_cl = r[1]
			_cut = false
		else:
			var k := 1.0 - exp(-d * _smooth)
			_cp = _cp.lerp(r[0], k)
			_cl = _cl.lerp(r[1], k)
		_rig.fov = _fov
		_rig.far = 8000.0
		_rig.look_at_from_position(_cp, _cl, Vector3.UP)
		_rig.make_current()


func _use_rig(b: Battle) -> void:
	_rig = Camera3D.new()
	_rig.far = 8000.0
	if b.cameras != null and b.cameras.chase_cam != null:
		_rig.cull_mask = b.cameras.chase_cam.cull_mask
	b.add_child(_rig)
	b.set_process(false)
	_rig.make_current()


# ------------------------------------------------------------------ raid set-up

func _prepare_profile() -> void:
	var o := OperatorProfile.load_for(PILOT)
	o.apply_raid_points(5000)
	o.unlocks.apply_add(UnlockId.make("vehicle", BOUGHT_VEHICLE))
	o.make_active_slot().vehicle = BOUGHT_VEHICLE
	o.save()


func _start_raid(fast: bool, overlay := false) -> Battle:
	var p := ExtractionProfile.load_for(PILOT)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	_prepare_profile()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": _map_id, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = fast
	config["extraction_seed"] = _seed
	var b: Battle = load("res://games/es1/battle.tscn").instantiate()
	b.config = config
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	_overlay = overlay
	if overlay:
		var win := get_window()
		win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		win.content_scale_size = Vector2i(1366, 768)
	_battle = b
	_fix_sky(b)
	await _frames(20)
	return b


## Varuna's cube-map sky shows a hard rectangular seam; the clips use a plain gradient sky instead.
func _fix_sky(b: Battle) -> void:
	for n in b.find_children("*", "WorldEnvironment", true, false):
		var e: Environment = (n as WorldEnvironment).environment
		if e == null:
			continue
		var m := ProceduralSkyMaterial.new()
		m.sky_top_color = Color(0.40, 0.55, 0.78)
		m.sky_horizon_color = Color(0.80, 0.82, 0.85)
		m.ground_horizon_color = Color(0.80, 0.82, 0.85)
		m.ground_bottom_color = Color(0.7, 0.7, 0.72)
		m.sky_curve = 0.25
		var sky := Sky.new()
		sky.sky_material = m
		e.sky = sky
		e.background_mode = Environment.BG_SKY


func _tune_air() -> void:
	var kinds: Dictionary = ExtractionRules.data().callins.kinds
	var bombing: Dictionary = kinds.bombing_run
	bombing.bombs = 6
	bombing.spacing_m = 26.0
	bombing.approach_m = 520.0
	bombing.leave_m = 300.0
	bombing.altitude_m = 80.0
	var attack: Dictionary = kinds.attack_craft
	attack.loiter_s = 40.0
	attack.approach_m = 400.0
	attack.leave_m = 250.0
	attack.wreck_s = 4.0
	ExtractionRules.data().callins.fast.shared_cooldown_s = 0.0
	ExtractionRules.data().callins.fast.marker_scale = 0.2


func _land(b: Battle) -> Infantry:
	var me := b.player as Infantry
	await _wait_for(func() -> bool: return not me.stowed, 90.0)
	await _frames(20)
	me.spawn_protection = 1.0e6
	me.apply_spawn_protection()
	return me


func _rich(c: CallinDirector) -> void:
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 5000
	c.points.mine = 5000


func _is_out_of_turret_reach(b: Battle, p: Vector3) -> bool:
	for node in b.get_children():
		if node is TribesTurret and (node as TribesTurret).global_position.distance_to(p) < (node as TribesTurret).engage_range + 80.0:
			return false
	return true


func _is_level(b: Battle, p: Vector3, tol := 1.2) -> bool:
	var h0 := MapBuilder.ground_height(b, p)
	for step in range(-40, 41, 10):
		if absf(MapBuilder.ground_height(b, p + Vector3(0, 0, step)) - h0) > tol or absf(MapBuilder.ground_height(b, p + Vector3(step, 0, 0)) - h0) > tol:
			return false
	return true


## Puts the soldier on level open ground (random map points until one passes); returns true when found.
func _place_on_open_ground(b: Battle, me: Infantry, footprint := 8.0) -> bool:
	var x := b.extraction
	for i in 200:
		var p: Vector3 = x.make_ground_point(x.map.make_random_point())
		if b.bounds != null and b.bounds.bounds.is_outside(p):
			continue
		if CallinSafety.make_reason_at(b, p, footprint, me.team).reason != "" or CallinSafety.is_covered(b, p) or not _is_level(b, p):
			continue
		if not _is_out_of_turret_reach(b, p):
			continue
		me.global_position = p + Vector3.UP * 0.3
		me.velocity = Vector3.ZERO
		await _frames(20)
		if CallinSafety.make_caller_refusal(b, me) == "":
			print("social: ground %s try %d" % [me.global_position, i])
			return true
	return false


func _find_open_spots(b: Battle, me: Infantry, n: int, rings := [18.0, 28.0, 40.0, 54.0, 70.0]) -> Array:
	var out: Array = []
	var angle := 0.0
	for ring in rings:
		for i in 12:
			var p := b.infantry.make_on_ground(me.global_position + Vector3(cos(angle), 0.0, sin(angle)) * ring)
			angle += TAU / 12.0 + 0.3
			if CallinSafety.make_reason_at(b, p, 5.0, me.team).reason != "" or CallinSafety.is_covered(b, p) or not _is_level(b, p, 1.5):
				continue
			if out.all(func(q: Vector3) -> bool: return Vector2(q.x - p.x, q.z - p.z).length() > 16.0):
				out.append(p)
			if out.size() >= n:
				return out
	return out


func _spawn_hostile(b: Battle, at: Vector3, with_brain := false) -> Infantry:
	var xf := Transform3D(Basis(), b.infantry.make_on_ground(at))
	var spec := b.infantry.make_soldier_spec(b.infantry.bots.allocate_bot_id(), FACTION_TEAM, "Hostile", xf)
	spec["bot"] = true
	spec["protection"] = 0.0
	b.send_spawn(spec)
	var s := b.vehicles.get(int(spec.net_id)) as Infantry
	s.spawn_protection = 0.0
	s.apply_spawn_protection()
	b.extraction.watch(s)
	if with_brain:
		s.add_child(InfantryBot.make(s, b.infantry.bots.allocate_bot_id(), 0.5))
	return s


func _yaw_to(from: Vector3, to: Vector3) -> float:
	return atan2(-(to.x - from.x), -(to.z - from.z))


func _aim(point: Vector3, normal := Vector3.UP, hit := true) -> Dictionary:
	return {"hit": hit, "point": point, "normal": normal, "distance": 10.0}


# ------------------------------------------------------------------ 1 the intro transport

func _intro() -> void:
	var b := await _start_raid(false)
	var craft := b.occupancy.vehicle_of(1) as Flyer
	if craft == null:
		push_error("promo2c: no transport")
		return
	print("social: transport %s" % craft.display_name)
	_use_rig(b)
	_smooth = 3.0
	_fov = 62.0
	var n := b.occupancy.soldier_of(1)
	_cam_fn = func() -> Array:
		if not is_instance_valid(craft):
			return [_cp, _cl]
		var bas := craft.global_basis.orthonormalized()
		var a := 0.15 + 0.05 * _t
		var off := Vector3(sin(a) * 46.0, 8.0, cos(a) * 52.0)
		return [craft.global_position + bas * off, craft.global_position + bas * Vector3(0, 1, -12)]
	_t = 0.0
	mark("action")
	var last := 0.0
	while _t < _secs and is_instance_valid(craft) and craft.alive:
		await get_tree().physics_frame
		if _t - last >= 1.0:
			last = _t
			print("social: t%.0f agl %.0f bank %+.0f pitch %+.0f speed %.0f stowed %s" % [_t, craft.make_altitude(), rad_to_deg(craft.flight.bank), rad_to_deg(craft.flight.pitch), craft.flight.speed, n.stowed])
	mark("end")


# ------------------------------------------------------------------ 2 the targeting laser

func _laser() -> void:
	var b := await _start_raid(true)
	var x := b.extraction
	var c := x.callins
	var me := await _land(b)
	if not await _place_on_open_ground(b, me):
		push_error("promo2c: no ground")
		return
	_rich(c)
	var spots := _find_open_spots(b, me, 4)
	print("social: spots %d" % spots.size())
	var pilot := b.pilot as InfantryPilot
	var s0: Vector3 = spots[0]
	var s1: Vector3 = spots[1]
	var yaw := _yaw_to(me.global_position, s0)
	pilot.aim_yaw = yaw
	pilot.aim_pitch = -0.2
	await _frames(5)
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var side := fwd.cross(Vector3.UP)
	var st := {"p": s0, "red": false}
	var d := c.designator
	d.aim_override = func() -> Dictionary:
		var p: Vector3 = st.p
		p.y = MapBuilder.ground_height(b, p)
		return _aim(p, Vector3(1, 0.1, 0).normalized() if st.red else Vector3.UP)
	_use_rig(b)
	_smooth = 3.0
	_fov = 62.0
	_cam_fn = func() -> Array:
		var mid: Vector3 = (me.global_position + (st.p as Vector3)) * 0.5
		return [me.global_position - fwd * (5.5 - 0.15 * _t) + side * (2.4 - 0.1 * _t) + Vector3.UP * 2.3, mid + Vector3.UP * 0.8]
	_t = 0.0
	mark("action")
	await _wait(1.0)
	d.begin("armor_drop", "medium")
	await _wait(2.2)
	mark("green")
	# sweep the dot to the second spot
	var t := 0.0
	while t < 2.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		st.p = s0.lerp(s1, smoothstep(0.0, 1.0, t / 2.0))
	st.red = true
	await _wait(2.4)
	mark("red")
	st.red = false
	t = 0.0
	while t < 1.4:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		st.p = s1.lerp(s0, smoothstep(0.0, 1.0, t / 1.4))
	await _wait(1.4)
	mark("fire")
	d.apply_confirm()
	await _wait(3.5)
	mark("end")


# ------------------------------------------------------------------ 3 the orbital pod and the stations

func _pod() -> void:
	var b := await _start_raid(true)
	var x := b.extraction
	var c := x.callins
	var me := await _land(b)
	if not await _place_on_open_ground(b, me, 10.0):
		push_error("promo2c: no ground")
		return
	_rich(c)
	var pilot := b.pilot as InfantryPilot
	var st := {"orders": [], "near": false}
	_use_rig(b)
	_smooth = 2.5
	_fov = 62.0
	_cam_fn = func() -> Array:
		var orders: Array = st.orders
		if orders.is_empty():
			return [me.global_position + Vector3(-5, 2.4, 5), me.global_position + Vector3(0, 1.4, 0)]
		var o: CallinOrder = orders[0]
		var lz := o.lz
		var m = c.fx.markers.get(o.id)
		var pod_pos := lz + Vector3.UP * 1.5
		var falling := false
		if m != null and m.pod != null and is_instance_valid(m.pod) and o.state == CallinOrder.State.INBOUND:
			pod_pos = (m.pod as Node3D).global_position
			falling = true
		if falling:
			var dir := Vector3(0.7, 0, 0.7)
			var h := maxf(pod_pos.y - lz.y, 0.0)
			return [lz + dir * 70.0 + Vector3.UP * 3.0, Vector3(pod_pos.x, minf(pod_pos.y, lz.y + 70.0), pod_pos.z)]
		var near: bool = st.near
		return [lz + Vector3(1, 0, 1).normalized() * (11.0 if near else 26.0) + Vector3.UP * (5.0 if near else 8.0), lz + Vector3.UP * (1.5 if near else 3.0)]
	_t = 0.0
	mark("action")
	await _wait(1.0)
	var order := c.apply_request(1, "armor_drop", "medium")
	if order == null:
		push_error("promo2c: armor drop refused: " + c.make_refusal(1, "armor_drop", "medium"))
		return
	st.orders = [order]
	_pod_c = c
	_pod_order = order
	print("social: order eta %.1f fall %.1f lz dist %.1f" % [order.eta, order.fall_s, order.lz.distance_to(me.global_position)])
	mark("marked")
	await _wait_for(func() -> bool: return order.state == CallinOrder.State.INBOUND, 30.0)
	mark("inbound")
	await _wait_for(func() -> bool: return order.state == CallinOrder.State.ACTIVE, 30.0)
	mark("impact")
	await _wait(2.0)
	st.near = true
	await _wait(2.6)
	# the temporary stations
	_rich(c)
	var repair := c.apply_request(1, "repair_station", "")
	print("social: station %s" % [repair != null])
	if repair != null:
		st.orders = [repair]
		_pod_order = repair
		_pod_t0 = -1.0
		st.near = false
		mark("stations_marked")
		await _wait_for(func() -> bool: return repair.state == CallinOrder.State.ACTIVE, 30.0)
		mark("stations_down")
		st.near = true
		await _wait(3.0)
		me.global_position = repair.lz + Vector3(2.2, 0.3, 0)
		await _wait(2.0)
	mark("end")


# ------------------------------------------------------------------ 4 the dropship and the Herc

func _dropship() -> void:
	var b := await _start_raid(true)
	var x := b.extraction
	var c := x.callins
	var me := await _land(b)
	var footprint := CallinDirector.make_footprint(CallinRules.KIND_VEHICLE, BOUGHT_VEHICLE)
	var found := false
	for i in 80:
		if not await _place_on_open_ground(b, me, footprint):
			continue
		var feet := c.checks.make_feet_request(1, CallinRules.KIND_VEHICLE, "")
		var approach := c.checks.make_approach_from(CallinRules.KIND_VEHICLE, feet.point)
		if CallinPlacement.make_judgement(b, feet, me, footprint, approach).ok:
			found = true
			break
	if not found:
		push_error("promo2c: no vehicle spot")
		return
	_rich(c)
	var st := {"order": null, "flyer": null, "cargo": null}
	_use_rig(b)
	_smooth = 2.0
	_fov = 60.0
	_cam_fn = func() -> Array:
		var o: CallinOrder = st.order
		if o == null:
			return [me.global_position + Vector3(-6, 3, 6), me.global_position + Vector3(0, 1.5, 0)]
		var flyer = st.flyer
		var cargo = st.cargo
		var lz := o.lz
		var fp: Vector3 = lz + Vector3.UP * 20.0
		if flyer != null and is_instance_valid(flyer):
			fp = (flyer as Node3D).global_position
		var cp := fp - Vector3.UP * 9.0
		if cargo != null and is_instance_valid(cargo):
			cp = (cargo as Node3D).global_position
		var horiz := Vector2(fp.x - lz.x, fp.z - lz.z).length()
		if o.state == CallinOrder.State.INBOUND and horiz > 140.0:
			return [fp + Vector3(80, -6, 80), fp]
		if o.state == CallinOrder.State.INBOUND or o.state == CallinOrder.State.DELIVERING:
			return [lz + Vector3(80, 8, 80), (fp + cp) * 0.5]
		return [lz + Vector3(34, 6, 34), cp + Vector3.UP * 3.0]
	_t = 0.0
	mark("action")
	await _wait(1.0)
	var order := c.apply_request(1, "vehicle_delivery", "")
	if order == null:
		push_error("promo2c: delivery refused: " + c.make_refusal(1, "vehicle_delivery", ""))
		return
	st.order = order
	print("social: delivery eta %.1f transport %s" % [order.eta, order.transport_vehicle])
	mark("marked")
	await _wait_for(func() -> bool: return order.state == CallinOrder.State.INBOUND, 40.0)
	st.flyer = b.vehicles.get(order.transport_id)
	st.cargo = b.vehicles.get(order.cargo_net_id)
	print("social: flyer %s cargo %s" % [(st.flyer as Flyer).display_name if st.flyer else "-", (st.cargo as Herc).display_name if st.cargo else "-"])
	mark("inbound")
	var released := [INF]
	await _wait_for(func() -> bool:
		if is_instance_valid(st.flyer) and order.state == CallinOrder.State.INBOUND:
			released[0] = (st.flyer as Flyer).make_altitude()
		return order.state == CallinOrder.State.DELIVERING, 90.0)
	print("social: release altitude %.1f" % released[0])
	mark("release")
	await _wait_for(func() -> bool: return order.state == CallinOrder.State.ACTIVE, 30.0)
	mark("down")
	await _wait(4.5)
	mark("end")


# ------------------------------------------------------------------ 5 the bombing run

func _make_run(x: ExtractionDirector, me: Infantry, distance: float) -> Dictionary:
	var center := x.map.make_center()
	var to_center := Vector3(center.x - me.global_position.x, 0.0, center.y - me.global_position.z).normalized()
	var point := me.global_position + to_center * distance
	return {"point": point, "dir": Vector3(-to_center.z, 0.0, to_center.x), "across": to_center}


func _bomb() -> void:
	_tune_air()
	var b := await _start_raid(true)
	var x := b.extraction
	var c := x.callins
	var me := await _land(b)
	if not await _place_on_open_ground(b, me, 10.0):
		push_error("promo2c: no ground")
		return
	_rich(c)
	var run := _make_run(x, me, 150.0)
	var point: Vector3 = run.point
	var dir: Vector3 = run.dir
	var across: Vector3 = run.across
	var order := c.apply_order(CallinRequest.make("bombing_run", "", 1, point, dir, CallinRequest.SOURCE_MAP))
	if order == null:
		push_error("promo2c: bombing refused: " + c.make_refusal(1, "bombing_run", ""))
		return
	var flight: CallinAirFlight = c.air.bombing.flights[order.id]
	var stick := c.air.bombing.make_stick(flight, CallinRules.rule("bombing_run"))
	for i in [1, 3, 4]:
		_spawn_hostile(b, stick[i] + across * (3.0 if i != 3 else -6.0))
	var mid: Vector3 = stick[stick.size() / 2]
	var st := {"phase": 0, "t2": 0.0}
	_use_rig(b)
	_smooth = 5.0
	_fov = 62.0
	_cam_fn = func() -> Array:
		var craft := c.air.bombing.make_craft(flight)
		var pilot := flight.pilot as CallinBomberPilot
		if st.phase == 0:
			if craft != null and is_instance_valid(craft) and pilot != null:
				if pilot.released >= 2:
					st.phase = 1
					st.t2 = _t
					_cut = true
				return [craft.global_position - flight.direction * 34.0 + Vector3.UP * 10.0 + across * 18.0, craft.global_position + flight.direction * 14.0 - Vector3.UP * 5.0]
			return [mid + Vector3.UP * 60.0 - across * 200.0, mid + Vector3.UP * 60.0]
		return [mid - across * 75.0 + Vector3.UP * 9.0 + dir * 25.0, mid + Vector3.UP * 5.0 - dir * 10.0]
	_t = 0.0
	mark("action")
	await _wait_for(func() -> bool: return flight.craft_id >= 0, 60.0)
	mark("bomber")
	var cr := c.air.bombing.make_craft(flight)
	print("social: bomber %s" % (cr.display_name if cr else "-"))
	await _wait_for(func() -> bool: return st.phase == 1, 60.0)
	mark("release")
	await _wait_for(func() -> bool: return flight.pilot != null and (flight.pilot as CallinBomberPilot).impacts.size() >= 6, 25.0)
	mark("impacts")
	await _wait(3.5)
	mark("end")


# ------------------------------------------------------------------ 6 the strafing attack craft

func _strafe() -> void:
	_tune_air()
	var b := await _start_raid(true)
	var x := b.extraction
	var c := x.callins
	var me := await _land(b)
	if not await _place_on_open_ground(b, me, 10.0):
		push_error("promo2c: no ground")
		return
	_rich(c)
	var run := _make_run(x, me, 120.0)
	var point: Vector3 = run.point
	var across: Vector3 = run.across
	var dir: Vector3 = run.dir
	var victims: Array = []
	for off in [Vector3.ZERO, dir * 9.0, -dir * 8.0 + across * 6.0]:
		victims.append(_spawn_hostile(b, point + across * 25.0 + off, true))
	var order := c.apply_order(CallinRequest.make("attack_craft", "", 1, point, dir, CallinRequest.SOURCE_MAP))
	if order == null:
		push_error("promo2c: attack refused: " + c.make_refusal(1, "attack_craft", ""))
		return
	var flight: CallinAirFlight = c.air.attack.flights[order.id]
	var st := {"phase": 0, "fired": -1.0}
	_use_rig(b)
	_smooth = 6.0
	_fov = 60.0
	_cam_fn = func() -> Array:
		var craft := c.air.attack.make_craft(flight)
		var v: Infantry = victims[0]
		var vp: Vector3 = v.global_position if is_instance_valid(v) else point
		if craft == null or not is_instance_valid(craft):
			return [point + Vector3(30, 20, 30), point]
		var to := vp - craft.global_position
		var firing := craft.weapons.any(func(w: Weapon) -> bool: return w.trigger)
		if st.phase == 0:
			if firing and to.length() < 160.0 and st.fired < 0.0:
				st.fired = _t
			if st.fired >= 0.0 and _t - st.fired > 4.5:
				st.phase = 1
				_cut = true
			return [craft.global_position - to.normalized() * 15.0 + Vector3.UP * 4.0 + to.normalized().cross(Vector3.UP) * 6.0, vp + Vector3.UP * 3.0]
		return [vp + Vector3(16, 2.5, 16), craft.global_position]
	_t = 0.0
	mark("action")
	await _wait_for(func() -> bool: return order.state == CallinOrder.State.ACTIVE, 60.0)
	mark("on_station")
	var cr := c.air.attack.make_craft(flight)
	print("social: craft %s" % (cr.display_name if cr else "-"))
	await _wait_for(func() -> bool: return st.phase == 1, 40.0)
	mark("pass2")
	await _wait(1.5)
	mark("end")


# ------------------------------------------------------------------ 7 the command map

func _left_click(at: Vector2) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = at
	e.global_position = at
	return e


func _glide(map: CommandMap, to_world: Vector3, secs: float) -> void:
	var from: Vector2 = map.view.cursor
	var to: Vector2 = map.view.to_map(to_world)
	var t := 0.0
	while t < secs:
		await get_tree().process_frame
		t += get_process_delta_time()
		map.view.cursor = from.lerp(to, smoothstep(0.0, 1.0, t / secs))
	map.view.cursor = to


func _map() -> void:
	_tune_air()
	var b := await _start_raid(true, true)
	var x := b.extraction
	var c := x.callins
	var me := await _land(b)
	if not await _place_on_open_ground(b, me, 10.0):
		push_error("promo2c: no ground")
		return
	_rich(c)
	var spots := _find_open_spots(b, me, 4)
	var blocker := _spawn_hostile(b, spots[2])
	await _frames(10)
	var map := CommandMap.open(b, me)
	await _frames(20)
	if map == null or map.callin_order == null:
		push_error("promo2c: no command map call-ins")
		return
	var o := map.callin_order
	map.view.cursor = map.view.to_map(me.global_position)
	mark("action")
	await _wait(2.0)
	o.begin("ammo_drop", "")
	await _wait(0.6)
	await _glide(map, spots[2], 1.4)
	o.apply_click(map.view.to_world(map.view.cursor))
	mark("refused")
	await _wait(2.0)
	b.remove_vehicle(blocker.net_id)
	await _glide(map, spots[0], 1.2)
	await _wait(1.0)
	mark("valid")
	map.view._gui_input(_left_click(map.view.cursor))
	await _wait(1.8)
	mark("ordered")
	# a bombing run: point, then the line
	_rich(c)
	o.begin("bombing_run", "")
	await _wait(0.5)
	await _glide(map, spots[3], 1.2)
	await _wait(0.5)
	map.view._gui_input(_left_click(map.view.cursor))
	await _wait(0.4)
	await _glide(map, spots[3] + Vector3(260, 0, 40), 1.4)
	await _wait(0.6)
	mark("direction")
	map.view._gui_input(_left_click(map.view.cursor))
	await _wait(3.0)
	mark("end")


# ------------------------------------------------------------------ 8 the Laser Rifle scope

func _find_clear_view(soldier: Infantry) -> Array:
	var best := [0.0, 0.0]
	var origin := soldier.aim_origin()
	for i in 36:
		var yaw := TAU * float(i) / 36.0
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 700.0, 0xFFFFFFFF, [soldier.get_rid()])
		var hit := soldier.get_world_3d().direct_space_state.intersect_ray(q)
		var dd := 700.0 if hit.is_empty() else origin.distance_to(hit.position)
		if dd > float(best[1]):
			best = [yaw, dd]
	return best


func _scope() -> void:
	var b := await _start_raid(true, true)
	var me := await _land(b)
	me.equip([RIFLE])
	var best := [0.0, 0.0]
	for i in 120:
		if not await _place_on_open_ground(b, me, 6.0):
			continue
		var v := _find_clear_view(me)
		if float(v[1]) > float(best[1]):
			best = v
		if float(v[1]) >= 450.0:
			break
	print("social: clear view %.0f deg %.0f m" % [rad_to_deg(best[0]), best[1]])
	var yaw: float = best[0]
	var dist := minf(float(best[1]) - 10.0, 400.0)
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var side := fwd.cross(Vector3.UP)
	var pilot := b.pilot as InfantryPilot
	pilot.aim_yaw = yaw
	pilot.aim_pitch = 0.0
	var targets: Array = []
	for k in 3:
		var s := _spawn_hostile(b, me.global_position + fwd * (dist - 20.0 * k) + side * (8.0 * (k - 1)), true)
		s.spawn_protection = 1.0e6
		s.apply_spawn_protection()
		targets.append(s)
	await _frames(30)
	pilot.aim_yaw = yaw
	mark("action")
	SiegeInput.last_device = SiegeInput.Device.GAMEPAD
	await _wait(1.6)
	mark("unzoomed")
	me.scope.level = 1
	me.scope.preview_left = 5.0
	await _wait(1.8)
	me.scope.level = 0
	me.scope.preview_left = 0.0
	await _wait(0.3)
	Input.action_press("scope_zoom")
	mark("zoom")
	var t := 0.0
	var lv := 0
	while t < 9.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		var want := 0 if t < 1.8 else (1 if t < 3.6 else (2 if t < 5.4 else 3))
		if want != lv:
			lv = want
			me.scope.level = lv
			print("social: scope level %d" % lv)
		var tg: Infantry = targets[0]
		if is_instance_valid(tg) and tg.alive:
			var dd := tg.global_position - me.global_position
			pilot.aim_yaw = lerp_angle(pilot.aim_yaw, atan2(-dd.x, -dd.z), 0.08)
			pilot.aim_pitch = lerpf(pilot.aim_pitch, atan2(dd.y + 1.0, Vector2(dd.x, dd.z).length()), 0.08)
	Input.action_release("scope_zoom")
	await _wait(1.0)
	mark("end")


func _probe() -> void:
	var b := await _start_raid(true)
	for n in b.find_children("*", "", true, false):
		var nm := str(n.name).to_lower()
		var cls := n.get_class()
		if nm.contains("sky") or nm.contains("cloud") or n is WorldEnvironment or nm.contains("env"):
			print("social: node %s [%s] %s" % [n.get_path(), cls, n.get("visible")])
	for n in b.find_children("*", "WorldEnvironment", true, false):
		var e: Environment = (n as WorldEnvironment).environment
		print("social: env bg %d sky %s" % [e.background_mode, e.sky])

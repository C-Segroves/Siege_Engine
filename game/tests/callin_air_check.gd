extends Node
## The air call-ins of an extraction raid (engine/extraction/callin: CallinAir, CallinBombingRun, CallinAttackCraft;
## docs/design/lobby_loadout_economy.md section 9): a bombing run and a fast attack craft, both CallinRequests with a point.
##   1 data and geometry: the rules, the line through a point clipped to the map, the stick, the airframe pick, the plain fallback
##   2 the bombing run: refusals; the bomber flies the line; the bombs land along it (the stick, in order, on the line);
##     the teammates near the line are warned "danger close" before the first release and the others are not; a kill by the
##     bombs credits the caller; the bomber is a battle vehicle (radar, EntityTable, snapshot, spawn message); it leaves
##   3 the fast attack craft: it flies to the point, engages a hostile near it and kills it (the caller is credited), hostile AI
##     targets it, it can be shot down (it crashes, the order ends), and it leaves when its time or its ammunition is gone
##   4 the cancel / caller-gone paths
## The player's own saves and profiles are kept (SavedCampaignGuard).
##   godot --headless --audio-driver Dummy --path game res://tests/callin_air_check.tscn [-- --only=<bombing|attack>]
## --shots=<dir> (needs a window, no --headless): callin_air_*.png (the bombing run, the strafing run).

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const MAP := "tribes2:Katabatic"
const SEED := 4242
const SETTLE_FRAMES := 20
const MATE_PEER := 2
const NEAR_PEER := 3
const FAR_PEER := 4
const FACTION_TEAM := 399
const POINT_DISTANCE_M := 150.0
const BOMBS := 4
const SPACING_M := 24.0
const MAX_CROSS_M := 25.0
const SPACING_SLACK_M := 14.0
const SYNC_SLACK_M := 6.0

var _pilot := "QA Air %d" % OS.get_process_id()
var _failures := 0
var _shots := ""
var _only := ""
var _trace := false
var _no_watcher := false
## --log=<file>: every line is also appended there and flushed (a killed run keeps what it printed).
var _log: FileAccess = null
var _rig: Camera3D = null
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
		if a.begins_with("--only="):
			_only = a.substr(7)
		if a.begins_with("--log="):
			_log = FileAccess.open(a.substr(6), FileAccess.WRITE)
		if a == "--trace":
			_trace = true
		if a == "--no-watcher":
			_no_watcher = true
	_guard.back_up()
	Net.player_name = _pilot
	await get_tree().process_frame
	_check_geometry()
	_check_rules_and_airframes()
	await _check_raid()
	ExtractionRules.reload()
	_guard.restore()
	_say("callin_air_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _wants(section: String) -> bool:
	return _only == "" or _only == section


func _say(text: String) -> void:
	print(text)
	if _log != null:
		_log.store_line(text)
		_log.flush()


func _expect(ok: bool, what: String) -> void:
	_say("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Takes the bomber over the area's edge and keeps it there past the damage delay and two damage ticks: a support craft is exempt
## from the out-of-area rule, so it is outside, the rule is on, and it stays unhurt.
func _check_bomber_outside_area(battle: Battle, craft: Flyer) -> void:
	var bounds: BattleBounds = battle.bounds
	var area := bounds.bounds.area
	var before := craft.integrity
	craft.global_position = Vector3(area.end.x + 300.0, craft.global_position.y, area.get_center().y)
	var wait := BattleBounds.SETTLE_SECONDS + BattleBounds.DAMAGE_DELAY + 2.0 * BattleBounds.DAMAGE_INTERVAL + 1.0
	var left := wait
	while left > 0.0 and is_instance_valid(craft):
		craft.global_position = Vector3(area.end.x + 300.0, craft.global_position.y, area.get_center().y)   # (its pilot flies on)
		await get_tree().physics_frame
		left -= get_physics_process_delta_time()
	_expect(is_instance_valid(craft) and SupportCraft.is_craft(craft) and bounds.checks_area and bounds.bounds.is_outside(craft.global_position)
		and not bounds.is_out_of_area(craft) and craft.integrity >= before,
		"the bomber, a support craft, is outside the area for %.0f s with the rule on and took no out-of-area damage" % wait)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()


func _shot(tag: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := "%s/callin_air_%s.png" % [_shots, tag]
	get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


func _free_scene() -> void:
	var s := get_tree().current_scene
	if s:
		s.queue_free()
		get_tree().current_scene = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _frames(3)


# ------------------------------------------------------------------ 1 data and geometry

func _check_geometry() -> void:
	print("1 geometry:")
	var rect := Rect2(-500.0, -400.0, 1000.0, 800.0)
	var point := Vector3(100.0, 0.0, 50.0)
	var east := Vector3(1.0, 0.0, 0.0)
	_expect(is_equal_approx(CallinAirLine.make_edge_distance(rect, point, east, 1.0, 5000.0), 400.0), "the line leaves the map 400 m east of the point")
	_expect(is_equal_approx(CallinAirLine.make_edge_distance(rect, point, east, -1.0, 5000.0), 600.0), "and enters 600 m west")
	_expect(is_equal_approx(CallinAirLine.make_edge_distance(rect, point, east, -1.0, 250.0), 250.0), "the rule's distance wins when it is nearer")
	var diag := Vector3(1.0, 0.0, 1.0).normalized()
	_expect(CallinAirLine.make_edge_distance(rect, point, diag, 1.0, 5000.0) <= 350.0 * sqrt(2.0) + 0.01, "a diagonal leaves by the nearer edge")
	_expect(CallinAirLine.make_edge_distance(rect, Vector3(900.0, 0.0, 0.0), east, 1.0, 100.0) == 0.0, "a point outside the rect has no way out ahead")
	var stick := CallinAirLine.make_stick(point, east, 4, 24.0)
	_expect(stick.size() == 4 and is_equal_approx(stick[1].distance_to(stick[2]), 24.0), "a stick of 4 bombs is 24 m apart")
	_expect(is_equal_approx((stick[0] + stick[3]).x * 0.5, point.x), "centred on the point")
	_expect(CallinAirLine.make_cross(point, east, point + Vector3(10.0, 0.0, 7.0)) == 7.0 and CallinAirLine.make_along(point, east, point + Vector3(10.0, 0.0, 7.0)) == 10.0,
		"along and cross distances")
	_expect(is_equal_approx(CallinAirLine.make_segment_distance(Vector3(5.0, 0.0, 9.0), Vector3.ZERO, Vector3(20.0, 0.0, 0.0)), 9.0)
		and is_equal_approx(CallinAirLine.make_segment_distance(Vector3(30.0, 0.0, 0.0), Vector3.ZERO, Vector3(20.0, 0.0, 0.0)), 10.0), "distance to the stick segment, ends included")
	var yaw := CallinAirLine.make_yaw_of_direction(Vector3(0.0, 0.0, -1.0))
	_expect(absf(yaw) < 0.001 and CallinAirLine.make_direction_of_yaw(yaw).distance_to(Vector3(0.0, 0.0, -1.0)) < 0.001, "the yaw of a direction and back (-Z is yaw 0)")


func _check_rules_and_airframes() -> void:
	print("  rules and airframes:")
	_expect(CallinRules.AIR_KINDS == [CallinRules.KIND_BOMBING, CallinRules.KIND_ATTACK] and CallinRules.is_air_kind("bombing_run") and not CallinRules.is_air_kind("radar_sweep"),
		"two air kinds")
	_expect(CallinRules.is_kind("bombing_run") and CallinRules.is_kind("attack_craft"), "both have rules")
	var offered := CallinRules.make_offers().map(func(o: Dictionary) -> String: return str(o.kind))
	_expect(offered.has("bombing_run") and offered.has("attack_craft"), "the menu and the command map offer both (%d rows)" % offered.size())
	var bomb_rule := CallinRules.rule("bombing_run")
	_expect((bomb_rule.airframe_ids as Array).has("starsiege:tr_drop"), "a Starsiege dropship is a bomber fallback for a pack set without Tribes 2")
	var ids: Array = (bomb_rule.airframe_ids as Array).duplicate()
	bomb_rule.airframe_ids = ["starsiege:tr_drop"]
	_expect(Packs.vehicle("starsiege:tr_drop").is_empty() or CallinAirframes.pick(bomb_rule, true) == "starsiege:tr_drop", "the dropship flies the run when it is the one installed")
	bomb_rule.airframe_ids = ids
	_expect(CallinRules.make_cost("bombing_run", "", "") == 450 and CallinRules.make_cost("attack_craft", "", "") == 500, "costs 450 and 500 RP")
	_expect(float(CallinRules.rule("bombing_run").cooldown_s) > 0.0 and int(CallinRules.rule("bombing_run").max_per_raid) > 0
		and float(CallinRules.rule("attack_craft").cooldown_s) > 0.0 and int(CallinRules.rule("attack_craft").max_per_raid) > 0, "each has a cooldown and a cap")
	_expect(CallinPlacement.is_directional("bombing_run") and CallinPlacement.is_directional("attack_craft"), "both take a direction (the second mark)")
	_expect(not bool(CallinPlacement.make_needs("bombing_run").ground), "they need no landing zone: a bomb can fall on a roof")
	var bomber := CallinAirframes.pick(CallinRules.rule("bombing_run"), true)
	var gunship := CallinAirframes.pick(CallinRules.rule("attack_craft"), false)
	print("    bomber: %s, gunship: %s, bomb: %s" % [bomber, gunship, str(CallinAirframes.make_bomb_def(bomber, CallinRules.rule("bombing_run")).get("id", "plain"))])
	_expect(bomber != "" and gunship != "", "an airframe is always found")
	_expect(CallinAirframes.pick({"airframe_ids": ["nothing:here"]}, true) == CallinAirframes.pick({}, true), "an uninstalled id falls to the best installed flyer")
	var plain := CallinAirframes.make_bomb_def("nothing:here", CallinRules.rule("bombing_run"))
	_expect(not plain.is_empty() and str(plain.kind) == "bomb", "a bomb definition always exists (the rule's plain one at worst)")
	_expect(CallinAirframes.make_loadout("nothing:here", CallinRules.rule("attack_craft")) == ["es1:LAS100"], "a gunship without a pack carries the plain gun")
	var spec := CallinAirframes.make_spec(7, gunship, 10, "attack_craft", Vector3(1, 2, 3), 0.5, [], 3.0)
	_expect(bytes_to_var(var_to_bytes(spec)).hash() == spec.hash(), "the spawn message is plain values")
	_expect(bool(spec.ai.flyer) and spec.ai.has("skill"), "an AI flyer")


# ------------------------------------------------------------------ the raid

func _start_raid() -> Battle:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var o := OperatorProfile.load_for(_pilot)
	o.apply_raid_points(5000)
	o.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": MAP, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = SEED
	for entry in [["QA Mate", 0, MATE_PEER], ["QA Near", 2, NEAR_PEER], ["QA Far", 3, FAR_PEER]]:
		var e := {"name": entry[0], "team": int(entry[1]), "kit": p.make_kit_dict()}
		MatchFlow.apply_extraction_entry(e, int(entry[1]), int(entry[1]) == 0)
		config.roster[int(entry[2])] = e
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


## The numbers of the test: short runs, short lives, a short flight.
func _tune_rules() -> void:
	var kinds: Dictionary = ExtractionRules.data().callins.kinds
	var bombing: Dictionary = kinds.bombing_run
	bombing.bombs = BOMBS
	bombing.spacing_m = SPACING_M
	bombing.approach_m = 520.0
	bombing.leave_m = 300.0
	bombing.altitude_m = 80.0
	var attack: Dictionary = kinds.attack_craft
	attack.loiter_s = 40.0
	attack.approach_m = 400.0
	attack.leave_m = 250.0
	attack.wreck_s = 4.0
	attack.max_per_raid = 20
	ExtractionRules.data().callins.fast.shared_cooldown_s = 0.0
	ExtractionRules.data().callins.fast.marker_scale = 0.2


func _soldier_on_open_ground(battle: Battle, peer: int, at: Vector3) -> Infantry:
	var s := battle.occupancy.soldier_of(peer)
	s.global_position = battle.infantry.make_on_ground(at) + Vector3.UP * 0.3
	s.velocity = Vector3.ZERO
	s.spawn_protection = 0.0
	s.apply_spawn_protection()
	return s


## A faction soldier of `team` standing at `at` (no brain unless `with_brain`).
func _spawn_hostile(battle: Battle, at: Vector3, with_brain := false) -> Infantry:
	var xf := Transform3D(Basis(), battle.infantry.make_on_ground(at))
	var spec := battle.infantry.make_soldier_spec(battle.infantry.bots.allocate_bot_id(), FACTION_TEAM, "QA Hostile", xf)
	spec["bot"] = true
	spec["protection"] = 0.0
	battle.send_spawn(spec)
	var s := battle.vehicles.get(int(spec.net_id)) as Infantry
	s.spawn_protection = 0.0
	s.apply_spawn_protection()
	battle.extraction.watch(s)
	if with_brain:
		s.add_child(InfantryBot.make(s, battle.infantry.bots.allocate_bot_id(), 0.5))
	return s


func _check_raid() -> void:
	print("2 a raid with a teammate:")
	_tune_rules()
	var battle := await _start_raid()
	var x := battle.extraction
	var c := x.callins
	var me := battle.player as Infantry
	var mate := battle.occupancy.soldier_of(MATE_PEER)
	await _wait_for(func() -> bool: return not me.stowed and not mate.stowed, 90.0)
	await _frames(20)
	c.points.apply_start_balance(1, 1000)
	if _wants("bombing"):
		await _check_bombing(battle, x, c, me, mate)
	if _wants("attack"):
		await _check_attack(battle, x, c, me)
	await _free_scene()


## The designated point `distance` metres from `me` towards the middle of the map (so it is inside), and the line through it
## that runs sideways to the way from `me`.
func _make_run(x: ExtractionDirector, me: Infantry, distance: float) -> Dictionary:
	var center := x.map.make_center()
	var to_center := Vector3(center.x - me.global_position.x, 0.0, center.y - me.global_position.z).normalized()
	var point := me.global_position + to_center * distance
	return {"point": point, "dir": Vector3(-to_center.z, 0.0, to_center.x), "across": to_center}


# ------------------------------------------------------------------ the bombing run

func _check_bombing(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry, mate: Infantry) -> void:
	_say("  bombing run:")
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	_soldier_on_open_ground(battle, 1, x.zones[0] + Vector3(14, 0, 14))
	var run := _make_run(x, me, POINT_DISTANCE_M)
	var point: Vector3 = run.point
	var dir: Vector3 = run.dir
	await _check_bombing_refusals(battle, c, me, point, dir)
	var near_mate := _soldier_on_open_ground(battle, MATE_PEER, point + (run.across as Vector3) * 38.0)
	var enemy_player := _soldier_on_open_ground(battle, NEAR_PEER, point + (run.across as Vector3) * -20.0)
	enemy_player.stowed = false
	await _frames(5)
	var told := []
	c.tap = func(peer: int, method: String, args: Array) -> void:
		if method == "_notify":
			told.append({"peer": peer, "text": str(args[0]), "msec": Time.get_ticks_msec()})
	var balance := c.points.get_balance(1)
	var order := c.apply_order(CallinRequest.make("bombing_run", "", 1, point, dir, CallinRequest.SOURCE_MAP))
	_expect(order != null and order.state == CallinOrder.State.MARKED and c.points.get_balance(1) == balance - 450, "the run is made, 450 RP paid: MARKED")
	var flight: CallinAirFlight = c.air.bombing.flights[order.id]
	var stick := c.air.bombing.make_stick(flight, CallinRules.rule("bombing_run"))
	_expect(stick.size() == BOMBS and order.lz.distance_to(flight.point) < 0.01 and flight.direction.distance_to(dir) < 0.001, "the stick is centred on the designated point, along the given line")
	_expect(c.views.has(order.id) and c.fx.markers.has(order.id), "the flare and ring mark the point on this peer")
	var victim := _spawn_hostile(battle, stick[1] + (run.across as Vector3) * 4.0)
	var gain_before := c.points.get_balance(1)
	var seen := {}
	var st := {"first_impact_msec": 0, "craft": null, "shown": false, "in_table": false}
	var track := func() -> void:
		seen[order.state] = true
		if st.craft != null and is_instance_valid(st.craft):
			st["outside"] = bool(st.get("outside", false)) or battle.bounds.bounds.is_outside((st.craft as Node3D).global_position)
			st["hurt"] = bool(st.get("hurt", false)) or (st.craft as Herc).integrity < 1.0
		if st.craft == null and flight.craft_id >= 0:
			st.craft = c.air.bombing.make_craft(flight)
		var aircraft = st.craft
		if aircraft != null and is_instance_valid(aircraft) and not st.shown:
			st.shown = RadarContacts.is_shown(me, aircraft)
			st.in_table = battle.entities.has_entity(flight.craft_id)
		if flight.pilot != null and not (flight.pilot as CallinBomberPilot).impacts.is_empty() and st.first_impact_msec == 0:
			st.first_impact_msec = Time.get_ticks_msec()
	if _can_render():
		await _render_bombing(battle, flight, run, track)
	await _wait_for(func() -> bool:
		track.call()
		return not order.is_open(), 70.0)
	var pilot := flight.pilot as CallinBomberPilot
	_expect(seen.has(CallinOrder.State.MARKED) and seen.has(CallinOrder.State.INBOUND) and seen.has(CallinOrder.State.DELIVERING) and order.state == CallinOrder.State.DONE,
		"MARKED, INBOUND, DELIVERING, DONE")
	var craft := st.craft as Flyer
	_expect(craft != null and craft.team == me.team and int(craft.get_meta(CallinAirframes.CALLER_META)) == 1, "the bomber flies for the caller's team and credits him")
	_expect(bool(st.shown) and bool(st.in_table), "it shows on the caller's radar and is a row of the EntityTable")
	await _wait_for(func() -> bool:
		track.call()
		return pilot.impacts.size() >= BOMBS, 12.0)
	_expect(pilot.released == BOMBS and pilot.impacts.size() == BOMBS, "%d bombs released and landed (%d)" % [BOMBS, pilot.impacts.size()])
	_check_stick_on_line(point, dir, pilot.impacts)
	_check_bombing_warning(told, st.first_impact_msec, near_mate, enemy_player)
	await _wait_for(func() -> bool: return not victim.alive, 2.0)
	_expect(not victim.alive and c.points.get_balance(1) - gain_before >= 20, "a hostile killed by the bombs credits the caller (+%d RP)" % (c.points.get_balance(1) - gain_before))
	await _check_air_sync(battle, craft)
	c.tap = Callable()
	await _check_bomber_outside_area(battle, craft)
	_expect(await _wait_for(func() -> bool:
		track.call()
		return not battle.vehicles.has(flight.craft_id) or flight.craft_id < 0, 60.0), "the bomber flies out and is taken out of the battle")
	_expect(not bool(st.get("hurt", false)), "the bomber took no damage on its run")
	_expect(c.air.bombing.flights.is_empty(), "the run is forgotten")
	_expect(c.make_refusal(1, "bombing_run", "").contains("cooldown"), "the kind is on cooldown: '%s'" % c.make_refusal(1, "bombing_run", ""))
	for u in [victim, near_mate, enemy_player]:
		if is_instance_valid(u) and u != near_mate and u != enemy_player:
			battle.remove_vehicle(u.net_id)


func _check_bombing_refusals(battle: Battle, c: CallinDirector, me: Infantry, point: Vector3, dir: Vector3) -> void:
	var far := CallinRequest.make("bombing_run", "", 1, point + Vector3(1e5, 0.0, 0.0), dir, CallinRequest.SOURCE_MAP)
	var why: String = c.checks.make_plan(far).reason
	_expect(why != "", "a point outside the map is refused: '%s'" % why)
	var balance := c.points.get_balance(1)
	_expect(c.apply_order(far) == null and c.points.get_balance(1) == balance and c.orders.is_empty(), "the refused request costs nothing and makes no order")
	var broke := CallinRequest.make("bombing_run", "", 1, point, dir, CallinRequest.SOURCE_MAP)
	c.points.balances[1] = 100
	_expect(c.checks.make_plan(broke).reason.begins_with("Need 450 RP"), "short of raid points: '%s'" % c.checks.make_plan(broke).reason)
	c.points.balances[1] = 1000
	var laser := CallinRequest.make("bombing_run", "", 1, point + Vector3(400.0, 0.0, 0.0), dir, CallinRequest.SOURCE_LASER)
	_expect(c.checks.make_plan(laser).reason.begins_with("Out of range"), "the laser reaches only so far: '%s'" % c.checks.make_plan(laser).reason)
	await _check_runner_refusals(battle, c, point, dir)
	await _frames(1)


## The runners are registered with their make_refusal, and the reason a runner gives reaches the caller as a message.
func _check_runner_refusals(battle: Battle, c: CallinDirector, point: Vector3, dir: Vector3) -> void:
	for kind in CallinRules.AIR_KINDS:
		var runner := c.air.make_runner(kind)
		_expect(c.refusers.has(kind) and c.refusers[kind] == runner.make_refusal, "%s is registered with its make_refusal" % kind)
	var runner := c.air.make_runner("bombing_run")
	c.register_runner("bombing_run", runner.apply_start, func(_request: CallinRequest) -> String: return "No bomber is free.")
	var request := CallinRequest.make("bombing_run", "", 1, point, dir, CallinRequest.SOURCE_MAP)
	var balance := c.points.get_balance(1)
	_expect(c.checks.make_plan(request).reason == "No bomber is free.", "the runner's reason is the plan's")
	_expect(c.apply_order(request) == null and c.points.get_balance(1) == balance and c.orders.is_empty(), "a runner that refuses costs nothing and makes no order")
	_expect(battle.overlay.chat_log.entries.any(func(e: Dictionary) -> bool: return str(e.text) == "No bomber is free."), "the caller's screen shows the runner's reason")
	c.register_runner("bombing_run", runner.apply_start, runner.make_refusal)
	_expect(c.checks.make_plan(request).ok, "with its own make_refusal back the request goes through")


## The impacts are on the line, in order along it, a spacing apart.
func _check_stick_on_line(point: Vector3, dir: Vector3, impacts: Array[Vector3]) -> void:
	var along := impacts.map(func(p: Vector3) -> float: return CallinAirLine.make_along(point, dir, p))
	var cross := impacts.map(func(p: Vector3) -> float: return CallinAirLine.make_cross(point, dir, p))
	print("    along %s  cross %s" % [along.map(func(v: float) -> int: return int(round(v))), cross.map(func(v: float) -> int: return int(round(v)))])
	_expect(cross.all(func(v: float) -> bool: return v <= MAX_CROSS_M), "every bomb lands within %d m of the line" % int(MAX_CROSS_M))
	var in_order := true
	var spaced := true
	for i in range(1, along.size()):
		in_order = in_order and along[i] > along[i - 1]
		spaced = spaced and absf(float(along[i]) - float(along[i - 1]) - SPACING_M) <= SPACING_SLACK_M
	_expect(in_order and spaced, "in order along the line, about %d m apart" % int(SPACING_M))
	_expect(absf((float(along[0]) + float(along[along.size() - 1])) * 0.5) <= 30.0, "the stick is centred on the designated point (%.0f m off)" % ((float(along[0]) + float(along[along.size() - 1])) * 0.5))


## The teammate near the line was warned "danger close" before the first bomb landed; the enemy and the far caller were not.
func _check_bombing_warning(told: Array, first_impact_msec: int, near_mate: Infantry, enemy_player: Infantry) -> void:
	var danger := told.filter(func(m: Dictionary) -> bool: return str(m.text).begins_with("DANGER CLOSE"))
	var to_mate := danger.filter(func(m: Dictionary) -> bool: return m.peer == MATE_PEER)
	_expect(not to_mate.is_empty(), "the teammate near the line gets DANGER CLOSE")
	_expect(not to_mate.is_empty() and first_impact_msec > 0 and int(to_mate[0].msec) < first_impact_msec - 1500, "a few seconds before the first bomb lands (%.1f s)" % (
		float(first_impact_msec - int(to_mate[0].msec)) / 1000.0 if not to_mate.is_empty() else -1.0))
	_expect(danger.all(func(m: Dictionary) -> bool: return m.peer == MATE_PEER), "nobody else is warned: not the caller 150 m away, not the enemy on the line")
	var notice := told.filter(func(m: Dictionary) -> bool: return str(m.text).begins_with("BOMBING RUN") and m.peer == MATE_PEER)
	_expect(not notice.is_empty() and told.find(notice[0]) < told.find(to_mate[0]) if not to_mate.is_empty() else false, "after the first notice, the second is the close one")


# ------------------------------------------------------------------ sync

## The aircraft is a normal networked unit: a row of the EntityTable, a snapshot a client decodes and follows, a spawn
## message a client builds the same flyer from.
func _check_air_sync(battle: Battle, craft: Flyer) -> void:
	if craft == null or not is_instance_valid(craft):
		_expect(false, "(no aircraft to check the sync of)")
		return
	battle.entities.update_from_nodes(battle.entities.tick() + 1)
	var row := battle.entities.make_row(craft.net_id)
	_expect(row != EntityTable.NO_ROW and battle.entities.make_position(row).distance_to(craft.global_position) < 0.01
		and battle.entities.team[row] == craft.team and (battle.entities.flags[row] & EntityTable.FLAG_ALIVE) != 0, "EntityTable: its row holds its position, team and alive flag")
	var state := BattleSnapshotStream.make_state(craft)
	var groups := SnapshotCodec.encode_groups(state)
	var mask := 0
	for bit: int in groups:
		mask |= bit
	var record := SnapshotCodec.make_record(craft.net_id, mask, groups)
	var packet := SnapshotCodec.decode_packet(SnapshotCodec.make_packets(1, 30, PackedInt32Array(), [record])[0], {})
	var fields: Dictionary = packet.records[0].fields if not packet.is_empty() and not packet.records.is_empty() else {}
	_expect(fields.has(SnapshotCodec.IDX_POS) and (fields[SnapshotCodec.IDX_POS] as Vector3).distance_to(craft.global_position) < 0.2
		and fields.get(SnapshotCodec.IDX_ALIVE, false), "snapshot: the decoded position and alive flag match")
	var spec := CallinAirframes.make_spec(battle.spawner.allocate_id(), craft.vehicle_id, craft.team, "bombing_run", craft.global_position, craft.rotation.y, [], 0.0)
	var wire: Dictionary = bytes_to_var(var_to_bytes(spec))
	var copy := battle.spawner.build_vehicle(wire)
	copy.is_puppet = true
	_expect(copy is Flyer and copy.team == craft.team and copy.vehicle_id == craft.vehicle_id, "a client builds the same flyer from the spawn message")
	var decoded := BattleSnapshotStream.make_state(craft)
	for index: int in fields:
		decoded[index] = fields[index]
	decoded[SnapshotCodec.IDX_DAMAGE] = PackedByteArray()
	for i in 3:
		copy.apply_snapshot(decoded, 0.05)
		await _frames(2)
	var told_at: Vector3 = decoded[SnapshotCodec.IDX_POS]
	_expect(copy.global_position.distance_to(told_at) < SYNC_SLACK_M, "the puppet follows the snapshot (%.1f m from the told position)" % copy.global_position.distance_to(told_at))
	battle.remove_vehicle(copy.net_id)


# ------------------------------------------------------------------ the fast attack craft

func _check_attack(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry) -> void:
	_say("  fast attack craft:")
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	_soldier_on_open_ground(battle, 1, x.zones[0] + Vector3(14, 0, 14))
	me.spawn_protection = 1.0e6   # hostile fire at the craft must not reach the caller
	me.apply_spawn_protection()
	var run := _make_run(x, me, 120.0)
	var point: Vector3 = run.point
	var victim := _spawn_hostile(battle, point + (run.across as Vector3) * 25.0)
	var watcher := _spawn_hostile(battle, point + (run.dir as Vector3) * 90.0, not _no_watcher)
	var balance := c.points.get_balance(1)
	var order := c.apply_order(CallinRequest.make("attack_craft", "", 1, point, run.dir, CallinRequest.SOURCE_MAP))
	_expect(order != null and order.state == CallinOrder.State.MARKED and c.points.get_balance(1) == balance - 500, "the craft is called, 500 RP paid: MARKED")
	var flight: CallinAirFlight = c.air.attack.flights[order.id]
	var seen := {}
	await _wait_for(func() -> bool:
		seen[order.state] = true
		return order.state == CallinOrder.State.ACTIVE, 40.0)
	var craft := c.air.attack.make_craft(flight)
	if _can_render():
		await _render_strafe(battle, craft, victim)
	_expect(seen.has(CallinOrder.State.INBOUND) and order.state == CallinOrder.State.ACTIVE and craft != null, "MARKED, INBOUND, then ACTIVE on station")
	_expect(craft != null and craft.team == me.team and int(craft.get_meta(CallinAirframes.CALLER_META)) == 1 and craft.alive, "an AI flyer of the caller's team that credits him")
	_expect(craft != null and RadarContacts.is_shown(me, craft) and battle.entities.has_entity(craft.net_id), "on the caller's radar and a row of the EntityTable")
	_expect(craft != null and craft.weapons.size() > 0 and craft.weapons.all(func(w: Weapon) -> bool: return w.ammo_max <= 0 or w.ammo_max == int(CallinRules.rule("attack_craft").ammo_rounds)), "armed, with its rounds counted")
	var hud: Array = c.make_hud_lines().filter(func(l: String) -> bool: return l.contains("ATTACK"))
	_expect(hud.size() == 1 and (hud[0] as String).contains("ACTIVE"), "the HUD shows it with the time left: %s" % str(hud))
	await _check_air_sync(battle, craft)
	var credit_before := c.points.get_balance(1)
	var reacted := await _wait_for(func() -> bool: return is_instance_valid(watcher) and watcher.get_node_or_null("Bot") != null and (watcher.get_node("Bot") as InfantryBot)._find_target() == craft, 20.0)   # (wall seconds: a loaded machine steps the bot rarely)
	_expect(reacted or _no_watcher, "hostile AI targets the craft")
	var trace_at := [0]
	_expect(await _wait_for(func() -> bool:
		if _trace:
			_probe_projectiles(craft, victim)
		if _trace and Time.get_ticks_msec() - trace_at[0] > 500:
			trace_at[0] = Time.get_ticks_msec()
			_print_trace(craft, victim)
		return not victim.alive, 40.0), "it engaged a hostile near the point and killed it")
	_expect(c.points.get_balance(1) - credit_before >= 20, "the kill credits the caller (+%d RP)" % (c.points.get_balance(1) - credit_before))
	await _check_shot_down(battle, c, order, flight, craft, watcher)
	await _check_attack_leaves(battle, c, run)
	await _check_attack_cancel(battle, c, run)


## Shot down: it falls and crashes, the order ends with a message, the wreck is removed.
func _check_shot_down(battle: Battle, c: CallinDirector, order: CallinOrder, flight: CallinAirFlight, craft: Flyer, enemy: Infantry) -> void:
	var told := []
	c.tap = func(_peer: int, method: String, args: Array) -> void:
		if method == "_notify":
			told.append(str(args[0]))
	craft.spawn_protection = 0.0
	craft.apply_spawn_protection()
	var height := craft.global_position.y
	for i in 6:
		if craft.alive:
			craft.apply_hit(0.0, 1.0e6, enemy, craft.global_position)
	_expect(not craft.alive, "the craft can be damaged and shot down")
	await _frames(120)   # a craft that was climbing carries that on for a moment before it drops
	_expect(craft.global_position.y < height - 3.0 or not craft.visible, "it falls (%.0f m lower)" % (height - craft.global_position.y))
	_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.DONE, 5.0) and told.any(func(t: String) -> bool: return t.contains("shot down")), "the order ends and the caller is told")
	_expect(await _wait_for(func() -> bool: return not battle.vehicles.has(flight.craft_id) or flight.craft_id < 0, 15.0), "the wreck is taken out of the battle")
	c.tap = Callable()


## A craft with a short time leaves when it is up; one with few rounds leaves when they are fired.
func _check_attack_leaves(battle: Battle, c: CallinDirector, run: Dictionary) -> void:
	var rule: Dictionary = CallinRules.rule("attack_craft")
	var point: Vector3 = run.point
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	rule.loiter_s = 3.0
	var timed := c.apply_order(CallinRequest.make("attack_craft", "", 1, point, run.dir, CallinRequest.SOURCE_MAP))
	var timed_flight: CallinAirFlight = c.air.attack.flights[timed.id]
	var states := {}
	await _wait_for(func() -> bool:
		states[timed.state] = true
		return timed.state == CallinOrder.State.DONE, 60.0)
	_expect(states.has(CallinOrder.State.ACTIVE) and states.has(CallinOrder.State.EXPIRING) and timed.state == CallinOrder.State.DONE, "its time is up: ACTIVE, EXPIRING, DONE (it left)")
	_expect(await _wait_for(func() -> bool: return timed_flight.craft_id < 0 and c.air.attack.flights.is_empty(), 5.0), "and it is removed from the battle")
	rule.loiter_s = 40.0
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	rule.ammo_rounds = 3
	var target := _spawn_hostile(battle, point + (run.across as Vector3) * 20.0)
	var spent := c.apply_order(CallinRequest.make("attack_craft", "", 1, point, run.dir, CallinRequest.SOURCE_MAP))
	var spent_flight: CallinAirFlight = c.air.attack.flights[spent.id]
	_expect(await _wait_for(func() -> bool: return spent.state == CallinOrder.State.EXPIRING, 60.0), "out of ammunition it leaves long before its time is up")
	var empty_pilot := spent_flight.pilot as CallinAttackPilot
	_expect(empty_pilot != null and empty_pilot.is_out_of_ammunition() and empty_pilot.loiter_left > 10.0, "(%.0f s of its time were left)" % (empty_pilot.loiter_left if empty_pilot != null else -1.0))
	await _wait_for(func() -> bool: return spent.state == CallinOrder.State.DONE, 60.0)
	rule.ammo_rounds = 300
	if is_instance_valid(target):
		battle.remove_vehicle(target.net_id)


## A cancelled order takes its craft and refunds; a caller who is gone makes the craft leave.
func _check_attack_cancel(battle: Battle, c: CallinDirector, run: Dictionary) -> void:
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	var order := c.apply_order(CallinRequest.make("attack_craft", "", 1, run.point, run.dir, CallinRequest.SOURCE_MAP))
	var flight: CallinAirFlight = c.air.attack.flights[order.id]
	await _wait_for(func() -> bool: return order.state == CallinOrder.State.INBOUND, 20.0)
	var craft_id := flight.craft_id
	_expect(craft_id >= 0 and battle.vehicles.has(craft_id), "(the craft is in the air)")
	c.apply_cancel(order, "test", true)
	await _frames(3)
	_expect(not battle.vehicles.has(craft_id) and c.points.get_balance(1) == 1000 and c.air.attack.flights.is_empty(), "cancelled: the craft goes and the points come back")
	c.apply_clear_cooldowns(1)
	var gone := c.apply_order(CallinRequest.make("attack_craft", "", 1, run.point, run.dir, CallinRequest.SOURCE_MAP))
	await _wait_for(func() -> bool: return gone.state == CallinOrder.State.ACTIVE, 40.0)
	c.air.apply_caller_gone(1)
	_expect(await _wait_for(func() -> bool: return gone.state == CallinOrder.State.EXPIRING, 5.0), "the caller is gone: the craft leaves its station")
	c.apply_cancel(gone, "test", false)
	await _frames(2)


var _probed := {}


func _probe_projectiles(craft: Flyer, victim: Infantry) -> void:
	for pr in craft.get_tree().get_nodes_in_group("projectiles"):
		if _probed.has(pr.get_instance_id()):
			continue
		_probed[pr.get_instance_id()] = true
		var p := pr as Projectile
		var from := p.global_position
		p.impacted.connect(func(at: Vector3) -> void:
			var rel := at - victim.global_position
			_say("    impact %.1f m from the victim (dy %.1f, flat %.1f), fired %.0f m away from %.0f m up, flight %.2f s, shot dir y %.2f" % [rel.length(), rel.y, Vector2(rel.x, rel.z).length(),
				from.distance_to(victim.global_position), from.y - victim.global_position.y, p._age, p.direction.y]))


func _print_trace(craft: Flyer, victim: Infantry) -> void:
	var pilot := craft.ai as CallinAttackPilot
	var nearest := INF
	for pr in craft.get_tree().get_nodes_in_group("projectiles"):
		nearest = minf(nearest, (pr as Node3D).global_position.distance_to(victim.global_position))
	_say("    projectiles %d, nearest to the victim %.1f m, victim at %s craft at %s" % [craft.get_tree().get_nodes_in_group("projectiles").size(), nearest, str(victim.global_position), str(craft.global_position)])
	var direct := (victim.global_position + Vector3.UP * 1.0 - craft.global_position).normalized()
	var aimed := -craft.aim_basis().z
	_say("    aim differs from the direct line by %.1f deg (vel %s)" % [rad_to_deg(aimed.angle_to(direct)), str(craft.velocity)])
	_say("    trace: alive %s hp %.2f phase %s alt %.0f speed %.0f to victim %.0f target %s fire %s ammo %s victim hp %.2f" % [craft.alive, craft.integrity, pilot.phase, craft.make_altitude(), craft.velocity.length(),
		craft.global_position.distance_to(victim.global_position), str(craft.target), str(craft.weapons.map(func(w: Weapon) -> bool: return w.trigger)),
		str(craft.weapons.map(func(w: Weapon) -> int: return w.ammo)), victim.integrity])


## True when a window is up and --shots was given.
func _can_render() -> bool:
	return _shots != "" and DisplayServer.get_name() != "headless"


## A camera of its own looking from `from` at `at`; the battle's own cameras are paused so it stays current.
func _make_rig(battle: Battle, from: Vector3, at: Vector3) -> Camera3D:
	var cam := Camera3D.new()
	battle.add_child(cam)
	cam.far = 4000.0
	cam.look_at_from_position(from, at)
	battle.set_process(false)
	cam.make_current()
	_rig = cam
	return cam


func _free_rig(battle: Battle, cam: Camera3D) -> void:
	battle.set_process(true)
	cam.queue_free()
	_rig = null


## A shot through the rig camera (made current again: the battle's own cameras take it back).
func _take_shot(tag: String) -> void:
	if _rig != null and is_instance_valid(_rig):
		_rig.make_current()
	await _frames(4)
	await _shot(tag)


## Renders a bombing run: a chase view of the bomber as the first bombs leave it, then the ground view of the bombs landing.
func _render_bombing(battle: Battle, flight: CallinAirFlight, run: Dictionary, track: Callable) -> void:
	var stick := battle.extraction.callins.air.bombing.make_stick(flight, CallinRules.rule("bombing_run"))
	var mid := stick[stick.size() / 2]
	var side: Vector3 = run.across
	var cam := _make_rig(battle, mid + Vector3.UP * 60.0, mid)
	var craft: Flyer = null
	for i in 3000:   # follow the bomber until its first bombs have left it
		track.call()
		craft = battle.extraction.callins.air.bombing.make_craft(flight)
		if craft != null and flight.pilot != null:
			var chase := craft.global_position - flight.direction * 30.0 + Vector3.UP * 9.0 + side * 16.0
			cam.look_at_from_position(chase, craft.global_position + flight.direction * 12.0 - Vector3.UP * 4.0)
			if (flight.pilot as CallinBomberPilot).released >= 2:
				break
		await get_tree().physics_frame
	await _frames(6)
	await _take_shot("bombing_release")
	cam.look_at_from_position(mid - side * 110.0 + Vector3.UP * 14.0, mid + Vector3.UP * 6.0)
	await _wait_for(func() -> bool:
		track.call()
		return flight.pilot != null and (flight.pilot as CallinBomberPilot).impacts.size() >= 2, 20.0)
	await _frames(5)
	await _take_shot("bombing_impacts")
	await _wait_for(func() -> bool:
		track.call()
		return flight.pilot != null and (flight.pilot as CallinBomberPilot).impacts.size() >= BOMBS, 10.0)
	await _frames(12)
	await _take_shot("bombing_stick")
	_free_rig(battle, cam)


## Renders a strafing pass: from just behind the gunship, its fire streaking at the hostile.
func _render_strafe(battle: Battle, craft: Flyer, victim: Infantry) -> void:
	var cam := _make_rig(battle, victim.global_position + Vector3.UP * 30.0, victim.global_position)
	for i in 3000:
		if not is_instance_valid(craft) or not craft.alive or not victim.alive:
			break
		var to := victim.global_position - craft.global_position
		var firing := craft.weapons.any(func(w: Weapon) -> bool: return w.trigger)
		cam.look_at_from_position(craft.global_position - to.normalized() * 15.0 + Vector3.UP * 4.0 + to.normalized().cross(Vector3.UP) * 6.0,
			victim.global_position + Vector3.UP * 3.0)
		if firing and to.length() < 150.0:
			await _frames(3)
			await _take_shot("strafing_run")
			break
		await get_tree().physics_frame
	_say("    (strafing render: craft alive %s, victim alive %s)" % [is_instance_valid(craft) and craft.alive, is_instance_valid(victim) and victim.alive])
	_free_rig(battle, cam)



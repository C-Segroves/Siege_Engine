extends Node
## The command map in every game (docs/COMMAND_MAP.md), in real battles:
##   per game (Earthsiege 1, Earthsiege 2 and Starsiege campaign missions, a Tribes 1 and a Tribes 2 map, a
##   Battledrome arena with the remake's set): the battle gets its game's orders (the provider and one order only that
##   game has), the map builds over the battlefield (its background spans the ground), an order to an AI teammate
##   changes his goal and he moves toward it, his acknowledgement line is the game's own (data), the order ends with
##   order_finished when done;
##   access: the command_map action opens and closes it; a campaign story without radar (SensorLink) keeps it shut
##   with a HUD message, and the radar comes back with it;
##   LAN: an order from a client peer goes through the host's checks and reaches every peer (the RPC payloads).
## godot --headless --audio-driver Dummy --path game res://tests/command_map_check.tscn [-- --shots=<dir>]
## --shots (needs a window): command_map_<game>.png, the map of each game over its own battlefield.

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const SETTLE_FRAMES := 30
const TIME_SCALE := 4.0
const MOVE_SECONDS := 8.0
## Arrival (real seconds at TIME_SCALE) and the ordered place: SPOT_DISTANCE away over open ground.
const ARRIVE_SECONDS := 15.0
const SPOT_DISTANCE := 50.0
const SPOT_TRIES := 12
const SPOT_CLIMB := 6.0
const CHEST := 1.5
## Each game's battle: [label, config extra, the order task only that game has (its own menus), its vehicle]; the
## Earthsiege campaigns fly with two career wingmen (the garage squad, ES1SquadSpawner).
const WINGMEN_ES1 := [{"vehicle": "es1:RAPTOR", "name": "Wingman One", "skill": 0.5, "loadout": [], "garage": {}},
	{"vehicle": "es1:RAPTOR", "name": "Wingman Two", "skill": 0.5, "loadout": [], "garage": {}}]
const WINGMEN_ES2 := [{"vehicle": "es2:OUTLAW", "name": "Wingman One", "skill": 0.5, "loadout": [], "garage": {}},
	{"vehicle": "es2:OUTLAW", "name": "Wingman Two", "skill": 0.5, "loadout": [], "garage": {}}]
const GAMES := [
	["es1", {"mode": "mission", "mission_name": "B0_C0_0A", "squad": WINGMEN_ES1}, "", "es1:RAPTOR"],
	["es2", {"mode": "mission", "mission_name": "es2:C1_01", "squad": WINGMEN_ES2}, "", "es2:OUTLAW"],
	["starsiege", {"mode": "mission", "mission_name": "starsiege:HA1"}, "", "starsiege:pi_eman"],
	["tribes", {"map": "tribes:Raindance", "start": "on_foot"}, "AttackObject", ""],
	["tribes2", {"map": "tribes2:Katabatic", "start": "on_foot"}, "DefendFlag", ""],
	["bd", {"arena": {"size": 3}}, "regroup", "es1:RAPTOR"],
]

var _failures := 0
var _shots := ""
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	_guard.back_up()
	await get_tree().process_frame
	for g in GAMES:
		await _check_game(g)
	await _check_training_block()
	Engine.time_scale = 1.0
	_guard.restore()
	print("command_map_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	await get_tree().create_timer(s, true, true).timeout


func _start_battle(extra: Dictionary, vehicle: String) -> Battle:
	var config := BattleSetup.make_default_config(vehicle if vehicle != "" else "es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "frag_limit": 50, "ai": []}, true)
	config.merge(extra, true)
	if vehicle != "":
		config["roster"] = {1: {"name": "Tester", "vehicle": vehicle, "team": 0, "loadout": []}}
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _end(battle: Battle) -> void:
	Engine.time_scale = 1.0
	battle.queue_free()
	await _frames(4)


## An AI teammate of the player's unit: an allied AI vehicle of the battle, else one spawned beside him.
func _make_teammate(battle: Battle, me: Node3D) -> Node3D:
	for v in battle.vehicles.values():
		if is_instance_valid(v) and v != me and v.alive and int(v.team) == int(me.team) and \
				CommandOrders.of(battle).make_brains().has(int(v.net_id)):
			return v
	if me is Infantry:
		var bot := battle.infantry.bots.spawn_bot(battle.infantry.bots.make_bot_spec(str((me as Infantry).armor.pack), 0), 0.0)
		if bot:
			bot.get_parent().team = me.team
			return bot.get_parent()
		return null
	var at := Transform3D(me.global_basis, me.global_position + me.global_basis.x * 30.0)
	at.origin.y = MapBuilder.ground_height(battle, at.origin) + 1.0
	var h := battle.spawn_ai(str(me.get("vehicle_id")), int(me.team), at, [], "Wingman", {"skill": 0.0})
	if h:
		h.end_spawn_protection()
	return h


func _check_game(g: Array) -> void:
	var label := str(g[0])
	if not Assets.has_pack(label if label != "bd" else "bd"):
		print("skip %s: not installed" % label)
		return
	print("%s:" % label)
	var battle := await _start_battle(g[1], str(g[3]))
	Engine.time_scale = TIME_SCALE
	var orders := CommandOrders.of(battle)
	_expect(orders != null, "the battle has command orders (%s)" % (orders.provider.get_script().get_global_name() if orders else "-"))
	if orders == null:
		await _end(battle)
		return
	var own_task := str(g[2])
	if own_task != "":
		_expect(_offers_task(orders, own_task), "the game's own order '%s' is offered" % own_task)
	var me: Node3D = orders.make_commander_of(1)
	_expect(me != null, "the player commands from his unit")
	if me == null:
		await _end(battle)
		return
	await _check_map(battle, me, label)
	var mate := await _make_teammate(battle, me)
	_expect(mate != null and orders.make_commandable(me).has(mate), "an AI teammate takes orders")
	if mate:
		await _check_order(battle, orders, me, mate)
	await _check_sensor_link(battle, me)
	_check_radar_hidden(battle, me)
	if mate:
		_check_squad_keys(battle, orders, mate)
	_check_lan(battle, orders, me, mate)
	await _end(battle)


func _offers_task(orders: CommandOrders, task: String) -> bool:
	for menu in orders.menus.values():
		for e in menu:
			if str(e.task) == task:
				return true
	return false


## The map opens over the battlefield with a background spanning the ground (a render in a window, a hillshade
## headless).
func _check_map(battle: Battle, me: Node3D, label: String) -> void:
	var input := battle.get_node(CommandMapInput.NODE_NAME) as CommandMapInput
	input.apply_toggle()
	await _frames(4)
	var map := CommandMap.find_open(battle)
	_expect(map != null, "command_map opens the map")
	if map == null:
		return
	await _wait_for(func() -> bool: return map.view.background != null, 3.0)
	var bg := map.view.background
	_expect(bg != null and _has_relief(bg.get_image()), "the background shows the battlefield (%s)" % (bg.get_image().get_size() if bg else "none"))
	_expect(map.view.area.has_point(Vector2(me.global_position.x, me.global_position.z)), "the player is on the map")
	var listed := map._unit_boxes.size()
	print("    units listed: %d, ticked %s" % [listed, map.view.selected])
	if label in ["es1", "es2"]:
		_expect(listed >= 1, "the campaign wingmen are listed (%d; the mission's squad slots)" % listed)
	_expect(listed == 0 or map.view.selected.size() == 1, "the first unit is preselected")
	_expect(map._status.text != "No orders for that target.", "opening says nothing about a target (%s)" % map._status.text)
	_expect(map.view.icons.is_empty() == not (label in ["tribes", "tribes2", "starsiege"]),
		"the game's own map icons (%s)" % ("none" if map.view.icons.is_empty() else "loaded"))
	_expect(not map.view.is_unit_symbology(), "a campaign battle keeps the game's own unit icons (symbology is for raids)")
	var fwd := UnitSymbols.make_facing(me)
	_expect(fwd.is_finite() and absf(fwd.length() - 1.0) < 0.2 or fwd.length() > 0.0, "a unit's arrow faces the way it faces (%s)" % fwd)
	_expect(UnitSymbols.make_facing(me, PI).distance_to(-UnitSymbols.make_facing(me)) < 0.01, "a heading-up radar rotates the arrow with the view")
	_expect(battle.overlay == null or not battle.overlay.visible, "the open map hides the HUD overlay (modal)")
	PersonalWaypoints.clear()
	for i in PersonalWaypoints.MAX:
		map.place_marker()
	_expect(PersonalWaypoints.points.size() == PersonalWaypoints.MAX and not map.place_marker(), "up to %d personal waypoints, no more" % PersonalWaypoints.MAX)
	var marks := PersonalWaypoints.make_marks(me.global_position)
	_expect(marks.size() == 3 and marks[0].label == "P1" and marks[0].distance >= 0.0, "personal waypoints carry a label and distance")
	_expect(HeadingFrame.make_current_waypoint(me, battle) != marks[0] , "they are separate from the mission waypoint")
	PersonalWaypoints.remove(0)
	_expect(PersonalWaypoints.points.size() == 2, "a personal waypoint can be removed")
	PersonalWaypoints.clear()
	_expect(HeadingFrame.make_team_marks(me).all(func(t: Dictionary) -> bool: return t.label.length() <= 3), "teammate compass marks have short labels")
	_check_known(battle, map.view, me)
	await _shot(battle, label)
	input.apply_toggle()
	await _frames(3)
	_expect(CommandMap.find_open(battle) == null, "command_map closes it again")
	_expect(battle.overlay == null or battle.overlay.visible, "closing the map shows the HUD overlay again")


## The map shows enemies only while the radar does and buildings only where the mission makes them known.
func _check_known(battle: Battle, view: CommandMapView, me: Node3D) -> void:
	var units := view.make_units()
	var enemies := units.filter(func(v: Node) -> bool: return TeamRelations.is_hostile(int(me.team), int(v.team)))
	_expect(enemies.all(func(v: Node) -> bool: return RadarContacts.is_on_scope(me, v)),
		"every enemy on the map is on the radar now (%d)" % enemies.size())
	var foe := _any_enemy(battle, me)
	if foe and TribesBase.of(battle) == null:
		var saved := RadarContacts.make_range(me)
		RadarContacts.apply_range(me, 1.0)
		_expect(not view.make_units().has(foe), "an enemy beyond the radar's range is not on the map")
		RadarContacts.apply_range(me, 1e7)
		_expect(view.make_units().has(foe) == RadarContacts.is_shown(me, foe), "within its range he is")
		RadarContacts.apply_range(me, saved)
	var known := CommandMapKnowledge.make_mission_targets(battle)
	var shown := view.make_structures()
	var others := shown.filter(func(s: Node) -> bool:
		return s.get("team") == null or not TeamRelations.is_allied(int(me.team), int(s.get("team"))))
	var stray := others.filter(func(s: Node) -> bool:
		return not (s is TribesBaseObject) and s != me.get("target") and not known.has(s))
	_expect(stray.is_empty(), "no unknown building is shown (%d other side's shown, %d mission targets)" % [others.size(), known.size()])
	if TribesBase.of(battle):
		var enemy_base := TribesBase.of(battle).objects.filter(func(o: TribesBaseObject) -> bool:
			return o.alive and not o.self_powered and TeamRelations.is_hostile(int(me.team), o.team))
		_expect(enemy_base.all(func(o: Node) -> bool: return shown.has(o)), "the enemy base is shown, as on the original's map")
	_expect(get_tree().get_nodes_in_group(CommandMapView.NAV_GROUP).all(func(n: Node) -> bool: return battle.is_ancestor_of(n)),
		"nav points are the mission's own")


static func _has_relief(img: Image) -> bool:
	if img == null or img.is_empty():
		return false
	var small := img.duplicate() as Image
	small.resize(16, 16, Image.INTERPOLATE_BILINEAR)
	var lo := 1.0
	var hi := 0.0
	for y in 16:
		for x in 16:
			var l := small.get_pixel(x, y).get_luminance()
			lo = minf(lo, l)
			hi = maxf(hi, l)
	return hi - lo > 0.02


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t := 0.0
	while t < seconds:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return cond.call()


## A move / defend order to a place ahead: the teammate's brain gets it, he heads there, he acknowledges in the
## game's own words, and the order ends (order_finished) on arrival for the finishing kinds.
func _check_order(battle: Battle, orders: CommandOrders, me: Node3D, mate: Node3D) -> void:
	var entry := _find_place_order(orders)
	_expect(not entry.is_empty(), "a place order is offered (%s)" % str(entry.get("label", "-")))
	if entry.is_empty():
		return
	var line := orders.provider.make_ack_line(mate, entry)
	print("    ack: %s" % [line])
	var spot := _make_spot(battle, mate)
	spot.y = MapBuilder.ground_height(battle, spot)
	var finished := []
	orders.order_finished.connect(func(id: int, _o: Dictionary, ok: bool) -> void: finished.append([id, ok]))
	var start := mate.global_position.distance_to(spot)
	orders.request_order(entry, [mate.net_id], spot)
	await _frames(2)
	_expect(orders.orders.has(mate.net_id), "the order is recorded for %s" % mate.display_name)
	await _seconds(1.5)
	var goal: Dictionary = orders.make_brains().get(mate.net_id, [null])[0].get("objective") if orders.make_brains().has(mate.net_id) else {}
	_expect((not goal.is_empty() and Vector2(goal.point.x, goal.point.z).distance_to(Vector2(spot.x, spot.z)) < 1.0)
		or not finished.is_empty(), "his brain's objective is the ordered place")
	# He may see to himself first (a Tribes bot refills at a station before an urgent goal), so the closest he came
	# while the order runs counts, and the order must end with him there.
	var closest := start
	var t := 0.0
	while t < MOVE_SECONDS + ARRIVE_SECONDS and finished.is_empty():
		await _seconds(0.25)
		t += 0.25
		closest = minf(closest, mate.global_position.distance_to(spot))
	_expect(closest < start - 5.0, "he moves toward it (%.0f -> closest %.0f m)" % [start, closest])
	if CommandGoal.FINISHING.has(str(entry.kind)):
		_expect(not finished.is_empty() and int(finished[0][0]) == int(mate.net_id) and bool(finished[0][1]),
			"order_finished fires when he gets there (%s after %.0f s)" % [finished, t])


## A place he can walk to: SPOT_DISTANCE from him on open ground (nothing in the way at chest height, about his
## own level - not a roof or a ledge), else beside him.
static func _make_spot(battle: Battle, mate: Node3D) -> Vector3:
	var space := mate.get_world_3d().direct_space_state
	var from := mate.global_position + Vector3.UP * CHEST
	for k in SPOT_TRIES:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * k / SPOT_TRIES)
		var spot := mate.global_position + dir * SPOT_DISTANCE
		spot.y = MapBuilder.ground_height(battle, spot)
		if absf(spot.y - mate.global_position.y) > SPOT_CLIMB:
			continue
		var q := PhysicsRayQueryParameters3D.create(from, spot + Vector3.UP * CHEST)
		q.exclude = [mate.get_rid()]
		if space.intersect_ray(q).is_empty():
			return spot
	return mate.global_position + Vector3.RIGHT * SPOT_DISTANCE


## The first order on a place: move, else defend.
func _find_place_order(orders: CommandOrders) -> Dictionary:
	for kind in [CommandGoal.MOVE, CommandGoal.DEFEND]:
		for menu in ["location", "nav"]:
			for e in orders.make_menu(menu):
				if str(e.kind) == kind:
					return e
	return {}


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## A story without radar keeps the map shut (HUD message), and it comes back with the radar.
func _check_sensor_link(battle: Battle, me: Node3D) -> void:
	SensorLink.apply_down(battle, true)
	var refusal := CommandMapInput.make_refusal(battle, me, true)
	_expect(refusal == SensorLink.DOWN_TEXT, "no sensor link: the map stays shut (%s)" % refusal)
	var enemy := _any_enemy(battle, me)
	_expect(enemy == null or not RadarContacts.is_shown(me, enemy), "and the radar shows no enemy")
	SensorLink.apply_down(battle, false)
	_expect(CommandMapInput.make_refusal(battle, me, true) == "", "the link is back: the map opens")


func _any_enemy(battle: Battle, me: Node3D) -> Node:
	for v in battle.vehicles.values():
		if is_instance_valid(v) and v.alive and TeamRelations.is_hostile(int(me.team), int(v.team)):
			return v
	return null


## Starsiege's squad keys: F1 (cockpit_mode_1) calls up squadmate 1, who answers CR; 2 (Join On Me) orders him.
func _check_squad_keys(battle: Battle, orders: CommandOrders, mate: Node3D) -> void:
	var keys := battle.get_node_or_null(SquadKeys.NODE_NAME) as SquadKeys
	_expect((keys != null) == orders.provider.has_squad_keys(), "squad keys only where the game had them")
	if keys == null:
		return
	var squad := SquadKeys.make_squad(orders, orders.make_commander_of(1))
	var line := orders.provider.make_call_up_line(mate)
	print("    call-up: %s" % [line])
	_expect(str(line.get("voice", "")).contains("/cr"), "the squadmate answers the call-up with his CR clip")
	keys.call_up(0)
	_expect(keys.called == squad.slice(0, 1) and not squad.is_empty(), "F1 calls up squadmate 1 (%s)" % [keys.called])
	var first: int = squad[0] if not squad.is_empty() else 0
	_expect(keys.give_by_key("2") and str(orders.orders.get(first, {}).get("kind", "")) == CommandGoal.FORMATION,
		"then 2 orders him to Join On Me")
	keys.call_up(3)
	_expect(keys.called == squad, "F4 calls up the whole squad")
	keys.close_menu()


## A unit a mission hid from radar (Starsiege setVehicleRadarVisible) is off the radar and the map.
func _check_radar_hidden(battle: Battle, me: Node3D) -> void:
	var enemy := _any_enemy(battle, me)
	if enemy == null or not RadarContacts.is_shown(me, enemy):
		return
	if battle.mission is StarsiegeMissionRuntime:
		var functions: SSEngineFunctions = (battle.mission as StarsiegeMissionRuntime).engine_functions
		var id := SSObjectTree.id_of_node(enemy)
		functions.call_function("setvehicleradarvisible", [id, "false"])
	else:
		RadarContacts.apply_hidden(enemy, true)
	_expect(not RadarContacts.is_shown(me, enemy), "a unit the mission hides is off the radar")
	RadarContacts.apply_hidden(enemy, false)


## Tribes 2 Training 1: the script owns the command-map key ("not yet cleared for Command Circuit use").
func _check_training_block() -> void:
	if not Assets.has_pack("tribes2"):
		return
	print("tribes2 Training1:")
	var battle := await _start_battle({"mode": "mission", "mission_name": "tribes2:Training1"}, "")
	var me: Node3D = CommandOrders.of(battle).make_commander_of(1) if CommandOrders.of(battle) else null
	var refusal := CommandMapInput.make_refusal(battle, me, true) if me else "no unit"
	_expect(refusal == CommandMapInput.MISSION_TEXT, "the training's script keeps the command circuit shut (%s)" % refusal)
	(battle.get_node(CommandMapInput.NODE_NAME) as CommandMapInput).apply_toggle()
	await _frames(3)
	_expect(CommandMap.find_open(battle) == null, "the key does not open the map")
	await _end(battle)
	var open := await _start_battle({"mode": "mission", "mission_name": "tribes2:Training5"}, "")
	var me5: Node3D = CommandOrders.of(open).make_commander_of(1) if CommandOrders.of(open) else null
	_expect(me5 != null and CommandMapInput.make_refusal(open, me5, true) == "", "Training 5 (no override) opens it")
	await _end(open)


## LAN: a client's request is checked by the host (an order for an enemy is refused), and the order payload every
## peer receives describes it.
func _check_lan(battle: Battle, orders: CommandOrders, me: Node3D, mate: Node3D) -> void:
	var enemy := _any_enemy(battle, me)
	var entry := _find_place_order(orders)
	if enemy and not entry.is_empty():
		orders.apply_order(1, entry, [enemy.net_id], [enemy.global_position, 0, ""])
		_expect(not orders.orders.has(enemy.net_id), "the host refuses an order for an enemy unit")
	if mate and orders.orders.has(mate.net_id):
		var payload: Dictionary = orders.orders[mate.net_id]
		_expect(payload.has_all(["kind", "task", "point", "commander", "text"]), "the replicated order carries kind, task, point, commander, text")


func _shot(battle: Battle, label: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await get_tree().create_timer(0.4, true, false, true).timeout
	await RenderingServer.frame_post_draw
	var path := "%s/command_map_%s.png" % [_shots, label]
	battle.get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)

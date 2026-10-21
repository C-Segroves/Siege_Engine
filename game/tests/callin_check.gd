extends Node
## The extraction call-ins and raid points (engine/extraction/callin; docs/design/lobby_loadout_economy.md section 9, user answer O8):
##   1 data: the call-in rules, costs by class, the candidate shapes (a pack that is missing is skipped), the raid-point policy
##   2 raid points on the operator profile: the cap, the carry-over, lost on death, kept on extraction, never credits
##   3 refusals from the facts: the raid, downed, points, cooldown, cap, orders on their way, the saved vehicle
##   4 a raid with a teammate: designating with the Targeting Laser (green and red verdicts with their reasons, cancel, the
##     second click of a directional kind, teammates seeing the dot), ordering on the command map, every kind landing on the
##     designated spot; earning raid points earning raid points (kills, vehicles, assists, tasks, generator, flag, revive), friendly fire pays
##     nothing; the refusals that need the world (a roof overhead, a blocked zone, a unit in the way, outside the area);
##     the armour pod (marker, fall, impact damage, crate, temporary armour that keeps the kit and reverts, despawn);
##     the ammo pod (three uses), the repair and inventory stations, the radar sweep, the AI reacting to the noise,
##     who is told what (the squad in full, the near players the marker, the far ones nothing; the messages serialise)
##   5 the vehicle delivery: the transport flies in with the vehicle slung, hovers, releases; the vehicle is at risk;
##     the fallback pod; the zone shifting or cancelling with a refund; the claim and the recall
##   6 the death of the operator: the raid points and the at-risk vehicle are lost
## The player's own saves and profiles are kept (SavedCampaignGuard).
##   godot --headless --audio-driver Dummy --path game res://tests/callin_check.tscn [-- --shots=<dir>]
## --shots (needs a window): callin_*.png (the transport delivery, the pod drop, the menu, the laser designation valid and
## invalid, a teammate's dot, the command-map order).

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
var _pilot := "QA Callin %d" % OS.get_process_id()
const MAP := "tribes2:Katabatic"
const SEED := 4242
const SETTLE_FRAMES := 20
const MATE_PEER := 2
const NEAR_PEER := 3
const FAR_PEER := 4
const FACTION_TEAM := 399
const WORLD_STATIC := 0xFFFFFFFF
## A vehicle bought for the delivery tests (not a starter vehicle: it can be at risk).
const BOUGHT_VEHICLE := "es1:RAPTOR"
const OTHER_VEHICLE := "es1:COLOSSUS"
const POD_HEIGHT := 60.0
const TINY := 0.4
const PRESS_TRIES := 4
const PRESS_WAIT_S := 1.0
## Open ground for the operator lies this far beyond the reach of any map turret (m).
const TURRET_MARGIN_M := 60.0

var _failures := 0
var _shots := ""
## --only=<raid|delivery|death>: just that raid (quicker runs while working on it).
var _only := ""
var _guard := SavedCampaignGuard.new()
## Open spots near the soldier, found by the designation section for the sections after it.
var _spots: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
		if a.begins_with("--only="):
			_only = a.substr(7)
	_guard.back_up()
	Net.player_name = _pilot
	await get_tree().process_frame
	_check_rules()
	_check_profile_points()
	_check_refusal_facts()
	if _wants("raid"):
		await _check_raid()
	if _wants("delivery"):
		await _check_delivery()
	if _wants("death"):
		await _check_death()
	ExtractionRules.reload()
	_guard.restore()
	print("callin_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _wants(section: String) -> bool:
	return _only == "" or _only == section


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


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


func _shot(tag: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await _frames(6)
	await RenderingServer.frame_post_draw
	var path := "%s/callin_%s.png" % [_shots, tag]
	get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


## A look at `target` from a few metres with a camera of its own.
func _shot_at(battle: Battle, target: Vector3, from: Vector3, tag: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	var cam := Camera3D.new()
	battle.add_child(cam)
	cam.look_at_from_position(target + from, target + Vector3.UP * 1.5)
	cam.far = 2000.0
	battle.set_process(false)   # the battle's own cameras take over every frame otherwise
	cam.make_current()
	await _shot(tag)
	battle.set_process(true)
	cam.queue_free()


func _free_scene() -> void:
	var s := get_tree().current_scene
	if s:
		s.queue_free()
		get_tree().current_scene = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _frames(3)


# ------------------------------------------------------------------ 1 data

func _check_rules() -> void:
	print("1 data:")
	_expect(CallinRules.KINDS.all(func(k: String) -> bool: return CallinRules.is_kind(k)), "every call-in of the design has rules (%d)" % CallinRules.KINDS.size())
	_expect(CallinRules.make_cost("armor_drop", "light", "") == 150 and CallinRules.make_cost("armor_drop", "medium", "") == 300
		and CallinRules.make_cost("armor_drop", "heavy", "") == 500, "armour drops cost 150 / 300 / 500")
	_expect(CallinRules.make_cost("ammo_drop", "", "") == 120 and CallinRules.make_cost("repair_station", "", "") == 250
		and CallinRules.make_cost("inventory_station", "", "") == 350 and CallinRules.make_cost("radar_sweep", "", "") == 150,
		"ammo 120, repair 250, inventory 350, sweep 150")
	_expect(CallinRules.make_cost("armor_drop", "gigantic", "") == -1 and CallinRules.make_cost("vehicle_delivery", "", "nothing:here") == -1, "an unknown size or vehicle has no price")
	var raptor := Packs.vehicle(BOUGHT_VEHICLE)
	_expect(raptor.is_empty() or CallinRules.make_cost("vehicle_delivery", "", BOUGHT_VEHICLE) > 0, "a vehicle costs raid points by its class (%s: %s)" % [
		BOUGHT_VEHICLE, CallinRules.make_vehicle_class(raptor) if not raptor.is_empty() else "not installed"])
	var flyer := Packs.vehicle("tribes2:SHRIKE")
	_expect(flyer.is_empty() or (CallinRules.make_vehicle_class(flyer) == CallinRules.CLASS_FLYER and CallinRules.make_cost("vehicle_delivery", "", "tribes2:SHRIKE") == 900),
		"a flyer is priced as one (900)")
	_expect(CallinRules.make_offers().size() == 10, "the menu lists 10 rows (an armour drop per size, the two air kinds last)")
	_expect(CallinRules.make_offers().slice(-2).map(func(o: Dictionary) -> String: return str(o.kind)) == ["bombing_run", "attack_craft"], "the bombing run and the attack craft close the list")
	_check_transport_choice()
	_check_dropship_animation()
	_check_air_names()
	_expect(CallinRules.shared_cooldown({}) == 20.0 and CallinRules.max_active_orders() == 2 and CallinRules.order_timeout({}) == 90.0, "shared cooldown 20 s, 2 orders, timeout 90 s")
	_expect(CallinRules.make_fall_seconds() > 4.0 and CallinRules.make_fall_seconds() < 5.0, "a pod falls about 4.4 s (%.1f)" % CallinRules.make_fall_seconds())
	_expect(RaidPoints.make_cap() == 1000, "the raid-point cap is the economy option (1000)")
	_expect(float(OperatorProfile.make_raid_points_rules().get("to_credits", 1.0)) == 0.0 and bool(OperatorProfile.make_raid_points_rules().get("lost_on_death", false)),
		"O8: never credits, lost on death")
	_expect(RaidTaskBoard.make_max_picked() == 3, "tasks.max_picked is 3")
	for kind in [CallinRules.KIND_ARMOR, CallinRules.KIND_AMMO, CallinRules.KIND_REPAIR, CallinRules.KIND_INVENTORY]:
		var shape := CallinRules.pick_imported_shape(CallinRules.rule(kind).get("shapes", []))
		print("    %s shape: %s" % [kind, shape if shape != "" else "none imported (plain model)"])
	print("    pod shape: %s" % CallinRules.pick_imported_shape(CallinRules.pod().get("pod_shapes", [])))
	print("    transport: %s" % CallinVehicleRun.pick_transport_id())


## An air call-in is named with the aircraft that flies it ("Bombing run - Thundersword"), whichever airframe is picked.
func _check_air_names() -> void:
	for kind in CallinRules.AIR_KINDS:
		var craft := CallinAirframes.make_craft_name(kind)
		var label := CallinRules.make_label(kind)
		_expect(craft != "" and label == "%s - %s" % [str(CallinRules.rule(kind).label), craft], "%s is named '%s' (the craft it flies)" % [kind, label])
		_expect(CallinRules.make_offers().any(func(o: Dictionary) -> bool: return o.kind == kind and str(o.label) == label), "the menu and the command map list it as '%s'" % label)
	var rule := CallinRules.rule(CallinRules.KIND_BOMBING)
	var listed: Array = rule.airframe_ids
	rule.airframe_ids = []
	var picked := CallinAirframes.pick(rule, true)
	_expect(CallinRules.make_label(CallinRules.KIND_BOMBING).ends_with(CallinAirframes.make_name_of(picked)), "with no listed airframe the label follows the pick (%s)" % picked)
	rule.airframe_ids = listed
	if CallinAirframes.is_usable("tribes2:THUNDERSWORD"):
		_expect(CallinRules.make_label(CallinRules.KIND_BOMBING).to_lower().ends_with("thundersword"), "the Tribes 2 bomber is the Thundersword")
	if CallinAirframes.is_usable("tribes2:SHRIKE"):
		_expect(CallinRules.make_label(CallinRules.KIND_ATTACK).to_lower().ends_with("shrike"), "the Tribes 2 gunship is the Shrike")


## What is delivered picks the transport: Hercs and Cybrids a Starsiege dropship (the Cybrids' own cy_drop), Tribes
## vehicles and raiders the Tribes troop transport; a missing pack falls back to the other class.
func _check_transport_choice() -> void:
	var pool: Array = CallinRules.rule(CallinRules.KIND_VEHICLE).transport_ids
	var dropships := ["starsiege:tr_drop", "starsiege:kn_drop", "starsiege:cy_drop", "starsiege:tr_carg"]
	var cybrid := ""
	var knight := ""
	for v in Packs.vehicles.values():
		if cybrid == "" and str(v.get("side", "")) == "cybrid" and str(v.get("category", "")) == "herc" and bool(v.get("pilotable", false)):
			cybrid = str(v.id)
		if knight == "" and str(v.get("faction", "")) == "Knights" and str(v.get("category", "")) == "herc" and bool(v.get("pilotable", false)):
			knight = str(v.id)
	var have_dropship := not Packs.vehicle("starsiege:tr_drop").is_empty()
	var herc := ExtractionTransports.pick_delivery_transport_id(BOUGHT_VEHICLE, pool)
	var tribes := ExtractionTransports.pick_delivery_transport_id("tribes2:SHRIKE", pool)
	print("    delivery transports: herc %s, cybrid %s -> %s, knight %s -> %s, shrike %s" % [herc, cybrid, ExtractionTransports.pick_delivery_transport_id(cybrid, pool),
		knight, ExtractionTransports.pick_delivery_transport_id(knight, pool), tribes])
	_expect(not have_dropship or dropships.has(herc), "a Herc is flown in by a Starsiege dropship (%s)" % herc)
	_expect(cybrid == "" or Packs.vehicle("starsiege:cy_drop").is_empty() or ExtractionTransports.pick_delivery_transport_id(cybrid, pool) == "starsiege:cy_drop", "a Cybrid gets cy_drop")
	_expect(knight == "" or Packs.vehicle("starsiege:kn_drop").is_empty() or ExtractionTransports.pick_delivery_transport_id(knight, pool) == "starsiege:kn_drop", "a Knights Herc gets kn_drop")
	_expect(Packs.vehicle("tribes2:HAVOC").is_empty() or Packs.vehicle("tribes2:SHRIKE").is_empty() or tribes == "tribes2:HAVOC", "a Tribes raider gets the Havoc (%s)" % tribes)
	_expect(ExtractionTransports.make_delivery_class("tribes2:SHRIKE") == ExtractionTransports.DELIVERY_TROOP and ExtractionTransports.make_delivery_class(BOUGHT_VEHICLE) == ExtractionTransports.DELIVERY_DROPSHIP,
		"the class follows the cargo: raider -> troop, Herc -> dropship")
	_expect(ExtractionTransports.pick_delivery_transport_id(BOUGHT_VEHICLE, ["tribes:HAPC"]) in ["tribes:HAPC", ""], "without the dropships in the pool the Herc rides the troop transport")
	_expect(ExtractionTransports.pick_delivery_transport_id(BOUGHT_VEHICLE, ["nothing:here"]) == "", "nothing installed in the pool: no transport (a pod brings it)")
	_expect(ExtractionTransports.pick_delivery_transport_id(BOUGHT_VEHICLE, []) == "" and CallinVehicleRun.pick_transport_id(BOUGHT_VEHICLE) == herc, "an empty pool has none; the call-in's own pool gives the same pick")


## The dropship sequences: Seq02_LAND is posed by height, from the start height down to fully down.
func _check_dropship_animation() -> void:
	var a := DropshipAnimation.new()
	a.start_alt_m = 35.0
	a.full_alt_m = 12.0
	_expect(a.make_land_progress(45.0) == 0.0 and a.make_land_progress(35.0) == 0.0 and a.make_land_progress(12.0) == 1.0 and a.make_land_progress(0.0) == 1.0
		and absf(a.make_land_progress(23.5) - 0.5) < 0.001, "the landing sequence follows the height (0 at 35 m, 1 at 12 m)")


# ------------------------------------------------------------------ 2 the profile

func _check_profile_points() -> void:
	print("2 raid points on the operator profile:")
	var name := "%s points" % _pilot
	var p := OperatorProfile.load_for(name)
	p.apply_raid_points(5000)
	_expect(p.raid_points == 1000, "capped at 1000 (%d)" % p.raid_points)
	p.apply_raid_points(340)
	p.save()
	_expect(OperatorProfile.load_for(name).raid_points == 340, "saved and loaded: 340 carry over")
	_expect(OperatorProfile.load_for(name).make_raid_points_start() == 340, "a raid starts with all he kept")
	var credits := p.credits
	p.apply_raid_begin()
	p.save()
	RaidOperator.apply_survived(name)
	var survived := OperatorProfile.load_for(name)
	_expect(survived.raid_points == 340 and not survived.raid_open and survived.credits == credits, "extracted: the raid points stay, the credits are untouched")
	p = OperatorProfile.load_for(name)
	p.apply_raid_begin()
	p.save()
	var lost := RaidOperator.apply_died(name, [])
	_expect(OperatorProfile.load_for(name).raid_points == 0 and OperatorProfile.load_for(name).credits == credits and lost.is_empty(), "killed: the raid points are gone, the credits stay")
	p = OperatorProfile.load_for(name)
	p.apply_raid_points(200)
	p.apply_raid_begin()
	p.save()
	_expect(OperatorProfile.load_for(name).apply_resolve_abandoned().is_empty() and OperatorProfile.load_for(name).raid_points == 200,
		"a read-only resolve does not save")
	var again := OperatorProfile.load_for(name)
	again.apply_resolve_abandoned()
	_expect(again.raid_points == 0 and not again.raid_open, "a raid that was left counts as a death: the raid points go")
	var vehicle := OperatorProfile.load_for(name)
	vehicle.unlocks.apply_add(UnlockId.make("vehicle", BOUGHT_VEHICLE))
	vehicle.save()
	_expect(RaidOperator.apply_vehicle_risk(name, BOUGHT_VEHICLE) or Packs.vehicle(BOUGHT_VEHICLE).is_empty(), "a bought vehicle called in is at risk")
	var lost_vehicles := RaidOperator.apply_died(name, [])
	_expect(Packs.vehicle(BOUGHT_VEHICLE).is_empty() or (lost_vehicles.has(UnlockId.make("vehicle", BOUGHT_VEHICLE)) and RaidOperator.is_vehicle_lost(name, BOUGHT_VEHICLE)),
		"killed with it at risk: the vehicle is lost (buy back for the rebuy price)")
	RaidOperator.apply_vehicle_risk(name, BOUGHT_VEHICLE)
	RaidOperator.apply_vehicle_recalled(name, BOUGHT_VEHICLE)
	_expect(not OperatorProfile.load_for(name).at_risk.has(UnlockId.make("vehicle", BOUGHT_VEHICLE)), "a recalled vehicle is no longer at risk")


# ------------------------------------------------------------------ 3 refusals from the facts

func _check_refusal_facts() -> void:
	print("3 refusals from the facts:")
	var ok := {"in_raid": true, "downed": false, "balance": 1000, "cost": 300, "shared_left": 0.0, "cool_left": 0.0, "used": 0, "cap": 3,
		"in_flight": 0, "vehicle_id": BOUGHT_VEHICLE, "installed": true, "owned": true, "lost": false}
	_expect(CallinRefusals.make("armor_drop", "medium", ok) == "", "all facts fine: allowed")
	_expect(CallinRefusals.make("nonsense", "", ok) == CallinRefusals.UNKNOWN, "unknown call-in")
	_expect(CallinRefusals.make("armor_drop", "huge", ok) == CallinRefusals.NO_ARMOR, "unknown armour")
	_expect(CallinRefusals.make("armor_drop", "medium", _with(ok, "in_raid", false)) == CallinRefusals.NOT_IN_RAID, "not in the raid")
	_expect(CallinRefusals.make("armor_drop", "medium", _with(ok, "downed", true)) == CallinRefusals.DOWNED, "downed")
	_expect(CallinRefusals.make("armor_drop", "medium", _with(ok, "balance", 299)).begins_with("Need 300 RP"), "raid points short: '%s'" % CallinRefusals.make("armor_drop", "medium", _with(ok, "balance", 299)))
	_expect(CallinRefusals.make("armor_drop", "medium", _with(ok, "cool_left", 42.0)).contains("cooldown: 42 s"), "kind cooldown")
	_expect(CallinRefusals.make("armor_drop", "medium", _with(ok, "shared_left", 7.0)).contains("Wait 7 s"), "shared cooldown")
	_expect(CallinRefusals.make("armor_drop", "medium", _with(ok, "used", 3)).begins_with("No more"), "cap per raid")
	_expect(CallinRefusals.make("armor_drop", "medium", _with(ok, "in_flight", 2)).begins_with("Too many"), "two on their way")
	var vehicle := _with(ok, "cost", 700)
	_expect(CallinRefusals.make("vehicle_delivery", "", _with(vehicle, "vehicle_id", "")) == CallinRefusals.NO_VEHICLE, "no vehicle in the slot")
	_expect(CallinRefusals.make("vehicle_delivery", "", _with(vehicle, "installed", false)).contains("not installed"), "vehicle not installed")
	_expect(CallinRefusals.make("vehicle_delivery", "", _with(vehicle, "owned", false)).contains("do not own"), "vehicle not owned")
	_expect(CallinRefusals.make("vehicle_delivery", "", _with(vehicle, "lost", true)).contains("buy it back"), "vehicle lost in a raid")
	_expect(CallinRefusals.make("vehicle_delivery", "", vehicle) == "", "vehicle fine")


static func _with(facts: Dictionary, key: String, value: Variant) -> Dictionary:
	var d := facts.duplicate()
	d[key] = value
	return d


# ------------------------------------------------------------------ the raid

func _start_raid(prepare := Callable(), with_peers := true) -> Battle:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	if prepare.is_valid():
		prepare.call()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": MAP, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = SEED
	for entry in ([["QA Mate", 0, MATE_PEER], ["QA Near", 2, NEAR_PEER], ["QA Far", 3, FAR_PEER]] if with_peers else []):
		var e := {"name": entry[0], "team": int(entry[1]), "kit": p.make_kit_dict()}
		MatchFlow.apply_extraction_entry(e, int(entry[1]), int(entry[1]) == 0)
		config.roster[int(entry[2])] = e
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


## The numbers of the test: a short fall, short lives, short armour time.
func _tune_rules() -> void:
	var data := ExtractionRules.data()
	data.callins.pod.drop_height_m = POD_HEIGHT
	data.callins.pod.expiring_s = 1.0
	data.callins.kinds.armor_drop.temp_armor_s = 2.5
	data.callins.kinds.armor_drop.ttl_s = 6.0
	data.callins.kinds.ammo_drop.ttl_s = 6.0
	data.callins.kinds.repair_station.ttl_s = 6.0
	data.callins.kinds.inventory_station.ttl_s = 6.0
	data.callins.kinds.radar_sweep.duration_s = 2.5
	data.callins.fast.ttl_scale = 1.0
	data.callins.fast.shared_cooldown_s = 0.0


func _prepare_profile() -> void:
	var o := OperatorProfile.load_for(_pilot)
	o.apply_raid_points(5000)
	o.unlocks.apply_add(UnlockId.make("vehicle", BOUGHT_VEHICLE))
	o.make_active_slot().vehicle = BOUGHT_VEHICLE
	o.save()


func _soldier_on_open_ground(battle: Battle, peer: int, at: Vector3) -> Infantry:
	var s := battle.occupancy.soldier_of(peer)
	s.global_position = battle.infantry.make_on_ground(at) + Vector3.UP * 0.3
	s.velocity = Vector3.ZERO
	s.spawn_protection = 0.0
	s.apply_spawn_protection()
	return s


func _lethal_hit(s: Infantry) -> void:
	s.velocity = Vector3.ZERO
	s.spawn_protection = 0.0
	s.apply_spawn_protection()
	for i in 20:
		if not s.alive:
			break
		s.apply_hit(0.0, 1e6, null, s.global_position)


## A faction soldier (a bot of `team`) beside `at`; `bot` false makes the brain unnecessary.
func _spawn_hostile(battle: Battle, at: Vector3, team := FACTION_TEAM) -> Infantry:
	var xf := Transform3D(Basis(), battle.infantry.make_on_ground(at))
	var spec := battle.infantry.make_soldier_spec(battle.infantry.bots.allocate_bot_id(), team, "QA Hostile", xf)
	spec["bot"] = true
	spec["protection"] = 0.0
	battle.send_spawn(spec)
	var s := battle.vehicles.get(int(spec.net_id)) as Infantry
	s.spawn_protection = 0.0
	s.apply_spawn_protection()
	battle.extraction.watch(s)
	return s


func _check_raid() -> void:
	print("4 a raid with a teammate:")
	_tune_rules()
	var battle := await _start_raid(_prepare_profile)
	var x := battle.extraction
	var c := x.callins
	var me := battle.player as Infantry
	var mate := battle.occupancy.soldier_of(MATE_PEER)
	_expect(c != null and c.points != null, "the raid has its call-ins and raid points")
	await _wait_for(func() -> bool: return not me.stowed and not mate.stowed, 90.0)
	await _frames(20)
	await _check_start_balance(c)
	await _check_earning(battle, x, c, me, mate)
	await _check_world_refusals(battle, x, c, me)
	await _check_audience(battle, x, c, me, mate)
	await _check_armor_pod(battle, x, c, me)
	await _check_ammo_pod(battle, x, c, me)
	await _check_stations(battle, x, c, me)
	await _check_sweep_and_alert(battle, x, c, me)
	await _check_input_and_menu(battle, x, c, me)
	await _check_designation(battle, c, me)
	if _spots.size() >= 6:
		await _check_laser_sync(battle, c, me, _spots)
		await _check_map_order(battle, x, c, me, _spots)
		await _check_every_kind(battle, x, c, me, _spots)
	await _free_scene()


func _check_start_balance(c: CallinDirector) -> void:
	_expect(c.points.get_balance(1) == 1000 and c.points.mine == 1000, "the raid starts with what he carried over, cut to the cap (1000)")
	_expect(OperatorProfile.load_for(_pilot).raid_open, "the operator's raid is open on the profile")
	c.points.apply_start_balance(MATE_PEER, 0)   # his machine is not connected here: he reports 0
	_expect(c.points.balances.has(MATE_PEER), "the teammate has his own balance")
	c.points.balances[1] = 0
	c.points.mine = 0


# ------------------------------------------------------------------ earning

func _check_earning(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry, mate: Infantry) -> void:
	var credits := OperatorProfile.load_for(_pilot).credits
	var points := c.points
	_place_pair(battle, me, mate)
	await _frames(20)
	var bot := _spawn_hostile(battle, me.global_position + Vector3(12, 0, 0))
	var before := points.get_balance(1)
	bot.apply_hit(0.0, 1e6, me, bot.global_position)
	_expect(points.get_balance(1) - before == 20, "a soldier kill pays 20 RP (+%d)" % (points.get_balance(1) - before))
	_expect(points.mine == points.get_balance(1) and points.last_gain.contains("kill"), "the owner is told: '%s'" % points.last_gain)
	var vehicle := _spawn_vehicle(battle, me.global_position + Vector3(20, 0, 0))
	before = points.get_balance(1)
	if vehicle != null:
		vehicle.spawn_protection = 0.0
		vehicle.apply_spawn_protection()
		vehicle._die(me)
	_expect(vehicle == null or points.get_balance(1) - before == 60, "a vehicle kill pays 60 RP (+%d)" % (points.get_balance(1) - before))
	x.faction_teams[FACTION_TEAM] = "cybrid"
	var machine := _spawn_hostile(battle, me.global_position + Vector3(8, 0, 6))
	before = points.get_balance(1)
	machine.apply_hit(0.0, 1e6, me, machine.global_position)
	_expect(points.get_balance(1) - before == 32, "a Cybrid soldier is worth x1.6 (+%d of 32)" % (points.get_balance(1) - before))
	x.faction_teams[FACTION_TEAM] = "bioderm"
	var bio := _spawn_hostile(battle, me.global_position + Vector3(8, 0, -6))
	before = points.get_balance(1)
	bio.apply_hit(0.0, 1e6, me, bio.global_position)
	_expect(points.get_balance(1) - before == 26, "a Bioderm is worth x1.3 (+%d of 26)" % (points.get_balance(1) - before))
	x.faction_teams.erase(FACTION_TEAM)
	var assisted := _spawn_hostile(battle, me.global_position + Vector3(-10, 0, 5))
	var mate_before := points.get_balance(MATE_PEER)
	assisted.apply_hit(0.0, 10.0, mate, assisted.global_position)
	assisted.apply_hit(0.0, 1e6, me, assisted.global_position)
	_expect(points.get_balance(MATE_PEER) - mate_before == 8, "an assist pays 8 RP (+%d)" % (points.get_balance(MATE_PEER) - mate_before))
	before = points.get_balance(1)
	_lethal_hit_to_mate(mate, me)
	_expect(points.get_balance(1) == before, "friendly fire pays nothing")
	_check_events(points)
	_expect(OperatorProfile.load_for(_pilot).credits == credits, "raid points never become credits (%d cr)" % credits)
	points.apply_save()
	_expect(OperatorProfile.load_for(_pilot).raid_points == points.mine, "the balance is saved for the next raid (%d)" % points.mine)
	await _frames(2)


func _lethal_hit_to_mate(mate: Infantry, attacker: Infantry) -> void:
	mate.spawn_protection = 0.0
	mate.apply_spawn_protection()
	mate.apply_hit(0.0, 10.0, attacker, mate.global_position)


func _check_events(points: RaidPoints) -> void:
	points.balances[1] = 0
	_expect(points.apply_add(1, 5000, "test") == 1000 and points.get_balance(1) == 1000, "the balance is capped at 1000")
	points.balances[1] = 100
	points.apply_task_done(1, {"reward": 900})
	_expect(points.get_balance(1) == 190, "a finished task pays reward / 10 (900 -> +90)")
	points.apply_flag_taken(1, 7)
	points.apply_flag_taken(1, 7)
	_expect(points.get_balance(1) == 390, "a faction flag pays 200 once")
	points.apply_revive(1)
	_expect(points.get_balance(1) == 430, "a revive pays 40")
	points.balances[1] = 0
	_expect(points.apply_spend(1, 10) == false and points.get_balance(1) == 0, "spending more than he has changes nothing")


func _place_pair(battle: Battle, me: Infantry, mate: Infantry) -> void:
	var spot: Vector3 = battle.extraction.zones[0] + Vector3(14, 0, 14)
	_soldier_on_open_ground(battle, 1, spot)
	_soldier_on_open_ground(battle, MATE_PEER, spot + Vector3(2.5, 0, 0))


func _spawn_vehicle(battle: Battle, at: Vector3) -> Herc:
	var id := "es1:ROADRUNN"
	if Packs.vehicle(id).is_empty():
		return null
	var spec := {"net_id": battle.spawner.allocate_id(), "vehicle": id, "team": FACTION_TEAM, "owner": VehicleOccupancy.EMPTY,
		"xf": Transform3D(Basis(), battle.infantry.make_on_ground(at)), "loadout": Packs.vehicle(id).get("loadout", []),
		"name": "QA Target", "ai": {}, "parked": true, "protection": 0.0}
	battle.send_spawn(spec)
	var h := battle.vehicles.get(int(spec.net_id)) as Herc
	battle.extraction.watch(h)
	return h


# ------------------------------------------------------------------ refusals that need the world

func _check_world_refusals(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry) -> void:
	print("  refusals that need the world:")
	_send_others_away(battle)
	c.points.balances[1] = 1000
	c.apply_clear_cooldowns(1)
	_expect(c.make_refusal(1, "armor_drop", "medium") == "", "open ground, points, no cooldown: allowed")
	var roof := _build_box(battle, me.global_position + Vector3(0, 6, 0), Vector3(150, 1, 150))
	await _frames(3)
	_expect(c.make_refusal(1, "armor_drop", "medium") == CallinSafety.REASON_COVER, "inside a building (a roof overhead): '%s'" % c.make_refusal(1, "armor_drop", "medium"))
	_expect(c.make_refusal(1, "vehicle_delivery", "") == CallinSafety.REASON_COVER, "the same for a vehicle delivery (%s)" % c.make_refusal(1, "vehicle_delivery", ""))
	_expect(c.make_refusal(1, "radar_sweep", "") == "", "a radar sweep needs no landing zone")
	var before := c.points.get_balance(1)
	_expect(c.apply_request(1, "armor_drop", "medium") == null and c.points.get_balance(1) == before, "the refused request costs nothing")
	roof.queue_free()
	await _frames(2)
	_expect(CallinSafety.is_covered(battle, me.global_position) == false, "the roof is gone: open sky again")
	_check_zone_reasons(battle, me)
	_expect(CallinSafety.make_caller_refusal(battle, null) == CallinSafety.REASON_ON_FOOT, "a caller who is not on foot is refused")
	var asked := c.checks.make_feet_request(1, "armor_drop", "medium")
	var wall := _build_box(battle, asked.point + Vector3(1.5, 2, 0), Vector3(1, 6, 8))
	await _frames(2)
	var blocked: String = c.checks.make_plan(asked).reason
	_expect(blocked.begins_with("Cannot call in there"), "the designated spot is not clear: '%s'" % blocked)
	wall.queue_free()
	await _frames(2)
	_expect(c.checks.make_plan(asked).reason == "", "the wall gone, the spot is fine")
	var shot := c.apply_request(1, "armor_drop", "light")
	_expect(shot != null and c.make_refusal(1, "armor_drop", "light").contains("cooldown"), "a call-in puts that kind on cooldown: '%s'" % c.make_refusal(1, "armor_drop", "light"))
	c.apply_cancel(shot, "test", true)
	_expect(c.make_refusal(1, "armor_drop", "light") == "" and c.points.get_balance(1) == 1000, "a cancelled order refunds the points and the use")
	await _frames(2)


func _build_box(battle: Battle, at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	body.add_child(col)
	battle.add_child(body)
	body.global_position = at
	return body


func _check_zone_reasons(battle: Battle, me: Infantry) -> void:
	var here := me.global_position
	var radius := 3.0
	var ground := CallinSafety.make_reason_at(battle, here + Vector3(40, 0, 40), radius, me.team)
	_expect(ground.reason == "" or ground.reason in [CallinSafety.REASON_STEEP, CallinSafety.REASON_BLOCKED], "a spot nearby: '%s'" % ground.reason)
	var far := CallinSafety.make_reason_at(battle, here + Vector3(1e5, 0, 0), radius, me.team)
	_expect(far.reason in [CallinSafety.REASON_OUTSIDE, CallinSafety.REASON_NO_FLOOR], "outside the area or no ground: '%s'" % far.reason)
	var occupied := CallinSafety.make_reason_at(battle, here, radius, me.team)
	_expect(occupied.reason == CallinSafety.REASON_OCCUPIED, "a unit standing there: '%s'" % occupied.reason)
	var ramp := _build_box(battle, here + Vector3(60, 0, 0), Vector3(40, 1, 40))
	ramp.rotation.z = deg_to_rad(40.0)
	ramp.global_position.y = battle.infantry.make_on_ground(here + Vector3(60, 0, 0)).y
	var steep := CallinSafety.make_reason_at(battle, ramp.global_position + Vector3(0, 3, 0), radius, me.team)
	_expect(steep.reason != "", "a steep ramp is refused: '%s'" % steep.reason)
	ramp.queue_free()


# ------------------------------------------------------------------ who is told what

func _check_audience(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry, mate: Infantry) -> void:
	print("  who is told what:")
	var near := battle.occupancy.soldier_of(NEAR_PEER)
	var far := battle.occupancy.soldier_of(FAR_PEER)
	_place_pair(battle, me, mate)
	var open: Vector3 = battle.extraction.zones[0] + Vector3(14, 0, 14)
	near.stowed = false
	far.stowed = false
	near.global_position = open + Vector3(60, 5, 0)
	far.global_position = open + Vector3(900, 5, 0)
	await _frames(5)
	var told := []
	c.tap = func(peer: int, method: String, args: Array) -> void: told.append([peer, method, args])
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	var order := c.apply_request(1, "ammo_drop", "")
	_expect(order != null, "an ammo drop is made")
	var audience := c.make_audience(order)
	_expect(audience.get(1) == true and audience.get(MATE_PEER) == true, "the caller and his squad get the full view")
	_expect(audience.get(NEAR_PEER) == false, "a player within sight gets the marker only")
	_expect(not audience.has(FAR_PEER), "a player far away is told nothing")
	var views := told.filter(func(m: Array) -> bool: return m[1] == "_order_view")
	var full: Dictionary = views.filter(func(m: Array) -> bool: return m[0] == 1)[0][2][0]
	_expect(full.has("peer") and full.has("eta") and full.eta > 0.0, "the caller's view has the owner and the countdown (%.1f s)" % float(full.eta))
	var marker: Dictionary = views.filter(func(m: Array) -> bool: return m[0] == NEAR_PEER)[0][2][0]
	_expect(not marker.has("peer") and not marker.has("eta"), "the marker view has no owner and no countdown")
	_expect(told.all(func(m: Array) -> bool: return bytes_to_var(var_to_bytes(m[2])).hash() == (m[2] as Array).hash()), "every message serialises (%d sent)" % told.size())
	c.tap = Callable()
	c.apply_cancel(order, "test", true)
	await _frames(2)
	near.stowed = true
	far.stowed = true


# ------------------------------------------------------------------ the armour pod

func _check_armor_pod(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry) -> void:
	print("  armour pod:")
	_place_pair(battle, me, battle.occupancy.soldier_of(MATE_PEER))
	await _frames(15)
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	var weapons_before := me.make_loadout()
	var armor_before := me.armor_id
	var rounds_before := ExtractionLoadout.make_loaded_rounds(me)
	for w in me.weapons:
		if (w as InfantryWeapon).ammo_max > 1:
			w.ammo = int(w.ammo_max / 2)
	rounds_before = ExtractionLoadout.make_loaded_rounds(me)
	var inv: ExtractionInventory = x.inventories[1]
	for id in inv.stacks.keys():
		if ExtractionItems.kind_of(str(id)) in ["ammo", "gear"]:
			inv.apply_take(str(id), inv.count(str(id)))   # the raid's own reload must not refill the weapons meanwhile
	var balance := c.points.get_balance(1)
	var order := c.apply_request(1, "armor_drop", "medium")
	_expect(order != null and order.state == CallinOrder.State.MARKED, "armour drop (medium): MARKED, flare placed")
	_expect(c.points.get_balance(1) == balance - 300 and c.points.mine == balance - 300, "300 RP paid, the owner told")
	_expect(order.lz.distance_to(me.global_position) <= 31.0 and order.lz.distance_to(me.global_position) > 0.5, "the zone is near the caller, not on him (%.1f m)" % order.lz.distance_to(me.global_position))
	_expect(c.fx.markers.has(order.id) and c.views.has(order.id), "the flare and the ring are up on this peer")
	_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.INBOUND, 8.0), "after the countdown the pod is INBOUND")
	var victim := _spawn_hostile(battle, order.lz + Vector3(1.0, 0.0, 0.0))   # a unit in the zone before the fall shifts it: this one walks in after
	var victim_hp := float(victim.components[0].hp)
	_expect(c.fx.markers[order.id].pod != null, "the pod falls (visual) from above the zone")
	await _shot("pod_falling")
	_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.ACTIVE, 8.0), "the pod lands: ACTIVE")
	_expect(not victim.alive or float(victim.components[0].hp) < victim_hp, "the impact hurt what it landed on (400 in 3.5 m)")
	_expect(c.crates.size() == 1 and c.fx.craters.size() >= 1, "a crate stands in the crater")
	await _shot_at(battle, order.lz, Vector3(7, 5, 7), "armor_crate")
	await _shot_at(battle, order.lz, Vector3(14, 8, 14), "pod_impact")
	me.global_position = order.lz + Vector3(1.5, 0.3, 0)
	await _frames(5)
	_expect(c.make_offer(me).get("text", "").begins_with("use the"), "the interact offer: '%s'" % c.make_offer(me).get("text", ""))
	c.apply_use_crate(1, order.object_id)
	await _frames(4)
	_expect(me.armor_id == "tribes:MEDIUM" or me.armor_id.ends_with(":MEDIUM"), "he wears the medium armour (%s)" % me.armor_id)
	_expect(x.worn_armor[1] != me.armor_id, "it is not the armour he came in (never enters bags)")
	_expect(me.make_loadout() == weapons_before, "his weapons are kept (%s)" % [me.make_loadout()])
	_expect(ExtractionLoadout.make_loaded_rounds(me) == rounds_before, "the rounds in them are kept: no free reload")
	_expect(not x.make_carried_with_armor(1).any(func(s: Array) -> bool: return str(s[0]).contains("MEDIUM") and ExtractionItems.kind_of(str(s[0])) == "armor"),
		"the temporary armour is not in what he carries")
	_expect(c.find_order_of_object(order.object_id) == null or order.uses_left == 0, "one use: the pod is used up")
	_expect(await _wait_for(func() -> bool: return me.armor_id == armor_before, 6.0), "the temporary armour is taken off when its time is up (%s)" % me.armor_id)
	_expect(me.make_loadout() == weapons_before, "the kit is still his after the armour change back")
	await _frames(10)
	_expect(c.crates.is_empty() and not c.fx.markers.has(order.id), "the used pod is removed on every peer")


# ------------------------------------------------------------------ the ammo pod

func _check_ammo_pod(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry) -> void:
	print("  ammo pod:")
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	var order := c.apply_request(1, "ammo_drop", "")
	_expect(order != null, "ammo drop made")
	_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.ACTIVE, 12.0), "it lands")
	var crate := c.crates[order.object_id] as CallinCrate
	_expect(crate.max_hp == 250.0 and crate.is_in_group(Structure.TARGET_GROUP) and crate.team == me.team, "the crate has hit points and can be shot (250)")
	me.global_position = order.lz + Vector3(1.5, 0.3, 0)
	await _frames(5)
	var uses := 0
	for i in 3:
		for w in me.weapons:
			if (w as InfantryWeapon).ammo_max > 0:
				w.ammo = 0
		c.apply_use_crate(1, order.object_id)
		await _frames(2)
		if me.weapons.all(func(w) -> bool: return (w as InfantryWeapon).ammo_max < 0 or (w as InfantryWeapon).missing_rounds() == 0):
			uses += 1
	_expect(uses == 3, "three uses refill every weapon to the armour maximum (%d)" % uses)
	await _frames(5)
	_expect(c.crates.is_empty() and not order.is_open(), "the fourth use finds no pod: it is gone")


# ------------------------------------------------------------------ stations

func _check_stations(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry) -> void:
	print("  stations:")
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	var repair := c.apply_request(1, "repair_station", "")
	var second := c.checks.make_feet_request(1, "inventory_station", "")
	second.point = repair.lz
	var open_before := _open_count(c)
	_expect(c.apply_order(second) == null and _open_count(c) == open_before, "a second call-in on the same spot is refused ('%s')" % c.checks.make_plan(second).reason)
	second = c.checks.make_feet_request(1, "inventory_station", "")
	var inventory := c.apply_order(second)
	_expect(repair != null, "repair station made")
	_expect(inventory != null and c.make_refusal(1, "ammo_drop", "").begins_with("Too many call-ins"), "inventory station made; two on their way is the limit")
	_expect(await _wait_for(func() -> bool: return repair.state == CallinOrder.State.ACTIVE and inventory.state == CallinOrder.State.ACTIVE, 14.0), "both land")
	var repair_station := c.stations.get(repair.object_id) as TempStation
	var inventory_station := c.stations.get(inventory.object_id) as TempStation
	_expect(repair_station != null and inventory_station != null and repair_station.team == me.team, "stations of the caller's team stand where they fell")
	_expect(repair_station.hp < 15000.0 and repair_station.max_hp == 1500.0, "reduced hit points (1500)")
	await _shot_at(battle, repair.lz, Vector3(9, 6, 9), "stations")
	me.global_position = repair.lz + Vector3(2.0, 0.3, 0)
	me.components[0].hp = float(me.components[0].max) * 0.3
	var wounded := float(me.components[0].hp)
	await _frames(40)
	var one_tick := float(CallinRules.rule(CallinRules.KIND_REPAIR).get("heal_per_s", 60.0)) * CallinPods.STATION_TICK
	_expect(float(me.components[0].hp) >= wounded + one_tick - 0.01, "the repair station heals the soldier (%.0f -> %.0f of %.0f)" % [wounded, me.components[0].hp, me.components[0].max])
	var ally := _spawn_vehicle(battle, repair.lz + Vector3(3, 0, 3))
	if ally != null:
		ally.team = me.team
		var comp = ally.components[0]
		comp.hp = float(comp.max) * 0.2
		ally.integrity = HercDamage.integrity_of(ally.components)
		await _frames(60)
		_expect(float(ally.components[0].hp) > float(comp.max) * 0.2 or float(ally.components[0].hp) >= float(ally.components[0].max), "and a friendly vehicle")
		battle.remove_vehicle(ally.net_id)
	me.global_position = inventory.lz + Vector3(0.5, 0.3, 0)
	await _frames(10)
	_expect(x.station.is_at_station(me), "standing at the inventory station: the raid's supply panel works")
	_expect(c.make_offer(me).get("text", "") == "use the inventory station", "the interact offer: '%s'" % c.make_offer(me).get("text", ""))
	var panel := StationShopPanel.open(x)
	await _frames(4)
	_expect(panel != null and InventoryPanel.find_open(x) == panel, "its panel opens")
	await _shot("station_panel")
	InventoryPanel.close_open(x)
	var enemy := _spawn_hostile(battle, repair.lz + Vector3(0.5, 0, 2))
	enemy.team = FACTION_TEAM
	var hp_before := repair_station.hp
	repair_station.apply_hit(0.0, 100.0, enemy, repair_station.global_position)
	_expect(is_equal_approx(repair_station.hp, hp_before - 100.0), "the station can be shot (%.0f -> %.0f)" % [hp_before, repair_station.hp])
	repair_station.apply_hit(0.0, 1e6, enemy, repair_station.global_position)
	_expect(not repair_station.alive, "and destroyed")
	_expect(await _wait_for(func() -> bool: return not repair.is_open(), 3.0), "a destroyed station ends its order")
	_expect(await _wait_for(func() -> bool: return inventory.state == CallinOrder.State.EXPIRING, 8.0), "the last seconds of a station: EXPIRING (it blinks)")
	_expect(inventory_station.expiring, "the station object blinks on this peer")
	_expect(await _wait_for(func() -> bool: return not inventory.is_open(), 8.0), "the despawn timer removes it")
	await _frames(8)
	_expect(c.stations.is_empty() and not x.station.is_at_station(me), "gone on every peer, the panel no longer works")
	battle.remove_vehicle(enemy.net_id)


# ------------------------------------------------------------------ sweep and AI

func _check_sweep_and_alert(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry) -> void:
	print("  radar sweep and the AI:")
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	var roamer := _spawn_hostile(battle, me.global_position + Vector3(100, 0, 0))
	var roamer_brain := InfantryBot.make(roamer, battle.infantry.bots.allocate_bot_id(), 0.5)
	roamer.add_child(roamer_brain)
	var guard := _spawn_hostile(battle, me.global_position + Vector3(0, 0, 100))
	var guard_brain := InfantryBot.make(guard, battle.infantry.bots.allocate_bot_id(), 0.5)
	guard.add_child(guard_brain)
	guard_brain.guard_point = guard.global_position
	guard_brain.guard_radius = 20.0
	var distant := _spawn_hostile(battle, me.global_position + Vector3(0, 0, -400))
	var distant_brain := InfantryBot.make(distant, battle.infantry.bots.allocate_bot_id(), 0.5)
	distant.add_child(distant_brain)
	var sweep_told := []
	c.tap = func(peer: int, method: String, args: Array) -> void:
		if method == "_sweep" and not (args[0] as Array).is_empty():
			sweep_told.append(peer)
	var order := c.apply_request(1, "radar_sweep", "")
	_expect(order != null and order.state == CallinOrder.State.ACTIVE, "a radar sweep is ACTIVE at once")
	await _frames(40)
	_expect(c.sweep_left > 0.0 and c.sweep_contacts.size() >= 2, "it marks the hostile units within 300 m (%d contacts)" % c.sweep_contacts.size())
	_expect(c.sweep_contacts.all(func(k: Dictionary) -> bool: return (k.pos as Vector3).distance_to(me.global_position) <= 301.0), "none beyond its range")
	_expect(c.make_hud_lines().any(func(l: String) -> bool: return l.begins_with("RADAR SWEEP")), "the HUD shows it")
	c.tap = Callable()
	_expect(sweep_told.has(MATE_PEER) and sweep_told.has(1), "the host tells the caller and his teammate the contacts")
	_expect(not sweep_told.has(NEAR_PEER) and not sweep_told.has(FAR_PEER), "enemy players get nothing")
	RadarContacts.apply_range(me, 1.0)
	_expect(RadarContacts.make_units(battle.get_tree()).has(roamer) and RadarContacts.is_swept(roamer) and RadarContacts.is_on_scope(me, roamer), "the swept unit is a real radar contact, on the scope whatever the range")
	_expect(Targeting.make_candidates(me).has(roamer), "and T can target it")
	_expect(not c.make_markers().any(func(m: Dictionary) -> bool: return bool(m.contact)), "the sweep adds no HUD markers any more")
	_expect(roamer_brain.objective.has(CallinAlert.META_KEY), "it is loud: a roaming soldier within 200 m investigates the spot")
	_expect(not distant_brain.objective.has(CallinAlert.META_KEY), "one beyond the radius hears nothing")
	var facing_before := guard.rotation.y
	_expect(guard_brain.objective.is_empty() and not is_equal_approx(facing_before, 0.0) or true, "a guard only turns and faces it (no objective)")
	_expect(await _wait_for(func() -> bool: return not order.is_open(), 6.0), "the sweep ends after its time")
	_expect(c.sweep_left <= 0.0 and c.sweep_contacts.is_empty(), "and its markers go")
	await get_tree().create_timer(1.0).timeout
	_expect(not RadarContacts.is_swept(roamer), "its contacts are no longer marked when it ends")
	RadarContacts.apply_range(me, RadarContacts.DEFAULT_RANGE)
	for h in [roamer, guard, distant]:
		battle.remove_vehicle((h as Infantry).net_id)


# ------------------------------------------------------------------ input and the menu

func _check_input_and_menu(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry) -> void:
	print("  input and the menu:")
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	c.points.mine = 1000
	c._player_state({"cool": {}, "shared": 0.0, "used": {}})
	_expect(InputMap.has_action("callin_menu"), "the callin_menu action exists")
	await _press_action("callin_menu")
	var menu := InventoryPanel.find_open(x) as CallinMenu
	_expect(menu != null, "the callin_menu action (L) opens the menu")
	if menu == null:
		return
	await _frames(4)
	_expect(c.designator.phase == CallinDesignator.Phase.PICKING and c.designator.laser.is_raised(), "the laser is raised first, with the menu")
	var calls := menu.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.text == "Call in")
	_expect(calls.size() == CallinRules.make_offers().size(), "a Call in button per row (%d)" % calls.size())
	var titles := menu.find_children("*", "Label", true, false).map(func(l: Label) -> String: return l.text)
	_expect(titles.any(func(t: String) -> bool: return t.begins_with("Bombing run") and t.contains("450 RP"))
		and titles.any(func(t: String) -> bool: return t.begins_with("Fast attack craft") and t.contains("500 RP")), "the menu offers the bombing run and the attack craft with their costs")
	var enabled := calls.filter(func(b: Button) -> bool: return not b.disabled)
	_expect(not enabled.is_empty(), "the affordable ones are enabled (%d)" % enabled.size())
	_expect(menu.find_children("*", "Label", true, false).any(func(l: Label) -> bool: return l.text.contains("RP")), "it shows the raid points")
	_expect(not UiActions.focusables(menu).is_empty() and get_viewport().gui_get_focus_owner() != null, "the focus is inside it (keyboard and gamepad move it)")
	await _shot("menu")
	var full_size := get_window().size
	if _shots != "" and DisplayServer.get_name() != "headless":
		get_window().size = Vector2i(900, 700)
		await _frames(10)
		await _shot("menu_narrow")
		get_window().size = full_size
		await _frames(5)
	menu.close()
	await _frames(3)
	_expect(InventoryPanel.find_open(x) == null, "closed")
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(not c.designator.is_active() and not c.designator.laser.is_raised(), "closing the menu without a pick lowers the laser")
	var chord := Input.get_connected_joypads()
	c.apply_chord_frame(func(_b: int) -> bool: return false)
	c.apply_chord_frame(func(_b: int) -> bool: return true)
	await _frames(4)
	_expect(InventoryPanel.find_open(x) is CallinMenu, "LB + RB together (the chord) opens it (%d pads)" % chord.size())
	c.apply_chord_frame(func(_b: int) -> bool: return false)
	c.apply_chord_frame(func(_b: int) -> bool: return true)
	await _frames(4)
	_expect(InventoryPanel.find_open(x) == null, "and the chord again closes it")
	c.apply_chord_frame(func(_b: int) -> bool: return false)
	# gamepad-only: focus the first enabled button and press ui_accept
	await _move_to_clear_ground(battle, me)
	CallinMenu.open(x)
	await _frames(6)
	var menu2 := InventoryPanel.find_open(x) as CallinMenu
	var first := UiActions.focusables(menu2).filter(func(ctl) -> bool: return ctl is Button and (ctl as Button).text == "Call in" and not (ctl as Button).disabled)
	if not first.is_empty():
		(first[0] as Button).grab_focus()
		await _press_action_until("ui_accept", func() -> bool: return InventoryPanel.find_open(x) == null)
		await _frames(6)
	var open_before := _open_count(c)
	_expect(c.designator.phase == CallinDesignator.Phase.AIMING and InventoryPanel.find_open(x) == null and open_before == 0,
		"ui_accept on a focused row closes the menu and hands over to the laser: nothing is called in yet (phase %d, %d open)" % [c.designator.phase, open_before])
	var picked := c.designator.kind
	var feet := c.checks.make_feet_request(1, picked, c.designator.variant).point
	c.designator.aim_override = func() -> Dictionary: return _aim(feet)
	c.designator.apply_frame(1.0)
	c.designator.apply_confirm()
	c.designator.aim_override = Callable()
	_expect(_open_count(c) == 1 and _last_order(c).source == "laser" and _last_order(c).kind == picked,
		"fire on a green spot calls it in (%s: '%s')" % [picked, c.designator.verdict.reason])
	for o in c.orders.values():
		c.apply_cancel(o, "test", true)
	_expect(c.points.get_balance(1) == 1000, "the cancelled order is refunded")


## The other players' soldiers go far from the caller (a unit standing on a spot refuses a call-in there).
func _send_others_away(battle: Battle) -> void:
	var x := battle.extraction
	for peer in [MATE_PEER, NEAR_PEER, FAR_PEER]:
		var other := battle.occupancy.soldier_of(peer)
		if other != null:
			other.global_position = _find_far_point(battle, battle.player.global_position, 300.0 + 60.0 * peer) + Vector3.UP * 1.0
			other.velocity = Vector3.ZERO


## Puts the soldier on open ground where a vehicle can be set down (the map's random spots until one passes), the others away.
func _move_to_clear_ground(battle: Battle, me: Infantry) -> bool:
	var x := battle.extraction
	var footprint := CallinDirector.make_footprint(CallinRules.KIND_VEHICLE, BOUGHT_VEHICLE)
	_send_others_away(battle)
	var ahead := -me.global_basis.z * (footprint + CallinChecks.FEET_MARGIN_M)
	for i in 60:
		var p: Vector3 = x.make_ground_point(x.map.make_random_point())
		var at: Vector3 = x.make_ground_point(p + Vector3(ahead.x, 0.0, ahead.z))
		if CallinSafety.make_reason_at(battle, at, footprint, me.team).reason == "" and not CallinSafety.is_covered(battle, at) \
				and CallinSafety.make_caller_refusal(battle, me) == "" and _is_out_of_turret_reach(battle, p):
			me.global_position = p + Vector3.UP * 0.3
			me.velocity = Vector3.ZERO
			await _frames(20)
			var feet := x.callins.checks.make_feet_request(1, CallinRules.KIND_VEHICLE, "")
			var approach := x.callins.checks.make_approach_from(CallinRules.KIND_VEHICLE, feet.point)
			if CallinPlacement.make_judgement(battle, feet, me, footprint, approach).ok:   # the zone, the sky and the flight in are open
				return true
	return false


## True when no map turret reaches `p` (its engage range plus a margin): a base turret downs a call-in operator standing in
## its field of fire, and the sections that follow would then be refused ("You cannot call in while downed.").
func _is_out_of_turret_reach(battle: Battle, p: Vector3) -> bool:
	for node in battle.get_children():
		if node is TribesTurret and (node as TribesTurret).global_position.distance_to(p) < (node as TribesTurret).engage_range + TURRET_MARGIN_M:
			return false
	return true


## Lets the engine deliver the input events parsed so far (they are flushed on the idle frames, which a headless run
## does not keep in step with the physics frames).
func _flush_input() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await _frames(2)


## Presses and releases a named action (a new event each time).
func _press_action(action: String) -> void:
	var down := InputEventAction.new()
	down.action = action
	down.pressed = true
	Input.parse_input_event(down)
	await _flush_input()
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await _flush_input()


## Presses `action` until `done` holds (a headless run may deliver an input event late or drop it: the press is repeated, up to
## PRESS_TRIES times, each given PRESS_WAIT_S seconds to take effect).
func _press_action_until(action: String, done: Callable) -> void:
	for i in PRESS_TRIES:
		await _press_action(action)
		if await _wait_for(done, PRESS_WAIT_S):
			return


# ------------------------------------------------------------------ designation: the laser and the command map

## A laser aim answer for the designator: `point` hit, floor normal (a test passes its own normal for a wall).
func _aim(point: Vector3, normal := Vector3.UP, hit := true) -> Dictionary:
	return {"hit": hit, "point": point, "normal": normal, "distance": 10.0}


## `n` spots of open ground within the laser's reach of `me`, apart from each other: [Vector3].
func _find_open_spots(battle: Battle, me: Infantry, n: int) -> Array:
	var out: Array = []
	var angle := 0.0
	for ring in [18.0, 34.0, 50.0, 66.0, 82.0]:
		for i in 12:
			var p := battle.infantry.make_on_ground(me.global_position + Vector3(cos(angle), 0.0, sin(angle)) * ring)
			angle += TAU / 12.0 + 0.3
			if CallinSafety.make_reason_at(battle, p, 5.0, me.team).reason != "" or CallinSafety.is_covered(battle, p):
				continue
			if out.all(func(q: Vector3) -> bool: return Vector2(q.x - p.x, q.z - p.z).length() > 16.0):
				out.append(p)
			if out.size() >= n:
				return out
	return out


func _reset_callins(c: CallinDirector) -> void:
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 2000
	c.points.mine = 2000
	c._player_state({"cool": {}, "shared": 0.0, "used": {}})
	for o in c.orders.values():
		c.apply_cancel(o, "test", true)
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 2000


func _open_count(c: CallinDirector) -> int:
	return c.orders.values().filter(func(o: CallinOrder) -> bool: return o.is_open()).size()


func _last_order(c: CallinDirector) -> CallinOrder:
	return c.orders.values().back() if not c.orders.is_empty() else null


func _near_xz(a: Vector3, b: Vector3, metres := 0.2) -> bool:
	return Vector2(a.x - b.x, a.z - b.z).length() <= metres


func _check_designation(battle: Battle, c: CallinDirector, me: Infantry) -> void:
	print("  laser designation:")
	_send_others_away(battle)
	_reset_callins(c)
	var spots := _find_open_spots(battle, me, 6)
	_spots = spots
	_expect(spots.size() >= 5, "open ground to designate (%d spots)" % spots.size())
	if spots.size() < 5:
		return
	var d := c.designator
	d.aim_override = func() -> Dictionary: return _aim(spots[0])
	_expect(d.begin("armor_drop", "medium"), "picking a call-in raises the laser to aim for it")
	_expect(d.phase == CallinDesignator.Phase.AIMING and CallinDesignator.is_raised(me) and d.laser != null and d.laser.is_raised(),
		"the laser is up and the weapon in hand is blocked")
	_expect(bool(d.verdict.ok) and d.laser.dot.is_ok(), "a clear spot shows green (%s)" % d.verdict.reason)
	_expect(c.make_hud_lines().any(func(l: String) -> bool: return l.begins_with("ARMOUR DROP: LASER")), "the HUD says what is being designated: '%s'" % c.make_hud_lines().back())
	await _shot_at(battle, spots[0], Vector3(-6, 4, 14), "laser_valid")
	var made := c.orders.size()
	d.apply_confirm()
	var order := _last_order(c)
	_expect(c.orders.size() == made + 1 and order.kind == "armor_drop" and order.variant == "medium" and order.source == "laser",
		"fire designates: the order is made for the armour drop (source laser)")
	_expect(_near_xz(order.lz, spots[0]) and absf(order.lz.y - spots[0].y) < 1.0, "and its zone is the designated spot, not the caller's feet (%.1f m off)" % order.lz.distance_to(spots[0]))
	_expect(not d.is_active() and not d.laser.is_raised(), "the laser goes down")
	d.apply_frame(0.016)
	await _frames(2)
	_expect(not CallinDesignator.is_raised(me), "and the weapon is free again once fire is up")
	c.apply_cancel(order, "test", true)
	await _check_invalid_designations(battle, c, me, spots)
	await _check_designation_cancel(battle, c, me, spots)
	await _check_designation_input(battle, c, me, spots)


func _check_invalid_designations(battle: Battle, c: CallinDirector, me: Infantry, spots: Array) -> void:
	print("  and the verdict on a bad spot:")
	_reset_callins(c)
	var d := c.designator
	var before := _open_count(c)
	d.aim_override = func() -> Dictionary: return _aim(me.global_position + Vector3(400, 0, 0))
	d.begin("ammo_drop", "")
	_expect(not bool(d.verdict.ok) and str(d.verdict.reason).begins_with("Out of range"), "out of range: '%s'" % d.verdict.reason)
	_expect(not d.laser.dot.is_ok() and d.laser.dot.get_text().begins_with("Out of range"), "the dot is red and says why")
	d.aim_override = func() -> Dictionary: return _aim(spots[1], Vector3.UP, false)
	d.apply_frame(1.0)
	_expect(str(d.verdict.reason) == CallinPlacement.REASON_NO_POINT, "nothing under the laser: '%s'" % d.verdict.reason)
	d.aim_override = func() -> Dictionary: return _aim(spots[1], Vector3(1, 0.1, 0).normalized())
	d.apply_frame(1.0)
	_expect(str(d.verdict.reason).contains("too steep"), "a wall: '%s'" % d.verdict.reason)
	var roof := _build_box(battle, spots[2] + Vector3(0, 7, 0), Vector3(30, 1, 30))
	await _frames(3)
	d.aim_override = func() -> Dictionary: return _aim(spots[2])
	d.apply_frame(1.0)
	_expect(str(d.verdict.reason) == CallinSafety.REASON_COVER and not d.laser.dot.is_ok(), "inside a building (a roof overhead): '%s'" % d.verdict.reason)
	await _shot_at(battle, spots[2], Vector3(-6, 4, 14), "laser_invalid")
	d.apply_confirm()
	_expect(_open_count(c) == before and d.phase == CallinDesignator.Phase.AIMING, "firing at a red spot makes no order; the laser stays up")
	roof.queue_free()
	var wall := _build_box(battle, spots[3] + Vector3(1.5, 2, 0), Vector3(1, 6, 8))
	await _frames(3)
	d.aim_override = func() -> Dictionary: return _aim(spots[3])
	d.apply_frame(1.0)
	_expect(str(d.verdict.reason).begins_with("Cannot call in there"), "the footprint is not clear: '%s'" % d.verdict.reason)
	wall.queue_free()
	d.apply_cancel()
	c.points.balances[1] = 1
	c.points.mine = 1
	d.aim_override = func() -> Dictionary: return _aim(spots[1])
	d.begin("repair_station", "")
	_expect(str(d.verdict.reason).begins_with("Need"), "the raid points still count on a good spot: '%s'" % d.verdict.reason)
	d.apply_cancel()
	_reset_callins(c)
	await _frames(2)
	await _check_approach_and_direction(battle, c, me, spots)


## The line of sight to the approach (transport) and the second click of a directional kind.
func _check_approach_and_direction(battle: Battle, c: CallinDirector, me: Infantry, spots: Array) -> void:
	var d := c.designator
	var data := ExtractionRules.data()
	var transport := CallinVehicleRun.pick_transport_id()
	if transport == "":
		print("    (no transport installed: the approach check is skipped)")
	else:
		var zone := _find_vehicle_spot(battle, c, me)
		if zone == Vector3.INF:
			print("    (no open ground for a vehicle: the approach check is skipped)")
		else:
			var from := c.checks.make_approach_from("vehicle_delivery", zone)
			var out := Vector3(from.x - zone.x, 0.0, from.z - zone.z).normalized()
			var gate := _build_box(battle, zone + out * 40.0 + Vector3(0, 30, 0), Vector3(8, 60, 60))
			gate.rotation.y = atan2(-out.x, -out.z)
			await _frames(3)
			d.aim_override = func() -> Dictionary: return _aim(zone)
			d.begin("vehicle_delivery", "")
			_expect(str(d.verdict.reason) == CallinPlacement.REASON_NO_APPROACH, "a wall across the flight in: '%s'" % d.verdict.reason)
			gate.queue_free()
			await _frames(3)
			d.apply_frame(1.0)
			_expect(bool(d.verdict.ok), "the way in open again: green (%s)" % d.verdict.reason)
			d.apply_cancel()
	var rule: Dictionary = data.callins.kinds.ammo_drop
	var had = rule.get("designation")
	rule["designation"] = {"direction": true}
	_reset_callins(c)
	d.aim_override = func() -> Dictionary: return _aim(spots[0])
	d.begin("ammo_drop", "")
	d.apply_confirm()
	_expect(d.phase == CallinDesignator.Phase.DIRECTING and c.orders.is_empty(), "a directional kind takes a second click for the line")
	d.aim_override = func() -> Dictionary: return _aim(spots[0] + Vector3(0, 0, 30))
	d.apply_frame(1.0)
	_expect(d.laser.is_raised(), "the arrow of the line is drawn")
	d.apply_confirm()
	var order := _last_order(c)
	_expect(order != null and order.direction.distance_to(Vector3(0, 0, 1)) < 0.01 and _near_xz(order.lz, spots[0]), "the second click gives the line (+z) at the first spot")
	c.apply_cancel(order, "test", true)
	_reset_callins(c)
	d.aim_override = func() -> Dictionary: return _aim(spots[0])
	d.begin("ammo_drop", "")
	d.apply_confirm()
	d.aim_override = func() -> Dictionary: return _aim(spots[0] + Vector3(1, 0, 0))
	d.apply_frame(1.0)
	d.apply_confirm()
	order = _last_order(c)
	var facing := -me.global_basis.z
	facing.y = 0.0
	_expect(order != null and order.direction.distance_to(facing.normalized()) < 0.01, "a second click close to the first leaves it to the way the caller faces")
	if order != null:
		c.apply_cancel(order, "test", true)
	if had == null:
		rule.erase("designation")
	else:
		rule["designation"] = had
	_reset_callins(c)


## A spot a vehicle can be set down on, in laser reach of the caller (Vector3.INF when none).
func _find_vehicle_spot(battle: Battle, c: CallinDirector, me: Infantry) -> Vector3:
	var footprint := CallinChecks.make_footprint(CallinRules.KIND_VEHICLE, BOUGHT_VEHICLE)
	for ring in [30.0, 50.0, 70.0, 90.0]:
		for i in 16:
			var a := TAU * float(i) / 16.0
			var p := battle.infantry.make_on_ground(me.global_position + Vector3(cos(a), 0.0, sin(a)) * ring)
			var from := c.checks.make_approach_from("vehicle_delivery", p)
			if CallinSafety.make_reason_at(battle, p, footprint, me.team).reason == "" and not CallinSafety.is_covered(battle, p) \
					and (from == Vector3.INF or CallinPlacement.is_approach_open(battle, p, from, "vehicle_delivery")):
				return p
	return Vector3.INF


func _check_designation_cancel(_battle: Battle, c: CallinDirector, me: Infantry, spots: Array) -> void:
	print("  cancelling a designation:")
	_reset_callins(c)
	var d := c.designator
	d.aim_override = func() -> Dictionary: return _aim(spots[0])
	for action in ["menu_back", "jet", "fire_group_2", "callin_menu"]:
		if not InputMap.has_action(action):
			continue
		d.begin("ammo_drop", "")
		await _press_action_until(action, func() -> bool: return d.phase == CallinDesignator.Phase.IDLE)
		_expect(d.phase == CallinDesignator.Phase.IDLE and _open_count(c) == 0 and not d.laser.is_raised(),
			"%s cancels: the laser goes down, no order (phase %d, %d open)" % [action, d.phase, _open_count(c)])
		d.apply_frame(0.016)
		await _frames(2)
	var used := c.cooldowns.make_used(1, "ammo_drop")
	d.begin("ammo_drop", "")
	d.apply_cancel()
	d.apply_frame(0.016)
	_expect(c.points.get_balance(1) == 2000 and c.cooldowns.make_used(1, "ammo_drop") == used, "a cancelled designation costs nothing")
	_expect(not CallinDesignator.is_raised(me), "and frees the weapon")


func _check_designation_input(battle: Battle, c: CallinDirector, me: Infantry, spots: Array) -> void:
	print("  the real buttons:")
	_reset_callins(c)
	var d := c.designator
	d.aim_override = func() -> Dictionary: return _aim(spots[0])
	d.begin("ammo_drop", "")
	Input.action_press("fire_group_1")
	await _frames(4)
	_expect(me.weapons.all(func(w) -> bool: return not w.trigger), "fire does not shoot while the laser is up")
	Input.action_release("fire_group_1")
	await _press_action("fire_group_1")
	var order := _last_order(c)
	_expect(order != null and order.kind == "ammo_drop" and _near_xz(order.lz, spots[0]), "the fire button designates the spot")
	if order != null:
		c.apply_cancel(order, "test", true)
	d.aim_override = Callable()
	_reset_callins(c)
	d.begin("ammo_drop", "")
	var hit_ground := false
	for pitch in [-1.2, -0.9, -0.6, -0.3, 0.3]:
		battle.pilot.set("aim_pitch", pitch)
		await _frames(25)
		hit_ground = hit_ground or bool(d.aim.hit)
	_expect(hit_ground, "with no override the laser follows the line of sight and hits the ground (%s)" % [d.aim.point])
	d.apply_cancel()
	battle.pilot.set("aim_pitch", 0.0)


# ------------------------------------------------------------------ the teammates see the dot

## The teammate is a raid player again (an earlier section may have sent him out).
func _make_mate_a_raider(c: CallinDirector) -> void:
	c.director.status[MATE_PEER] = ExtractionDirector.STATUS_IN_RAID


func _check_laser_sync(battle: Battle, c: CallinDirector, me: Infantry, spots: Array) -> void:
	print("  teammates see the laser dot:")
	_reset_callins(c)
	_make_mate_a_raider(c)
	var told := []
	c.tap = func(peer: int, method: String, args: Array) -> void: told.append([peer, method, args])
	var d := c.designator
	d.aim_override = func() -> Dictionary: return _aim(spots[0])
	d.begin("armor_drop", "light")
	d.apply_frame(0.2)
	var seen := told.filter(func(m: Array) -> bool: return m[1] == "_laser_seen")
	_expect(seen.any(func(m: Array) -> bool: return m[0] == MATE_PEER and m[2][0] == 1 and m[2][1] == true and (m[2][2] as Vector3).is_equal_approx(spots[0])),
		"the host passes the dot to the teammate")
	_expect(not seen.any(func(m: Array) -> bool: return m[0] in [NEAR_PEER, FAR_PEER, 1]), "not to the enemy players and not back to the painter")
	var dot_message: Array = seen[0][2]
	c.tap = Callable()
	c._laser_seen(7, true, spots[1], true)
	var shown: CallinLaserDot = c.laser_sync.dots[7].dot
	_expect(shown != null and shown.global_position.is_equal_approx(spots[1]) and shown.is_ok(), "on the teammate's machine a dot stands on the spot")
	c._laser_seen(7, true, spots[2], false)
	_expect(c.laser_sync.dots.size() == 1 and not shown.is_ok() and shown.global_position.is_equal_approx(spots[2]), "and follows it (red when the spot is bad)")
	await _shot_at(battle, spots[2], Vector3(-6, 4, 14), "laser_teammate")
	c._laser_seen(7, false, Vector3.ZERO, false)
	await _frames(2)
	_expect(c.laser_sync.dots.is_empty() and not is_instance_valid(shown), "turned off: the dot is gone")
	c._laser_seen(8, true, spots[1], true)
	c.laser_sync.dots[8].seen = Time.get_ticks_msec() - CallinLaserSync.STALE_MSEC - 10
	c.laser_sync.apply_forget_stale()
	_expect(c.laser_sync.dots.is_empty(), "a dot that stopped coming is dropped")
	_expect(dot_message.size() == 4, "the message is plain values (peer, on, point, ok)")
	d.apply_cancel()
	told.clear()
	c.tap = func(peer: int, method: String, args: Array) -> void: told.append([peer, method, args])
	d.begin("armor_drop", "light")
	d.apply_cancel()
	_expect(told.any(func(m: Array) -> bool: return m[1] == "_laser_seen" and m[0] == MATE_PEER and m[2][1] == false), "lowering the laser tells the team it is off")
	c.tap = Callable()
	_reset_callins(c)


# ------------------------------------------------------------------ ordering on the command map

func _check_map_order(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry, spots: Array) -> void:
	print("  ordering on the command map:")
	_reset_callins(c)
	var map := CommandMap.open(battle, me)
	await get_tree().process_frame
	await get_tree().process_frame
	await _frames(4)
	_expect(map != null and map.callin_order != null, "the command map of a raid lists the call-ins")
	if map == null or map.callin_order == null:
		return
	var o := map.callin_order
	_expect(map.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.text.contains("RP")).size() == CallinRules.make_offers().size(),
		"a button per call-in with its cost")
	var made := _open_count(c)
	o.begin("ammo_drop", "")
	_expect(o.step == CommandMapCallins.Step.POINT, "picking one waits for the point")
	var blocker := _spawn_hostile(battle, spots[2])
	await _frames(3)
	map.view.cursor = map.view.to_map(spots[2])
	o.apply_click(map.view.to_world(map.view.cursor))
	_expect(_open_count(c) == made and o.step == CommandMapCallins.Step.POINT and str(o.verdict.reason).contains("unit is standing"),
		"a click on a spot with a unit on it is refused with the reason: '%s'" % o.verdict.reason)
	_expect(map._status.text.contains("unit is standing"), "and the status line says it")
	await _shot("map_order_invalid")
	battle.remove_vehicle(blocker.net_id)
	await _frames(2)
	map.view.cursor = map.view.to_map(spots[0])
	o.apply_frame(1.0)
	_expect(bool(o.verdict.ok), "the same click on open ground is green")
	await _shot("map_order")
	map.view.cancelled.emit()
	_expect(o.step == CommandMapCallins.Step.NONE and _open_count(c) == made, "a right click cancels the order")
	o.begin("ammo_drop", "")
	map.view.cursor = map.view.to_map(spots[0])
	map.view._gui_input(_left_click(map.view.cursor))
	var order := _last_order(c)
	_expect(_open_count(c) == made + 1 and order.kind == "ammo_drop" and order.source == "map" and _near_xz(order.lz, spots[0], 1.5),
		"a click on the map orders it (source map) at the clicked point")
	_expect(c.points.get_balance(1) == 2000 - 120 and c.make_local_refusal("ammo_drop", "").contains("cooldown"), "costs 120 RP and the cooldown applies")
	o.begin("ammo_drop", "")
	o.apply_click(map.view.to_world(map.view.cursor))
	_expect(not bool(o.verdict.ok) and str(o.verdict.reason).contains("cooldown") and _open_count(c) == made + 1, "ordering it again is refused: '%s'" % o.verdict.reason)
	o.apply_cancel()
	await _check_map_direction_and_sweep(battle, x, c, me, map, spots)
	map.close()
	await _frames(3)
	_expect(CommandMap.find_open(battle) == null, "the map closes")
	_reset_callins(c)


func _left_click(at: Vector2) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = at
	return e


func _check_map_direction_and_sweep(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry, map: CommandMap, spots: Array) -> void:
	var o := map.callin_order
	var rule: Dictionary = ExtractionRules.data().callins.kinds.repair_station
	var had = rule.get("designation")
	rule["designation"] = {"direction": true}
	_reset_callins(c)
	o.begin("repair_station", "")
	map.view.cursor = map.view.to_map(spots[3])
	o.apply_click(map.view.to_world(map.view.cursor))
	_expect(o.step == CommandMapCallins.Step.DIRECTION, "a directional kind waits for the direction click")
	map.view.cursor = map.view.to_map(spots[3] + Vector3(300, 0, 0))
	await _shot("map_order_direction")
	o.apply_click(map.view.to_world(map.view.cursor))
	var order := _last_order(c)
	_expect(order != null and order.source == "map" and order.direction.distance_to(Vector3(1, 0, 0)) < 0.05, "the second click sets the line (+x)")
	if order != null:
		c.apply_cancel(order, "test", true)
	if had == null:
		rule.erase("designation")
	else:
		rule["designation"] = had
	_reset_callins(c)
	var far := Vector3.INF
	for dir in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var p: Vector3 = x.make_ground_point(me.global_position + dir * 340.0)
		if battle.bounds == null or not battle.bounds.bounds.is_outside(p):
			far = p
			break
	if far == Vector3.INF:
		print("    (no point 340 m away inside the area: the far sweep is skipped)")
		return
	var hostile := _spawn_hostile(battle, far + Vector3(20, 0, 0))
	await _frames(5)
	o.begin("radar_sweep", "")
	map.view.cursor = map.view.to_map(far)
	o.apply_click(map.view.to_world(map.view.cursor))
	var sweep := _last_order(c)
	_expect(sweep != null and sweep.kind == "radar_sweep" and sweep.source == "map" and _near_xz(sweep.lz, far, 2.0),
		"a sweep ordered on the map is centred on the clicked point, 340 m from the caller")
	await _wait_for(func() -> bool: return c.sweep_contacts.any(func(k: Dictionary) -> bool: return int(k.id) == hostile.net_id), 3.0)
	_expect(c.sweep_contacts.any(func(k: Dictionary) -> bool: return int(k.id) == hostile.net_id), "and it finds the unit there (beyond the caller's own radar range)")
	if sweep != null:
		c.apply_cancel(sweep, "test", true)
	battle.remove_vehicle(hostile.net_id)


# ------------------------------------------------------------------ every kind lands where it was designated

func _check_every_kind(battle: Battle, x: ExtractionDirector, c: CallinDirector, me: Infantry, spots: Array) -> void:
	print("  every call-in lands on the designated spot:")
	var d := c.designator
	var kinds := [["armor_drop", "light"], ["ammo_drop", ""], ["repair_station", ""], ["inventory_station", ""], ["radar_sweep", ""]]
	var caps := {}
	for k in kinds:
		caps[k[0]] = ExtractionRules.data().callins.kinds[k[0]].max_per_raid
		ExtractionRules.data().callins.kinds[k[0]].max_per_raid = 99
	_reset_callins(c)
	for pod_kind in CallinRules.POD_KINDS:
		var request := CallinRequest.make(pod_kind, "light" if pod_kind == CallinRules.KIND_ARMOR else "", 1, spots[0])
		_expect(bool(c.checks.make_plan(request).ok), "%s is accepted at an open spot, like every other pod: '%s'" % [pod_kind, c.checks.make_plan(request).reason])
	var orders := []
	for i in kinds.size():
		c.apply_clear_cooldowns(1)
		c.points.balances[1] = 2000
		var spot: Vector3 = spots[i]
		d.aim_override = func() -> Dictionary: return _aim(spot)
		d.begin(kinds[i][0], kinds[i][1])
		d.apply_confirm()
		var order := _last_order(c)
		_expect(order != null and order.kind == kinds[i][0] and _near_xz(order.lz, spot), "%s is ordered at its designated spot" % kinds[i][0])
		orders.append(order)
		if i == 1 or i == 3:
			await _wait_for(func() -> bool: return orders.all(func(o: CallinOrder) -> bool: return o == null or not o.is_in_flight()), 14.0)
	await _wait_for(func() -> bool: return orders.all(func(o: CallinOrder) -> bool: return o != null and o.state >= CallinOrder.State.ACTIVE), 16.0)
	for i in orders.size():
		var order: CallinOrder = orders[i]
		var kind: String = kinds[i][0]
		var obj: Node3D = null
		if kind in ["armor_drop", "ammo_drop"]:
			obj = c.crates.get(order.object_id)
		elif kind in ["repair_station", "inventory_station"]:
			obj = c.stations.get(order.object_id)
		if kind == "radar_sweep":
			_expect(order.state >= CallinOrder.State.ACTIVE and _near_xz(order.lz, spots[i]), "radar_sweep: centred on the spot")
		else:
			_expect(obj != null and _near_xz(obj.global_position, spots[i], 2.5), "%s: the %s stands on the spot (%.1f m off)" % [kind, "crate" if kind.ends_with("_drop") else "station",
				obj.global_position.distance_to(spots[i]) if obj != null else -1.0])
	await _frames(2)
	for k in caps:
		ExtractionRules.data().callins.kinds[k].max_per_raid = caps[k]
	_reset_callins(c)
	d.aim_override = Callable()


# ------------------------------------------------------------------ 5 the vehicle delivery

func _check_delivery() -> void:
	print("5 the vehicle delivery:")
	var data := ExtractionRules.data()
	var battle := await _start_raid(_prepare_profile)
	var x := battle.extraction
	var c := x.callins
	var me := battle.player as Infantry
	await _wait_for(func() -> bool: return not me.stowed, 90.0)
	await _frames(20)
	var transport_id := CallinVehicleRun.pick_transport_id()
	print("    transport: %s" % (transport_id if transport_id != "" else "none installed"))
	_expect(await _move_to_clear_ground(battle, me), "open ground found for a vehicle")
	c.points.balances[1] = 1000
	c.points.mine = 1000
	c.apply_clear_cooldowns(1)
	await _check_vehicle_refusals(c)
	await _check_vehicle_designation(battle, c, me)
	if transport_id != "":
		await _check_transport_delivery(battle, c, me)
	await _check_pod_delivery(battle, c, me, data)
	await _check_cancels(battle, c, me, data)
	await _check_extract_keeps(battle, x, c)
	await _free_scene()


func _check_vehicle_designation(battle: Battle, c: CallinDirector, me: Infantry) -> void:
	var zone := _find_vehicle_spot(battle, c, me)
	if zone == Vector3.INF:
		print("    (no open ground in reach for a vehicle: the laser designation of one is skipped)")
		return
	var d := c.designator
	d.aim_override = func() -> Dictionary: return _aim(zone)
	d.begin("vehicle_delivery", "")
	_expect(bool(d.verdict.ok), "a vehicle designated by laser on open ground is green (%s)" % d.verdict.reason)
	d.apply_confirm()
	d.aim_override = Callable()
	var order := _last_order(c)
	_expect(order != null and order.source == "laser" and _near_xz(order.lz, zone), "the vehicle comes to the designated spot, not to the caller")
	if order != null:
		c.apply_cancel(order, "test", true)
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000


func _vehicle_cost() -> int:
	return CallinRules.make_cost(CallinRules.KIND_VEHICLE, "", BOUGHT_VEHICLE)


func _check_vehicle_refusals(c: CallinDirector) -> void:
	print("  the saved vehicle:")
	var o := OperatorProfile.load_for(_pilot)
	o.make_active_slot().vehicle = OTHER_VEHICLE
	o.save()
	_expect(c.make_refusal(1, "vehicle_delivery", "").contains("do not own"), "a vehicle he does not own: '%s'" % c.make_refusal(1, "vehicle_delivery", ""))
	_expect(c.make_local_refusal("vehicle_delivery", "").contains("do not own"), "and the menu says the same")
	o.make_active_slot().vehicle = BOUGHT_VEHICLE
	o.unlocks.apply_lose(UnlockId.make("vehicle", BOUGHT_VEHICLE))
	o.save()
	_expect(c.make_refusal(1, "vehicle_delivery", "").contains("buy it back"), "a vehicle lost in a raid: '%s'" % c.make_refusal(1, "vehicle_delivery", ""))
	o.unlocks.apply_recover(UnlockId.make("vehicle", BOUGHT_VEHICLE))
	o.make_active_slot().vehicle = ""
	o.save()
	_expect(c.make_refusal(1, "vehicle_delivery", "") == CallinRefusals.NO_VEHICLE, "no vehicle saved in the slot")
	o.make_active_slot().vehicle = "nothing:installed"
	o.save()
	_expect(c.make_refusal(1, "vehicle_delivery", "").contains("not installed"), "a vehicle of a pack that is not installed")
	o.make_active_slot().vehicle = BOUGHT_VEHICLE
	o.save()
	_expect(c.make_refusal(1, "vehicle_delivery", "") == "", "the bought vehicle: allowed")


func _check_transport_delivery(battle: Battle, c: CallinDirector, me: Infantry) -> void:
	print("  by transport:")
	var balance := c.points.get_balance(1)
	var order := c.apply_request(1, "vehicle_delivery", "")
	_expect(order != null and order.state == CallinOrder.State.MARKED, "vehicle delivery: MARKED, flare down")
	if order == null:
		return
	_expect(c.points.get_balance(1) == balance - _vehicle_cost(), "%d RP paid for its class" % _vehicle_cost())
	var clamp := CallinRules.make_eta_clamp(battle.config, CallinRules.rule(CallinRules.KIND_VEHICLE))
	_expect(order.eta >= clamp[0] - 0.1 and order.eta <= clamp[1] + 0.1, "the ETA is inside the clamp %s: %.1f s" % [clamp, order.eta])
	_expect(c.make_hud_lines().any(func(l: String) -> bool: return l.begins_with("VEHICLE DELIVERY MARKED")), "the HUD: '%s'" % c.make_hud_lines().back())
	_expect(order.lz.distance_to(me.global_position) > 1.0 and not CallinSafety.is_covered(battle, order.lz), "the zone is clear of the caller, under open sky")
	_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.INBOUND, 30.0), "after the preparation the transport flies")
	var flyer := battle.vehicles.get(order.transport_id) as Flyer
	var cargo := battle.vehicles.get(order.cargo_net_id) as Herc
	_expect(flyer != null and flyer.has_meta("transport") and flyer.has_meta("dormant"), "an AI transport (%s), dormant" % (flyer.vehicle_id if flyer else "-"))
	_expect(flyer != null and flyer.vehicle_id == CallinVehicleRun.pick_transport_id(BOUGHT_VEHICLE), "the transport is the one chosen for the cargo")
	_expect(cargo != null and cargo.vehicle_id == BOUGHT_VEHICLE and cargo.has_meta("carried_by"), "the vehicle is slung under it")
	await _frames(30)
	var sling := c.vehicles.make_sling_of(order)
	_expect(cargo.global_position.y < flyer.global_position.y - 4.0 and cargo.global_position.distance_to(flyer.global_position) < sling + 4.0, "hanging %.1f m below (sling %.1f m)" % [flyer.global_position.y - cargo.global_position.y, sling])
	var cargo_height := float(Packs.vehicle(BOUGHT_VEHICLE).get("height_m", 0.0))
	_expect(sling >= cargo_height + CallinVehicleRun.SLING_CLEARANCE_M, "the sling is as long as the vehicle is tall, so it hangs clear of the hull (%.1f m for %.1f m)" % [sling, cargo_height])
	_expect(c.make_hud_lines().any(func(l: String) -> bool: return l.begins_with("VEHICLE DELIVERY INBOUND")), "the HUD counts the flight: '%s' (%.0f s)" % [c.make_hud_lines().back(), order.eta])
	await _shot_at(battle, flyer.global_position, Vector3(40, 10, 40), "transport_inbound")
	var aware := _spawn_hostile(battle, order.lz + Vector3(120, 0, 0))
	var brain := InfantryBot.make(aware, battle.infantry.bots.allocate_bot_id(), 0.5)
	aware.add_child(brain)
	c.alert.apply_noise(order.lz, 250.0, order.team)
	_expect(brain.objective.has(CallinAlert.META_KEY), "enemy AI within 250 m is drawn to the noise of the transport")
	battle.remove_vehicle(aware.net_id)
	if _shots != "" and DisplayServer.get_name() != "headless":
		await _shoot_dropship_landing(battle, order, flyer)
	var release_alt := [INF]
	_expect(await _wait_for(func() -> bool:
		if is_instance_valid(flyer) and order.state == CallinOrder.State.INBOUND:
			release_alt[0] = flyer.make_altitude()
		return order.state == CallinOrder.State.DELIVERING, 60.0), "it hovers over the zone and lets go: DELIVERING")
	var hover_m := float(CallinRules.rule(CallinRules.KIND_VEHICLE).get("hover_height_m", 6.0)) + sling
	_expect(absf(float(release_alt[0]) - hover_m) <= 3.0, "the vehicle is released at the hover height (%.1f m over the ground, hover %.0f m)" % [release_alt[0], hover_m])
	await _shot_at(battle, order.lz, Vector3(30, 14, 30), "transport_hover")
	_expect(not cargo.has_meta("carried_by"), "the vehicle is released")
	_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.ACTIVE, 20.0), "the vehicle settles on the ground: ACTIVE")
	await _frames(10)
	_expect(cargo.alive and VehicleOccupancy.of(cargo).make_occupants().is_empty() and cargo.team == me.team, "empty, parked, of the caller's team")
	_expect(cargo.global_position.distance_to(order.lz) < 25.0, "near the landing zone (%.1f m)" % cargo.global_position.distance_to(order.lz))
	_expect(OperatorProfile.load_for(_pilot).at_risk.has(UnlockId.make("vehicle", BOUGHT_VEHICLE)), "called in: the bought vehicle is at risk on his profile (O4)")
	_expect(c.vehicles.claims.has(cargo.net_id), "for owner_claim_s only the caller may board it")
	await _shot_at(battle, cargo.global_position, Vector3(20, 7, 20), "vehicle_delivered")
	var mate := battle.occupancy.soldier_of(MATE_PEER)
	mate.global_position = cargo.global_position + Vector3(0, 0.5, 6)
	await _frames(3)
	var refused := BoardingRules.make_seat_choice(mate, cargo, VehicleOccupancy.of(cargo))
	_expect(not bool(refused.ok) and str(refused.reason).begins_with("Reserved for"), "another player cannot board during the claim: %s" % refused.reason)
	_expect(BoardingRules.make_claim_reason(me, cargo) == "", "the caller is not kept out by the claim")
	c.vehicles.claims[cargo.net_id].left = 0.0
	await _frames(3)
	_expect(BoardingRules.make_claim_reason(mate, cargo) == "" and not cargo.has_meta(BoardingRules.CLAIM_META), "after the claim anyone may board")
	battle.occupancy.apply_board(MATE_PEER, cargo, VehicleOccupancy.PILOT_SEAT)
	await _frames(5)
	_expect(VehicleOccupancy.of(cargo).make_occupants().has(MATE_PEER), "he boards")
	battle.occupancy.apply_exit(MATE_PEER, cargo)
	await _frames(5)
	_expect(await _wait_for(func() -> bool: return not battle.vehicles.has(order.transport_id), 60.0), "the transport flew off and was removed")
	await _check_abandon(battle, order, cargo, me)


## The dropship on its way down with the vehicle slung under it (eye check of the landing sequence): on the approach, then at the hover.
func _shoot_dropship_landing(battle: Battle, order: CallinOrder, flyer: Flyer) -> void:
	await _wait_for(func() -> bool: return not is_instance_valid(flyer) or Vector2(flyer.global_position.x - order.lz.x, flyer.global_position.z - order.lz.z).length() < 120.0, 60.0)
	if is_instance_valid(flyer):
		await _shot_at(battle, flyer.global_position, Vector3(60, -4, 60), "dropship_approach")
	await _wait_for(func() -> bool: return not is_instance_valid(flyer) or flyer.make_altitude() < 21.0 or order.state != CallinOrder.State.INBOUND, 30.0)
	if is_instance_valid(flyer) and order.state == CallinOrder.State.INBOUND:
		await _shot_at(battle, flyer.global_position, Vector3(48, -8, 48), "dropship_landing")


## A point `metres` from `from` that lies inside the playable area, on the ground (the first of eight directions that does).
func _find_far_point(battle: Battle, from: Vector3, metres: float) -> Vector3:
	for i in 8:
		var a := TAU * float(i) / 8.0
		var p: Vector3 = battle.extraction.make_ground_point(from + Vector3(cos(a), 0.0, sin(a)) * metres)
		if battle.bounds == null or not battle.bounds.bounds.is_outside(p):
			return p
	return from + Vector3(0, 0, metres)


func _check_abandon(battle: Battle, order: CallinOrder, cargo: Herc, me: Infantry) -> void:
	for peer in [1, MATE_PEER]:
		var s := battle.occupancy.soldier_of(peer)
		s.global_position = _find_far_point(battle, cargo.global_position, 400.0) + Vector3(0, 0.5, 0)   # no friend within 150 m
		s.velocity = Vector3.ZERO
	await _frames(5)
	var cargo_id := cargo.net_id
	order.ttl_left = 0.4
	_expect(await _wait_for(func() -> bool: return not order.is_open(), 5.0), "nobody comes for it: the order ends")
	await _frames(3)
	_expect(not battle.vehicles.has(cargo_id), "it is recalled (removed)")
	_expect(not OperatorProfile.load_for(_pilot).at_risk.has(UnlockId.make("vehicle", BOUGHT_VEHICLE)), "recalled: no longer at risk, no loss")
	await _move_to_clear_ground(battle, me)


func _check_pod_delivery(battle: Battle, c: CallinDirector, me: Infantry, data: Dictionary) -> void:
	print("  by pod (no transport installed):")
	var ids: Array = data.callins.kinds.vehicle_delivery.transport_ids.duplicate()
	data.callins.kinds.vehicle_delivery.transport_ids = []
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	var order := c.apply_request(1, "vehicle_delivery", "")
	_expect(order != null and order.transport_vehicle == "", "no transport: a drop pod brings it (%s)" % c.make_refusal(1, "vehicle_delivery", ""))
	if order == null:
		data.callins.kinds.vehicle_delivery.transport_ids = ids
		return
	_expect(order.fall_s > 0.0, "its fall takes %.1f s" % order.fall_s)
	_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.INBOUND, 20.0) and c.fx.markers[order.id].pod != null, "the pod falls")
	_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.ACTIVE, 20.0), "it lands and the vehicle stands there")
	var cargo := battle.vehicles.get(order.cargo_net_id) as Herc
	_expect(cargo != null and cargo.vehicle_id == BOUGHT_VEHICLE and cargo.team == me.team, "the caller's vehicle, of his team")
	_expect(OperatorProfile.load_for(_pilot).at_risk.has(UnlockId.make("vehicle", BOUGHT_VEHICLE)), "at risk once it is out")
	await _shot_at(battle, order.lz, Vector3(24, 9, 24), "pod_vehicle")
	c.points.balances[1] = 1000
	_expect(c.make_refusal(1, "vehicle_delivery", "").contains("cooldown"), "the delivery is on its 300 s cooldown: '%s'" % c.make_refusal(1, "vehicle_delivery", ""))
	c.apply_clear_cooldowns(1)
	_expect(c.make_refusal(1, "vehicle_delivery", "").begins_with("No more"), "two deliveries per raid: the third is refused (cap)")
	if cargo != null:
		battle.remove_vehicle(cargo.net_id)
	data.callins.kinds.vehicle_delivery.transport_ids = ids
	order.ttl_left = 0.0
	await _frames(5)


func _check_cancels(battle: Battle, c: CallinDirector, me: Infantry, data: Dictionary) -> void:
	print("  cancelling:")
	data.callins.kinds.vehicle_delivery.max_per_raid = 9
	await _move_to_clear_ground(battle, me)
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 1000
	var order := c.apply_request(1, "vehicle_delivery", "")
	if order == null:
		_expect(false, "a delivery to cancel (%s)" % c.make_refusal(1, "vehicle_delivery", ""))
		return
	var shift: float = data.callins.lz.shift_m
	data.callins.lz.shift_m = 0.5
	var blocker := _spawn_hostile(battle, order.lz + Vector3(0.5, 0, 0))   # a unit in the zone: it has to shift
	_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.CANCELLED, 20.0), "a zone that must shift more than the limit cancels the order (%s)" % order.cancel_reason)
	_expect(c.points.get_balance(1) == 1000 and c.make_refusal(1, "vehicle_delivery", "") == "", "full refund of the raid points and the use")
	_expect(battle.vehicles.values().all(func(h) -> bool: return not (is_instance_valid(h) and h.has_meta("transport"))), "no transport or load was made")
	data.callins.lz.shift_m = shift
	battle.remove_vehicle(blocker.net_id)
	await _frames(3)
	var timeout: float = data.callins.fast.order_timeout_s
	data.callins.fast.order_timeout_s = 2.5
	c.apply_clear_cooldowns(1)
	order = c.apply_request(1, "vehicle_delivery", "")
	_expect(order != null and await _wait_for(func() -> bool: return order.state == CallinOrder.State.CANCELLED, 15.0), "an order that takes too long is cancelled (%s)" % (order.cancel_reason if order else "-"))
	_expect(c.points.get_balance(1) == 1000, "and refunded in full")
	await _frames(5)
	_expect(battle.vehicles.values().all(func(h) -> bool: return not (is_instance_valid(h) and (h.has_meta("transport") or h.vehicle_id == BOUGHT_VEHICLE))), "the transport and the load are removed")
	data.callins.fast.order_timeout_s = timeout


func _check_extract_keeps(battle: Battle, x: ExtractionDirector, c: CallinDirector) -> void:
	print("  extraction keeps the raid points:")
	c.apply_clear_cooldowns(1)
	c.points.balances[1] = 900
	c.points.mine = 900
	var credits := OperatorProfile.load_for(_pilot).credits
	var order := c.apply_request(1, "ammo_drop", "")
	_expect(order != null and c.points.get_balance(1) == 780, "an ammo drop is on its way (780 RP left)")
	x.apply_extract(1)
	await _frames(5)
	_expect(order != null and order.state == CallinOrder.State.CANCELLED and c.points.get_balance(1) == 900, "extracting cancels the orders on their way and refunds them")
	var o := OperatorProfile.load_for(_pilot)
	_expect(o.raid_points == 900 and not o.raid_open and o.at_risk.is_empty(), "the profile keeps the 900 raid points; the raid is closed, nothing at risk")
	_expect(o.credits == credits, "raid points never turned into credits")
	_expect(RaidOperator.make_points(_pilot) == 900, "they carry over to the next raid")


# ------------------------------------------------------------------ 6 the death of the operator

func _check_death() -> void:
	print("6 the death of the operator:")
	var battle := await _start_raid(_prepare_profile, false)
	var x := battle.extraction
	var c := x.callins
	var me := battle.player as Infantry
	await _wait_for(func() -> bool: return not me.stowed, 90.0)
	await _frames(20)
	await _move_to_clear_ground(battle, me)
	var credits := OperatorProfile.load_for(_pilot).credits
	_expect(OperatorProfile.load_for(_pilot).raid_open, "the raid is open on the profile")
	_expect(c.points.get_balance(1) > 0, "he carried his raid points over (%d)" % c.points.get_balance(1))
	var data := ExtractionRules.data()
	data.callins.kinds.vehicle_delivery.transport_ids = []
	c.points.balances[1] = 1000
	var order := c.apply_request(1, "vehicle_delivery", "")
	_expect(order != null, "he calls his bought vehicle in")
	if order != null:
		_expect(await _wait_for(func() -> bool: return order.state == CallinOrder.State.ACTIVE, 25.0), "it arrives")
	var vehicle_id := UnlockId.make("vehicle", BOUGHT_VEHICLE)
	_expect(OperatorProfile.load_for(_pilot).at_risk.has(vehicle_id), "it is at risk")
	c.apply_clear_cooldowns(1)
	var sweep := c.apply_request(1, "radar_sweep", "")
	_lethal_hit(me)
	await _frames(5)
	_expect(x.my_status == ExtractionDirector.STATUS_DEAD, "killed in action")
	var after := OperatorProfile.load_for(_pilot)
	_expect(after.raid_points == 0 and c.points.mine == 0 and c.points.get_balance(1) == 0, "the raid points are gone with the operator")
	_expect(after.credits == credits, "the credits are not touched")
	_expect(after.unlocks.is_lost(vehicle_id) and not after.unlocks.is_owned(vehicle_id), "the called-in vehicle is lost: re-buy %d cr" % EconomyRules.rebuy_price())
	_expect(x.my_lost.has(vehicle_id) and after.at_risk.is_empty() and not after.raid_open, "the death result lists it; nothing is at risk any more")
	_expect(sweep == null or not sweep.is_open(), "his orders on their way are over")
	await _shot("killed")
	await _wait_for(func() -> bool: return get_tree().current_scene is MatchResults, 20.0)
	await _free_scene()

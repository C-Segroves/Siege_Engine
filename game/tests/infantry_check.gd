extends Node
## Infantry and vehicle occupancy (docs/formats/tribes_infantry.md, tribes_vehicles.md section 6):
##   armour data (Tribes / Tribes 2 PlayerData), weapon family isolation, running / jumping / jetting,
##   energy, damage and respawn in light armour, the mode defaults (start on foot beside the parked vehicle),
##   vehicle_enter_exit (light armour only, empty vehicles only, within the hatch reach; exit beside the
##   hatch), Tribes touch boarding (Tribes 1 light-armour pilots and passengers, Tribes 2 lightOnly / heavy
##   seats / remount delay), destroyed vehicles eject their riders, inventory and ammo stations.
##   godot --headless --audio-driver Dummy --path game res://tests/infantry_check.tscn [-- --shots=<dir>]
## --shots (needs a window): first-person, chase, in-vehicle and station screenshots infantry_*.png.
## LAN replication: tests/e2e_driver.gd flows lan_host / lan_join (co-op starts on foot).

const MAP := "tribes:Raindance"
const SETTLE_FRAMES := 20
const RUN_SECONDS := 1.0
const JET_SECONDS := 1.0

var _failures := 0
var _shots := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	await get_tree().process_frame
	_check_armor_data()
	_check_weapon_families()
	_check_bindings()
	var battle := await _start_battle()
	await _check_start_on_foot(battle)
	await _check_movement(battle)
	await _check_hatch(battle)
	await _check_tribes_boarding(battle)
	await _check_destroyed_vehicle_ejects(battle)
	await _check_stations(battle)
	await _check_damage_and_respawn(battle)
	await _check_mission_start(battle)
	print("infantry_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
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


func _shot(battle: Battle, tag: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await _frames(4)
	await RenderingServer.frame_post_draw
	var path := "%s/infantry_%s.png" % [_shots, tag]
	battle.get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


# ------------------------------------------------------------------ data

func _check_armor_data() -> void:
	print("armour data:")
	var light := InfantryCatalog.armor("tribes:LIGHT")
	var heavy := InfantryCatalog.armor("tribes:HEAVY")
	_expect(not light.is_empty() and not heavy.is_empty(), "Tribes armours loaded")
	_expect(is_equal_approx(float(light.max_forward_speed), 11.0) and is_equal_approx(float(heavy.max_forward_speed), 5.0),
		"larmor / harmor maxForwardSpeed 11 / 5 m/s")
	_expect(absf(float(light.jump_speed) - 75.0 / 9.0) < 0.01, "larmor jump = jumpImpulse 75 / mass 9")
	_expect(absf(float(light.jet_accel) - 236.0 / 9.0) < 0.01, "larmor jet = jetForce 236 / mass 9")
	_expect(is_equal_approx(float(light.max_energy), 60.0) and is_equal_approx(float(light.hp), 1980.0),
		"larmor maxEnergy 60, maxDamage 0.66 -> 1980")
	_expect(int(light.max_weapons) == 3 and int(heavy.max_weapons) == 5, "$MaxWeapons 3 / 5")
	_expect(not (light.weapons as Array).has("tribes:MORTAR") and (heavy.weapons as Array).has("tribes:MORTAR"),
		"only heavy armour carries the mortar ($ItemMax)")
	_expect((light.default_loadout as Array) == ["tribes:BLASTER", "tribes:CHAINGUN", "tribes:DISC_LAUNCHER"],
		"spawn loadout = $spawnBuyList")
	_expect(bool(light.can_pilot) and not bool(heavy.can_pilot), "light armour pilots, heavy does not")
	var t2 := InfantryCatalog.armor("tribes2:HEAVY")
	_expect(not t2.is_empty() and is_equal_approx(float(InfantryCatalog.armor("tribes2:LIGHT").max_forward_speed), 14.0),
		"Tribes 2 armours loaded (light 14 m/s)")
	var shape := Assets.shape(str(light.shape))
	_expect(not shape.is_empty() and absf(float(light.height_m) - 2.16) < 0.1, "larmor shape exported, 2.16 m tall")


func _check_weapon_families() -> void:
	print("weapon families:")
	var infantry := Packs.weapons.values().filter(func(w: Dictionary) -> bool: return w.get("category") == "infantry")
	_expect(infantry.size() >= 18, "infantry weapons in the catalog (%d)" % infantry.size())
	_expect(Packs.weapons_for_mask(31, true).all(func(w: Dictionary) -> bool: return w.get("category", "herc") == "herc"),
		"Herc hardpoints never offer infantry weapons")
	var disc := Packs.weapon("tribes:DISC_LAUNCHER")
	_expect(is_equal_approx(float(disc.armor_damage), 1500.0) and is_equal_approx(float(disc.splash_radius), 7.5),
		"disc: 0.5 x 3000, radius 7.5 m")


func _check_bindings() -> void:
	print("bindings:")
	for action in ["jet", "weapon_next", "vehicle_enter_exit"]:
		_expect(InputMap.has_action(action) and InputMap.action_get_events(action).size() >= 2, "%s bound (keyboard + pad)" % action)
	for context in BindingContexts.CONTEXTS:
		var seen := {}
		var clash := ""
		for action in BindingContexts.CONTEXTS[context]:
			for ev in InputMap.action_get_events(action) if InputMap.has_action(action) else []:
				var key := _control_key(ev)
				if seen.has(key) and seen[key] != action:
					clash = "%s / %s" % [seen[key], action]
				seen[key] = action
		_expect(clash == "" or context != "infantry", "no default binding used twice in the %s context %s" % [context, clash])


static func _control_key(ev: InputEvent) -> String:
	if ev is InputEventJoypadMotion:
		return "axis%d%s" % [(ev as InputEventJoypadMotion).axis, signf((ev as InputEventJoypadMotion).axis_value)]
	return ev.as_text()


# ------------------------------------------------------------------ battle

func _start_battle() -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": [{"vehicle": "es1:SCORPION", "team": 1, "skill": 0.0, "name": "Target"}]}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _player_vehicle(battle: Battle) -> Herc:
	for h in battle.vehicles.values():
		if not (h is Infantry) and h.vehicle_id == "es1:RAPTOR" and h.team == 0:
			return h
	return null


func _check_start_on_foot(battle: Battle) -> void:
	print("mode default (start on foot):")
	var soldier := battle.player as Infantry
	var herc := _player_vehicle(battle)
	_expect(soldier != null and soldier.armor_id == "tribes:LIGHT", "the player starts on foot in light armour")
	_expect(herc != null and VehicleOccupancy.of(herc).is_empty() and herc.owner_peer == 0,
		"the chosen Raptor stands parked and empty")
	_expect(battle.pilot is InfantryPilot, "infantry controls")
	var ai_vehicle: Herc = battle.vehicles.values().filter(func(h: Herc) -> bool: return h.team == 1)[0]
	_expect(VehicleOccupancy.of(ai_vehicle).is_ai_piloted(), "the AI vehicle has its AI pilot")
	if soldier and herc:
		_expect(BoardingRules.is_within_hatch_reach(soldier, herc), "the soldier starts within the hatch reach")
	if soldier:
		_check_on_foot_view(battle, soldier)
	await _shot(battle, "first_person")
	if _shots != "":
		battle.use_chase = true
		await _seconds(1.5)
		await _shot(battle, "chase")
		battle.use_chase = false


## The arrival message, the chase camera and the weapon in hand of the player's soldier.
func _check_on_foot_view(battle: Battle, soldier: Infantry) -> void:
	var texts: Array = battle.overlay.hud.messages.map(func(m: Array) -> String: return str(m[0]))
	_expect(texts.any(func(t: String) -> bool: return t.begins_with("On foot - Light Armor") and t.contains("board")),
		"arrival message says on foot, not piloting (%s)" % [texts])
	_expect(not texts.any(func(t: String) -> bool: return t.begins_with("You are piloting")), "no piloting message on foot")
	var rig := BattleCameras.make_chase_rig(soldier)
	_expect(float(rig.distance) < 6.0 and float(rig.height) < 3.5, "chase camera sized to a 2 m soldier (%s)" % [rig])
	var held := soldier.held
	_expect(held.view_model != null and held.view_model.is_visible_in_tree(), "first-person weapon shown")
	_expect(held.world_model != null and held.world_model.get_parent() == soldier.shape.nodes[int(soldier.armor.hand_node)],
		"third-person weapon on the hand node")
	var cam := battle.cameras.cockpit_cam
	var in_front := true
	for mi in held.view_model.find_children("*", "MeshInstance3D", true, false):
		var centre: Vector3 = cam.global_transform.affine_inverse() * (mi.global_transform * mi.mesh.get_aabb().get_center())
		in_front = in_front and centre.z < -cam.near and (mi.layers & cam.cull_mask) != 0 \
			and (mi.layers & battle.cameras.chase_cam.cull_mask) == 0
	_expect(in_front, "view model in front of the eye, drawn by the first-person camera only")


func _check_movement(battle: Battle) -> void:
	print("movement:")
	var s := battle.player as Infantry
	battle.pilot.set_physics_process(false)   # drive the controls directly
	var p0 := s.global_position
	s.throttle = 1.0
	await _seconds(RUN_SECONDS)
	s.throttle = 0.0
	var run := Vector2(s.global_position.x - p0.x, s.global_position.z - p0.z).length()
	_expect(run > 5.0 and run < 11.5 * RUN_SECONDS, "runs %.1f m in %.1f s (max 11 m/s)" % [run, RUN_SECONDS])
	await _seconds(0.5)
	var y0 := s.global_position.y
	s.jump_input = true
	await _frames(3)
	s.jump_input = false
	await _seconds(0.25)
	_expect(s.global_position.y > y0 + 0.5, "jumps (%.2f m up)" % (s.global_position.y - y0))
	await _seconds(1.0)
	var e0 := s.capacitor
	y0 = s.global_position.y
	s.jet_input = true
	await _seconds(JET_SECONDS)
	s.jet_input = false
	_expect(s.global_position.y > y0 + 1.0, "jets up %.1f m" % (s.global_position.y - y0))
	_expect(s.capacitor < e0 - 10.0, "jetting spends energy (%.0f -> %.0f)" % [e0, s.capacitor])
	var e1 := s.capacitor
	await _seconds(1.0)
	_expect(s.capacitor > e1 + 5.0, "energy recharges (8 / s)")
	await _shot(battle, "jetting")
	await _seconds(2.0)
	battle.pilot.set_physics_process(true)


func _check_hatch(battle: Battle) -> void:
	print("hatch (non-Tribes vehicles):")
	var s := battle.player as Infantry
	var herc := _player_vehicle(battle)
	_place_beside(s, herc)
	await _frames(3)
	s.apply_armor("tribes:MEDIUM", ["tribes:BLASTER"])
	battle.refresh_player_view()
	await _frames(2)
	_expect(battle.occupancy.make_local_hint() == BoardingRules.REASON_LIGHT_ARMOR, "medium armour: hint '%s'" % battle.occupancy.make_local_hint())
	_press("vehicle_enter_exit")
	await _frames(3)
	_expect(battle.player == s and not s.stowed, "medium armour can't board")
	s.apply_armor("tribes:LIGHT", s.armor.default_loadout if false else ["tribes:BLASTER", "tribes:CHAINGUN"])
	battle.refresh_player_view()
	await _frames(2)
	_expect(battle.occupancy.make_local_hint().contains("enter"), "light armour: hint '%s'" % battle.occupancy.make_local_hint())
	_press("vehicle_enter_exit")
	await _frames(3)
	_expect(battle.player == herc and s.stowed and VehicleOccupancy.of(herc).pilot() == 1, "light armour boards the empty Raptor")
	_expect(herc.owner_peer == 1 and s.owner_peer == 0 and not s.is_in_group("vehicles"), "input drives the Herc; the soldier is out of play")
	_expect(battle.pilot is PlayerPilot and not (battle.pilot is InfantryPilot), "Herc controls")
	_expect(battle.occupancy.make_local_hint() == "%s: get out of the Raptor" % OccupancyHint.make_key_text(),
		"in the Raptor: exit hint '%s'" % battle.occupancy.make_local_hint())
	_expect(_last_message(battle).begins_with("You are piloting"), "boarding announces the vehicle")
	_expect(not s.held.view_shown, "the soldier's first-person weapon hides in the vehicle")
	await _shot(battle, "in_herc")
	herc.throttle = 0.5
	await _seconds(1.0)
	_expect(s.global_position.distance_to(herc.global_position) < 0.5, "the soldier rides along")
	_press("vehicle_enter_exit")
	await _frames(3)
	_expect(battle.player == s and not s.stowed and VehicleOccupancy.of(herc).is_empty(), "exits: on foot, the Raptor empty")
	_expect(_last_message(battle).begins_with("On foot") and s.held.view_shown, "leaving announces on foot; weapon back in view")
	_expect(herc.owner_peer == 0 and is_zero_approx(herc.throttle), "the empty Raptor idles")
	var gap := Vector2(s.global_position.x - herc.global_position.x, s.global_position.z - herc.global_position.z).length() \
		- BoardingRules.make_hull_radius(herc)
	_expect(gap > 0.5 and gap < BoardingRules.HATCH_REACH + 0.5, "out beside the hatch (%.1f m from the hull)" % gap)
	await _shot(battle, "beside_herc")
	var enemy: Herc = battle.vehicles.values().filter(func(h: Herc) -> bool: return h.team == 1 and not (h is Infantry))[0]
	var occ := VehicleOccupancy.of(enemy)
	var back := s.global_position
	_place_beside(s, enemy)
	var check := BoardingRules.make_check(s, enemy, occ)
	_expect(not bool(check.ok) and check.reason == BoardingRules.REASON_OCCUPIED, "an occupied (AI) vehicle refuses: %s" % check.reason)
	s.global_position = back


func _last_message(battle: Battle) -> String:
	var msgs: Array = battle.overlay.hud.messages
	return str(msgs[msgs.size() - 1][0]) if not msgs.is_empty() else ""


func _place_beside(s: Infantry, h: Herc) -> void:
	var right := h.global_basis.x.normalized()
	s.global_position = h.global_position + right * (BoardingRules.make_hull_radius(h) + 1.5) + Vector3.UP * 0.3
	s.velocity = Vector3.ZERO


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()   # deliver it now, not on the next idle frame
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()


func _spawn_parked(battle: Battle, vehicle_id: String, at: Vector3, team := 0) -> Herc:
	var id := battle.spawner.allocate_id()
	battle.send_spawn({"net_id": id, "vehicle": vehicle_id, "team": team, "owner": 0,
		"xf": Transform3D(Basis(), at), "loadout": [], "name": vehicle_id, "ai": {}, "parked": true})
	return battle.vehicles.get(id)


func _check_tribes_boarding(battle: Battle) -> void:
	print("Tribes boarding (touch):")
	var s := battle.player as Infantry
	var base := s.global_position + Vector3(60, 0, 0)
	base.y = MapBuilder.ground_height(battle, base)
	var scout := _spawn_parked(battle, "tribes:SCOUT", base)
	var lapc := _spawn_parked(battle, "tribes:LAPC", base + Vector3(40, 0, 0))
	await _frames(5)
	_expect(VehicleOccupancy.of(lapc).seats.size() == 3 and VehicleOccupancy.of(scout).seats.size() == 1, "LPC pilot + 2, Scout pilot only")
	var heavy := battle.spawn_soldier_for(77, 0, "Heavy", Transform3D(Basis(), base + Vector3(0, 0, 30)))
	heavy.apply_armor("tribes:HEAVY", [])
	_touch(heavy, scout)
	var check := BoardingRules.make_check(heavy, scout, VehicleOccupancy.of(scout))
	_expect(not bool(check.ok) and check.reason == BoardingRules.REASON_T1_LIGHT_ARMOR, "heavy armour can't pilot the Scout: %s" % check.reason)
	_touch(heavy, lapc)
	check = BoardingRules.make_check(heavy, lapc, VehicleOccupancy.of(lapc))
	_expect(bool(check.ok) and int(check.seat) == 1, "heavy armour rides in the LPC as a passenger")
	await _frames(3)
	_expect(heavy.stowed and VehicleOccupancy.of(lapc).seat_of(77) == 1, "touching the LPC boards it (passenger seat 1)")
	battle.occupancy.apply_exit(77, lapc)
	heavy.global_position += Vector3(0, 0, 100)
	_place_near(s, scout, OccupancyHint.TOUCH_HINT_REACH * 0.5)
	await _frames(2)
	_expect(battle.occupancy.make_local_hint() == "Walk into the Scout to board (pilot seat)",
		"near the Scout: boarding hint '%s'" % battle.occupancy.make_local_hint())
	_touch(s, scout)
	await _frames(3)
	_expect(battle.player == scout and VehicleOccupancy.of(scout).pilot() == 1, "light armour touching the Scout takes the pilot seat")
	var exit_hint := "%s / %s: get out of the Scout (pilot seat)" % [OccupancyHint.make_key_text(), OccupancyHint.make_key_text("ascend")]
	_expect(battle.occupancy.make_local_hint() == exit_hint, "in the Scout: exit hint '%s'" % battle.occupancy.make_local_hint())
	var hud := battle.overlay.get_node("InfantryHud") as InfantryHud
	for i in 2:   # the HUD updates its hint in _process: physics frames alone may pass none under load
		await get_tree().process_frame
	_expect(hud.hint == exit_hint and (battle.overlay.cockpit == null or battle.overlay.cockpit.hint == exit_hint),
		"the HUD / cockpit message area carries the Scout's exit hint")
	await _shot(battle, "in_scout")
	_press("vehicle_enter_exit")
	await _frames(3)
	_expect(battle.player == s and not s.stowed, "leaves the Scout with vehicle_enter_exit")
	_touch(s, scout)
	await _frames(3)
	_expect(battle.player == s, "no re-boarding within the remount delay")
	print("Tribes 2 seats:")
	var t2base := base + Vector3(0, 0, -60)
	var wildcat := _spawn_parked(battle, "tribes2:WILDCAT", t2base)
	var beowulf := _spawn_parked(battle, "tribes2:BEOWULF", t2base + Vector3(40, 0, 0))
	var havoc := _spawn_parked(battle, "tribes2:HAVOC", t2base + Vector3(-40, 0, 0))
	await _frames(5)
	var med := battle.spawn_soldier_for(78, 0, "Medium", Transform3D(Basis(), t2base + Vector3(0, 0, 30)))
	med.apply_armor("tribes2:MEDIUM", [])
	heavy.apply_armor("tribes2:HEAVY", [])
	med.global_position += Vector3(0, 0, 100)
	heavy.global_position += Vector3(0, 0, 100)
	_touch(med, wildcat)
	check = BoardingRules.make_check(med, wildcat, VehicleOccupancy.of(wildcat))
	_expect(not bool(check.ok) and check.reason == BoardingRules.REASON_T2_LIGHT_ONLY, "Wildcat is lightOnly: %s" % check.reason)
	_touch(heavy, beowulf)
	check = BoardingRules.make_check(heavy, beowulf, VehicleOccupancy.of(beowulf))
	_expect(not bool(check.ok) and check.reason == BoardingRules.REASON_T2_POSITION, "heavy armour can't take the Beowulf's sitting seats: %s" % check.reason)
	_touch(heavy, havoc)
	check = BoardingRules.make_check(heavy, havoc, VehicleOccupancy.of(havoc))
	_expect(bool(check.ok) and int(check.seat) == 1, "heavy armour rides in the Havoc (seat %d)" % int(check.seat))
	_touch(med, beowulf)
	check = BoardingRules.make_check(med, beowulf, VehicleOccupancy.of(beowulf))
	_expect(bool(check.ok) and int(check.seat) == 0, "medium armour drives the Beowulf")
	for h in [heavy, med]:
		h.global_position += Vector3(0, 0, 200)


## `gap` metres beyond touching `v`, on its right.
func _place_near(s: Infantry, v: Herc, gap: float) -> void:
	s.global_position = v.global_position + Vector3(BoardingRules.make_hull_radius(v) + BoardingRules.TOUCH_MARGIN + gap, 0.3, 0)
	s.velocity = Vector3.ZERO


func _touch(s: Infantry, v: Herc) -> void:
	s.global_position = v.global_position + Vector3(BoardingRules.make_hull_radius(v) + 0.2, 0.3, 0)
	s.velocity = Vector3.ZERO


func _check_destroyed_vehicle_ejects(battle: Battle) -> void:
	print("destroyed vehicle:")
	var s := battle.player as Infantry
	var herc := _player_vehicle(battle)
	_place_beside(s, herc)
	await _seconds(4.5)   # past the Tribes remount delay
	_place_beside(s, herc)
	await _frames(2)
	_press("vehicle_enter_exit")
	await _frames(3)
	_expect(battle.player == herc, "back in the Raptor")
	herc.end_spawn_protection()
	for i in 50:
		if herc.alive:
			herc.apply_hit(1e6, 1e6, null, herc.global_position)
	await _frames(3)
	_expect(not herc.alive and battle.player == s and not s.stowed and s.alive, "the destroyed Raptor throws its pilot out alive")


func _check_stations(battle: Battle) -> void:
	print("stations:")
	var s := battle.player as Infantry
	var stations: TribesStations = battle.get_node("Stations")
	var inv := stations.stations.find(stations.stations.filter(func(st: Dictionary) -> bool: return st.kind == "inventory" and int(st.team) in [-1, 0])[0])
	_expect(inv >= 0, "Raindance has an inventory station for team 0")
	s.global_position = (stations.stations[inv].xf as Transform3D).origin + Vector3.UP * 0.5
	s.velocity = Vector3.ZERO
	await _frames(3)
	_expect(stations.find_station(s) == inv, "standing on the inventory station")
	var menu: StationMenu = battle.find_child("StationMenuLayer", false, false).get_child(0) if battle.find_child("StationMenuLayer", false, false) else null
	_expect(menu != null, "stepping onto it opens the inventory menu")
	await _shot(battle, "inventory_station")
	if menu:
		menu.close()
	stations.apply_inventory(1, "tribes:HEAVY", ["tribes:MORTAR", "tribes:LASER_RIFLE", "tribes:CHAINGUN"])
	await _frames(2)
	_expect(s.armor_id == "tribes:HEAVY" and s.make_loadout() == ["tribes:MORTAR", "tribes:CHAINGUN"],
		"buys heavy armour; the laser rifle (light only) is refused: %s" % [s.make_loadout()])
	var chaingun := s.weapons[1] as InfantryWeapon
	chaingun.ammo = 0
	TribesStations.apply_resupply(s)
	_expect(chaingun.ammo == 20, "an ammo station step adds 20 bullets")
	stations.apply_inventory(1, "tribes:LIGHT", ["tribes:BLASTER", "tribes:CHAINGUN", "tribes:DISC_LAUNCHER"])
	await _frames(2)
	var veh := stations.stations.find(stations.stations.filter(func(st: Dictionary) -> bool: return st.kind == "vehicle" and int(st.team) in [-1, 0])[0])
	s.global_position = (stations.stations[veh].xf as Transform3D).origin + Vector3.UP * 0.5
	await _frames(3)
	var count := battle.vehicles.size()
	stations.apply_vehicle_purchase(1, "tribes:SCOUT", veh)
	await _frames(3)
	_expect(battle.vehicles.size() == count + 1, "the vehicle station puts a Scout on the pad")
	if battle.player != s:
		battle.occupancy.apply_enter_exit(1)   # he walked onto the new Scout: out again
		await _frames(3)
	s.global_position = (stations.stations[inv].xf as Transform3D).origin + Vector3(0, 0.5, 30)
	var menu_layer := battle.find_child("StationMenuLayer", false, false)
	if menu_layer:
		await _shot(battle, "vehicle_station")
		(menu_layer.get_child(0) as StationMenu).close()


func _check_damage_and_respawn(battle: Battle) -> void:
	print("damage and respawn:")
	var s := battle.player as Infantry
	s.end_spawn_protection()
	var enemy: Herc = battle.vehicles.values().filter(func(h: Herc) -> bool: return h.team == 1 and not (h is Infantry))[0]
	s.apply_hit(0.0, 1000.0, enemy)
	_expect(s.alive and is_equal_approx(float(s.components[0].hp), 980.0), "a hit takes health (1980 -> 980)")
	s.apply_hit(600.0, 1500.0, enemy)
	_expect(not s.alive and enemy.kills >= 1, "killed by a Herc weapon; the kill counts")
	await _seconds(BattleRules.RESPAWN_TIME + 0.5)
	_expect(s.alive and s.armor_id == "tribes:LIGHT" and s.weapons.size() == 3, "respawns in light armour with the spawn loadout")


func _check_mission_start(battle: Battle) -> void:
	print("missions start inside:")
	battle.queue_free()
	await _frames(3)
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "mission", "mission_name": BattleSetup.DEFAULT_MISSION, "start": BattleInfantry.START_ON_FOOT}, true)
	var m: Battle = load("res://games/es1/battle.tscn").instantiate()
	m.config = config
	get_tree().root.add_child(m)
	await _frames(SETTLE_FRAMES)
	_expect(m.player != null and not (m.player is Infantry), "a mission starts inside the Herc")
	_expect(m.player != null and VehicleOccupancy.of(m.player).pilot() == 1, "the player's peer is its pilot")
	m.occupancy.apply_enter_exit(1)
	await _frames(3)
	_expect(m.player is Infantry and (m.player as Infantry).armor_id.ends_with("LIGHT"), "getting out makes a light armour soldier")
	var pilots := m.find_children("*", "PlayerPilot", true, false)
	_expect(pilots.size() == 1 and pilots[0] == m.pilot,
		"getting out frees the vehicle's controls: the empty Herc no longer follows the player (%d pilots)" % pilots.size())
	m.queue_free()
	await _frames(2)

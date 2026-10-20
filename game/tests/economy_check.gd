extends Node
## Headless check of the campaign economy and crew (docs/formats/campaign_availability.md sections
## 7-8): the decoded tables (GO.EXE / HERC_INF / WEAPONS / DAMAGE.DAT), build prices and build time,
## repair costs (the original fixed-point formula), weapon fabrication, the battle report (salvage
## tonnage, damage kept, write-offs, a dead wingman replaced, losses), the squad, saves, the saga carry
## and the Hangar screen's economy and Crew tab.
##   godot --headless --audio-driver Dummy --path game res://tests/economy_check.tscn

var _failures := 0


func _ready() -> void:
	_check_tables()
	_check_build()
	_check_repair()
	_check_fabrication()
	_check_squad()
	_check_report()
	_check_es2_vars()
	_check_persistence()
	_check_saga()
	_check_starsiege()
	await _check_hangar_screen()
	print("economy_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _check_tables() -> void:
	print("tables:")
	var es1 := GarageEconomy.make_for_pack("es1")
	var es2 := GarageEconomy.make_for_pack("es2")
	_expect(es1.is_enabled() and es2.is_enabled(), "Earthsiege and Earthsiege 2 have an economy")
	_expect(not GarageEconomy.make_for_pack("starsiege").is_enabled(), "Starsiege has none (inventories)")
	_expect(es1.make_start_pool(1) == 60000, "Earthsiege career starts with 60 t (GO.EXE 0x163ec)")
	var pool := es2.make_start_pool(5)
	_expect(pool >= 100000 and pool <= 110000 and pool % 1000 == 0, "Earthsiege 2: 100000 + rand(11) x 1000 kg (%d)" % pool)
	_expect(es1.make_vehicle_price("es1:ROADRUNN") == 50000 and es1.make_build_missions("es1:COLOSSUS") == 3, "ES1 Roadrunner 50 t, Colossus 3 missions")
	_expect(es2.make_vehicle_price("es2:OUTLAW") == 60000 and es2.make_vehicle_price("es2:OGRE") == 230000, "ES2 Outlaw 60 t, Ogre 230 t (HERC_INF)")
	_expect(es2.make_weapon_price("es2:LAS100") == 8000 and es2.make_weapon_price("es2:MSL6_SARH") == 6000, "ES2 LAS100 8 t, MSL6 rack 6 t (WEAPONS.DAT)")
	var cybrid := es2.make_vehicle_price("es1:APOLLO")
	_expect(cybrid >= 55000 and cybrid <= 230000, "a vehicle outside the table is priced inside its range (%d)" % cybrid)
	_expect((es2.make_pilot_names()[0] as Array) == ["DUGGAN", "BRUTUS", "BUTCHER"], "ES2 pilots from PILOTS.STR")
	_expect((es1.make_pilot_names()[1] as Array)[0] == "RIGGS" and es1.make_squad_max() == 3, "ES1 pilots from NAMES.DAT, three wingmen")
	var state := Es2Tech.make_start_state()
	_expect((state.vehicles as Array).has("es2:TOMAHAWK") and not (state.vehicles as Array).has("es2:OGRE"), "ES2 offers HERC_INF's available types (Tomahawk, not Ogre)")


func _check_build() -> void:
	print("build:")
	var c := Campaign.start(0, 11)
	var g := c.garage
	var ctx := c.availability_context()
	_expect(g.salvage_kg == 60000, "pool 60 t")
	_expect(not g.can_build(ctx, "es1:RAPTOR"), "a Raptor (80 t) is unaffordable")
	var n := g.vehicles.size()
	var i := g.apply_build(ctx, "es1:ROADRUNN")
	_expect(i == n and g.salvage_kg == 10000, "a Roadrunner costs 50 t (pool %d)" % g.salvage_kg)
	_expect(int(g.vehicles[i].build_left) == 1 and not Garage.is_ready(g.vehicles[i]), "it is in the factory for one mission")
	_expect(str(g.make_battle_entry().vehicle) != "" and int(g.make_battle_entry().garage.uid) != int(g.vehicles[i].uid), "the battle takes a built Herc meanwhile")
	GarageReport.apply(g, ctx, {})
	_expect(Garage.is_ready(g.vehicles[i]), "ready after a mission")
	g.apply_select(i)
	var value := GarageEconomy.make_for_pack("es1").make_scrap_value(g.selected_entry())
	g.apply_scrap(ctx)
	_expect(value > 0 and g.salvage_kg == 10000 + value, "scrapping pays its parts' worth (%d)" % value)


func _check_repair() -> void:
	print("repair:")
	var c := CampaignES2.start(1, 12)
	var g := c.garage
	var ctx := c.availability_context()
	var e: Dictionary = g.selected_entry()
	var parts := GarageEconomy.make_for_pack("es2").make_parts(e)
	_expect(int(parts[0].cost) == 4577 and int(parts[1].cost) == 2288, "Outlaw armour part costs fixmul(800, fixmul(w, 60000)) = 4577 / 2288")
	_expect(g.make_repair_cost(ctx, g.selected) == 0, "a pristine Herc costs nothing")
	e.condition = HercCondition.make_fractions(str(e.vehicle), []).map(func(_f): return 0.5)
	var expected := 0
	for part in parts:
		expected += 50 * int(part.cost) / 100
	var cost := g.make_repair_cost(ctx, g.selected)
	_expect(cost == expected and cost > 0, "repair from 50 %% = sum (100 - 50) x cost / 100 (%d)" % cost)
	_expect(HercCondition.make_percent(str(e.vehicle), e.condition) == 50, "condition 50 %")
	g.salvage_kg = cost / 2
	g.apply_repair(ctx, g.selected)
	var pc := HercCondition.make_percent(str(e.vehicle), g.selected_entry().condition)
	_expect(pc > 50 and pc < 100 and g.salvage_kg >= 0, "a short pool repairs to a lower level (%d %%, %d kg left)" % [pc, g.salvage_kg])
	g.salvage_kg = 1000000
	g.apply_repair_all(ctx)
	_expect(g.make_repair_all_cost(ctx) == 0 and g.selected_entry().condition.is_empty(), "Repair all restores every Herc")


func _check_fabrication() -> void:
	print("weapon fabrication:")
	var c := CampaignES2.start(1, 13)
	var g := c.garage
	var ctx := c.availability_context()
	var point := _first_point(g.selected_entry(), "es2:LAS300")
	var old := str(g.selected_entry().loadout[point])
	g.stock.erase("es2:LAS300")
	g.salvage_kg = 100000
	g.apply_arm(ctx, point, "es2:LAS300")
	_expect(g.selected_entry().loadout[point] == "es2:LAS300" and g.salvage_kg == 100000 - 16000, "LAS300 fabricated for 16 t")
	g.apply_arm(ctx, point, "")
	_expect(int(g.stock.get("es2:LAS300", 0)) == 1, "taken off, it waits in the armory")
	g.apply_arm(ctx, point, "es2:LAS300")
	_expect(g.salvage_kg == 84000 and int(g.stock.get("es2:LAS300", 0)) == 0, "put back on for free")
	g.salvage_kg = 0
	g.apply_arm(ctx, point, old)
	_expect(str(g.selected_entry().loadout[point]) == old or old == "", "the old weapon (from the armory) is free")
	_expect(not g.can_arm(ctx, point, "es2:PLAS") or int(g.stock.get("es2:PLAS", 0)) > 0, "nothing fabricated without salvage")


static func _first_point(e: Dictionary, wid: String) -> int:
	var v := Packs.vehicle(str(e.vehicle))
	for i in (e.loadout as Array).size():
		if WeaponFit.fits(Packs.weapon(wid), v, i):
			return i
	return -1


func _check_squad() -> void:
	print("crew and squad:")
	var c := Campaign.start(0, 14)
	var g := c.garage
	_expect(g.crew.pilots.size() == 12 and str(g.crew.pilots[0].name) == "DUGGAN", "twelve pilots, DUGGAN first")
	_expect(SquadRoster.pilot_of(g, g.selected).is_empty() and not SquadRoster.pilot_of(g, 1).is_empty(), "pilots sit in the Hercs besides the player's")
	var squad := SquadRoster.make_squad_config(g, c.wingman_slots({}))
	_expect(squad.size() == 3 and float(squad[0].skill) > 0.0 and str(squad[0].name) == "DUGGAN", "three wingmen with their pilots (%s)" % [squad.map(func(w): return w.name)])
	var expected := {"B0_C0_0A": 0, "B0_C0_1A": 0, "B0_C0_2A": 2, "B0_C0_3A": 1, "B0_C0_5A": 0, "B0_C0_6A": 2}
	for name in expected:
		var slots := c.wingman_slots(MissionCompiler.load_mission(name, PackedInt32Array(), 1))
		_expect(slots == expected[name], "%s takes %d wingmen (MSN group 0 slots), got %d" % [name, expected[name], slots])
	SquadRoster.apply_toggle_wingman(g, 1, 3)
	_expect(SquadRoster.make_squad(g, 3).size() == 2 and not g.squad_auto, "a wingman left at home")
	SquadRoster.apply_assign(g, 2, str(g.crew.pilots[5].id))
	_expect(str(SquadRoster.pilot_of(g, 2).name) == "RAMIREZ", "RAMIREZ assigned to Herc 3")
	SquadRoster.apply_assign(g, 3, str(g.crew.pilots[5].id))
	_expect(SquadRoster.pilot_of(g, 2).is_empty() and str(SquadRoster.pilot_of(g, 3).name) == "RAMIREZ", "a pilot flies one Herc")
	var cands := SquadRoster.make_slot_candidates(g)
	_expect(not cands.is_empty() and not cands.has(g.selected), "slot candidates: eligible Hercs, not the player's")
	SquadRoster.apply_slot(g, 0, 3, int(cands[cands.size() - 1]))
	_expect(SquadRoster.make_slots(g, 3).size() == 3 and SquadRoster.make_slots(g, 3)[0] == int(cands[cands.size() - 1]), "slot 0 takes the chosen Herc")
	SquadRoster.apply_slot(g, 1, 3, int(cands[cands.size() - 1]))
	_expect(SquadRoster.make_slots(g, 3)[0] == -1 and SquadRoster.make_slots(g, 3)[1] == int(cands[cands.size() - 1]), "a Herc sits in one slot")
	var panel := CrewPanel.new(g, 3, "ME")
	_expect(panel.get_child_count() > 6, "the crew panel builds its wingman slot rows")
	panel.free()


func _check_report() -> void:
	print("battle report:")
	var c := Campaign.start(0, 15)
	var g := c.garage
	var player: Dictionary = g.selected_entry()
	var wing_i: int = SquadRoster.make_squad(g, 3)[0]
	var wing: Dictionary = g.vehicles[wing_i]
	var pilot := SquadRoster.pilot_of(g, wing_i)
	var n := g.vehicles.size()
	var pool := g.salvage_kg
	var damaged := HercCondition.make_fractions(str(player.vehicle), []).map(func(_f): return 0.7)
	var result := {"success": true, "salvage": ["es1:ATC50"], "salvage_kg": 12000, "squad": [
		{"uid": int(player.uid), "pilot_id": "", "alive": true, "condition": damaged, "kills": 2},
		{"uid": int(wing.uid), "pilot_id": str(pilot.id), "alive": false, "condition": [], "kills": 1}]}
	var stock := int(g.stock.get("es1:ATC50", 0))
	var summary := c.apply_battle_result(result)
	print("    summary %s" % summary)
	_expect(int(g.stock.get("es1:ATC50", 0)) == stock + 1, "the recovered weapon joins the armory")
	_expect(g.vehicles.size() == n - 1 and g.find_uid(int(wing.uid)) < 0, "the wingman's destroyed Herc is written off")
	_expect(g.salvage_kg > pool + 12000, "salvage tonnage plus the wreck's scrap value (%d -> %d)" % [pool, g.salvage_kg])
	_expect(HercCondition.make_percent(str(player.vehicle), g.selected_entry().condition) == 70, "the player's Herc keeps its damage (70 %)")
	_expect(g.crew.losses() == 1 and str(g.crew.pilot_in_slot(int(pilot.slot)).name) == "%s 1" % pilot.name, "%s killed, replaced by %s 1" % [pilot.name, pilot.name])
	_expect((summary.killed as Array) == [pilot.name], "the debriefing names the loss")


func _check_es2_vars() -> void:
	print("Earthsiege 2 vars:")
	var c := CampaignES2.start(1, 16)
	var g := c.garage
	var wing_i: int = SquadRoster.make_squad(g, 3)[0]
	var wing: Dictionary = g.vehicles[wing_i]
	var pilot := SquadRoster.pilot_of(g, wing_i)
	var vars := c.prepared_vars()
	vars[20] = 2
	var pool := g.salvage_kg
	var result := {"success": true, "vars": vars, "salvage_kg": 0, "squad": [
		{"uid": int(wing.uid), "pilot_id": str(pilot.id), "alive": false, "condition": [], "kills": 0}]}
	c.apply_battle_result(result)
	_expect(g.salvage_kg >= pool + 50000, "mission var 20 pays 25 t per point")
	_expect((result.vars as PackedInt32Array)[9] == 1, "the dead pilot counts in var 9 (Losses)")
	_expect(str(g.crew.pilot_in_slot(int(pilot.slot)).name) == "BRUTUS" or int(pilot.slot) != 0, "DUGGAN's replacement is BRUTUS (PILOTS.STR)")


func _check_persistence() -> void:
	print("persistence:")
	var c := CampaignES2.start(1, 17)
	c.garage.salvage_kg = 4321
	c.garage.vehicles[0].condition = [0.5, 0.25]
	c.garage.crew.apply_death(str(c.garage.crew.pilots[2].id))
	SquadRoster.apply_auto_assign(c.garage)   # as the battle report does: the replacement takes the seat
	SquadRoster.apply_toggle_wingman(c.garage, 1, 3)
	var back := CampaignES2.from_dict(JSON.parse_string(JSON.stringify(c.to_dict())))
	var a := JSON.stringify(back.garage.to_dict())
	var b := JSON.stringify(c.garage.to_dict())
	if a != b:
		print("    saved  %s
    loaded %s" % [b, a])
	_expect(a == b, "pool, condition, crew and squad survive a save")
	var legacy := c.to_dict()
	(legacy.garage as Dictionary).erase("salvage_kg")
	(legacy.garage as Dictionary).erase("crew")
	var old := CampaignES2.from_dict(legacy)
	_expect(old.garage.salvage_kg >= 100000 and old.garage.crew.pilots.size() == 12, "older saves get the start pool and a crew")


func _check_saga() -> void:
	print("saga:")
	var saga := Saga.new()
	saga.stage = 0
	saga.campaign = Campaign.start(0, 18)
	saga.campaign.garage.salvage_kg = 33000
	saga.campaign.garage.crew.pilots[0].kills = 9
	saga.apply_carry(saga.availability_context(), saga.campaign.garage)
	saga.advance()
	var g: Garage = saga.campaign.garage
	_expect(g.salvage_kg >= 33000 + 100000, "the pool carries into Earthsiege 2 (%d)" % g.salvage_kg)
	_expect(int(g.crew.pilot_in_slot(0).kills) == 9, "DUGGAN keeps his record")
	var pilots := g.vehicles.map(func(e): return str(e.pilot_id)).filter(func(p): return p != "")
	var unique := {}
	for p in pilots:
		unique[p] = true
	_expect(unique.size() == pilots.size(), "every pilot flies one Herc after the merge")


func _check_starsiege() -> void:
	print("Starsiege:")
	var ss = load("res://games/starsiege/campaign_provider.gd").start("human")
	var g: Garage = ss.garage
	var e: Dictionary = g.selected_entry()
	var vid := "es1:RAPTOR"
	var n := g.vehicles.size()
	g.apply_build({}, vid)
	_expect(g.vehicles.size() == n + 1 and g.salvage_kg == 0, "building is free (inventories, no salvage)")
	ss.apply_battle_result({"success": true, "squad": [{"uid": int(e.uid), "pilot_id": "", "alive": true, "condition": [0.1], "kills": 0}]})
	_expect(g.find_uid(int(e.uid)) >= 0 and (g.vehicles[g.find_uid(int(e.uid))].condition as Array).is_empty(), "no damage is kept between missions")
	_expect(ss.wingman_slots({}) == 0, "the scripts bring the squadmates")


func _check_hangar_screen() -> void:
	print("Hangar screen:")
	var c := Campaign.start(0, 19)
	var router := HangarRouter.new()
	add_child(router)
	var screen := router.go("hangar", {"garage": c.garage, "availability": c.availability_context, "wingman_slots": 3,
		"heading": "test", "on_done": func() -> void: pass}) as HangarScreen
	await get_tree().process_frame
	screen._build.select_vehicle("es1:RAPTOR")
	screen.call("_update_build_price")
	_expect(screen._build.selected_id() == "es1:RAPTOR" and screen._build_button.disabled, "Build is disabled for a Raptor (80 t) the pool can't pay")
	screen._build.select_vehicle("es1:ROADRUNN")
	screen.call("_update_build_price")
	_expect(not screen._build_button.disabled and screen._build_price.text.contains("50 t"), "Roadrunner: '%s'" % screen._build_price.text)
	_expect(screen._pool.text.contains("60 t"), "pool shown: '%s'" % screen._pool.text)
	c.garage.selected_entry().condition = HercCondition.make_fractions(str(c.garage.selected_entry().vehicle), []).map(func(_f): return 0.6)
	screen.call("_after_change")
	var repair := _find_button(screen, "Repair")
	_expect(repair != null and not repair.disabled, "Repair offered for a damaged Herc")
	var pool := c.garage.salvage_kg
	screen.call("_repair_selected")
	_expect(c.garage.salvage_kg < pool, "repairing costs salvage (%d -> %d)" % [pool, c.garage.salvage_kg])
	screen.show_tab(HangarScreen.TAB_CREW)
	await get_tree().process_frame
	var boxes := _all(screen, []).filter(func(n): return n is CheckBox and n.is_visible_in_tree())
	_expect(boxes.size() == c.garage.vehicles.size() - 1, "Crew tab: a wingman box per Herc besides the player's (%d)" % boxes.size())
	router.queue_free()


static func _find_button(root: Node, text: String) -> Button:
	for n in _all(root, []):
		if n is Button and (n as Button).text == text and (n as Button).is_visible_in_tree():
			return n
	return null


static func _all(n: Node, out: Array) -> Array:
	for c in n.get_children():
		out.append(c)
		_all(c, out)
	return out

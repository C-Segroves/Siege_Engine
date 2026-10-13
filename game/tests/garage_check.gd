extends Node
## Headless check of the campaign garage (Garage, docs/formats/campaign_availability.md section 6):
## the Earthsiege / Earthsiege 2 / Starsiege seeds, build (only what the campaign offers, standard
## weapons as far as the armory allows), scrap (counted weapons back to the armory, never the last
## Herc), arm uses stock / unarm returns it, save round trips through each provider, the saga merging
## a finished stage's garage into the next, and the Hangar screen editing a garage.
##   godot --headless --audio-driver Dummy --path game res://tests/garage_check.tscn

var _failures := 0


func _ready() -> void:
	_check_seeds()
	_check_build_and_scrap()
	_check_arming()
	_check_persistence()
	_check_saga_carry()
	await _check_hangar_screen()
	print("garage_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


static func _vehicle_ids(g: Garage) -> Array:
	return g.vehicles.map(func(e): return str(e.vehicle))


func _check_seeds() -> void:
	print("seeds:")
	var es1 := Campaign.start(0, 1).garage
	print("    es1 %s stock %s" % [_vehicle_ids(es1), es1.stock])
	_expect(_vehicle_ids(es1) == ["es1:ROADRUNN", "es1:ROADRUNN", "es1:GUNSLING", "es1:GUNSLING"], "Earthsiege: CAR_INIT.DAT's 2 Roadrunners + 2 Gunslingers")
	_expect(Garage.make_armed_count(es1.vehicles[0]) == 2 and int(es1.stock.get("es1:LAS100", 0)) == 5, "armed per CAR_INIT, C_ARMORY stock (LAS100 x5)")
	var es2 := CampaignES2.start(1, 1).garage
	print("    es2 %s" % [es2.vehicles.map(func(e): return [e.vehicle, e.loadout])])
	_expect(es2.vehicles.size() == 4 and _vehicle_ids(es2).all(func(id): return id == "es2:OUTLAW"), "Earthsiege 2: HERCS.DAT's four Outlaws")
	_expect(es2.vehicles.all(func(e): return Garage.make_armed_count(e) == 3), "each with its three HERCS.DAT weapons")
	var ss: Garage = load("res://games/starsiege/campaign_provider.gd").start("human").garage
	print("    starsiege %s" % [_vehicle_ids(ss)])
	_expect(_vehicle_ids(ss).has("starsiege:pi_eman"), "Starsiege: the stash's Emancipator")


func _check_build_and_scrap() -> void:
	print("build and scrap:")
	var c := Campaign.start(0, 2)
	var g := c.garage
	g.salvage_kg = 10000000   # the build prices are economy_check's
	var ctx := c.availability_context()
	_expect(g.apply_build(ctx, "es2:OGRE") < 0, "a Herc the campaign doesn't offer can't be built")
	var before := g.vehicles.size()
	var stock_before := g.stock.duplicate()
	var i := g.apply_build(ctx, "es1:RAPTOR")
	_expect(i == before and g.selected == i and g.vehicles.size() == before + 1, "Raptor built and selected")
	var raptor_loadout: Array = Packs.vehicle("es1:RAPTOR").get("loadout", [])
	print("    raptor standard %s -> built %s" % [raptor_loadout, g.selected_entry().loadout])
	_expect(_stock_total(g.stock) <= _stock_total(stock_before), "standard weapons come out of the armory, never from nowhere")
	var counted_on := _counted_mounted(c, g.selected_entry())
	var stock_mid := _stock_total(g.stock)
	g.apply_scrap(c.availability_context())
	_expect(g.vehicles.size() == before and _stock_total(g.stock) == stock_mid + counted_on, "scrap returns the counted weapons (%d)" % counted_on)
	while g.can_scrap():
		g.apply_scrap(c.availability_context())
	_expect(g.vehicles.size() == 1, "the last Herc can't be scrapped")
	for k in Garage.MAX_VEHICLES:
		g.apply_build({}, "es1:RAPTOR")
	_expect(g.vehicles.size() == Garage.MAX_VEHICLES and g.apply_build({}, "es1:RAPTOR") < 0, "the hangar holds %d Hercs" % Garage.MAX_VEHICLES)


static func _stock_total(stock: Dictionary) -> int:
	var n := 0
	for k in stock:
		n += int(stock[k])
	return n


## Counted (not released) weapons on entry `e` under the campaign's context.
static func _counted_mounted(c: Campaign, e: Dictionary) -> int:
	var ctx := c.availability_context()
	var counted := func(w): return str(w) != "" and CampaignAvailability.make_weapon_reason(ctx, str(w)) in [CampaignAvailability.REASON_STOCK, ""]
	return (e.loadout as Array).filter(counted).size()


func _check_arming() -> void:
	print("arming uses stock, unarming returns it:")
	var c := CampaignES2.start(1, 3)
	var g := c.garage
	var ctx := c.availability_context()
	var award := "es2:LAS400"
	var point := _first_fitting_point(g.selected_entry(), award)
	_expect(point >= 0, "an Outlaw hardpoint fits %s" % award)
	_expect(not g.can_arm(ctx, point, award), "not in the armory yet: can't arm")
	c.apply_salvage([award])
	g.apply_arm(c.availability_context(), point, award)
	_expect(g.selected_entry().loadout[point] == award and int(g.stock.get(award, 0)) == 0, "armed: the armory's unit is used")
	g.apply_select(1)
	_expect(not g.can_arm(c.availability_context(), _first_fitting_point(g.selected_entry(), award), award), "the next Herc can't have it too")
	g.apply_select(0)
	g.apply_arm(c.availability_context(), point, "")
	_expect(int(g.stock.get(award, 0)) == 1, "unarmed: back in the armory")
	_expect(not g.can_arm(c.availability_context(), point, "es1:ATC20_NOPE"), "unknown weapons are refused")


static func _first_fitting_point(e: Dictionary, wid: String) -> int:
	var v := Packs.vehicle(str(e.vehicle))
	for i in (e.loadout as Array).size():
		if WeaponFit.fits(Packs.weapon(wid), v, i):
			return i
	return -1


func _check_persistence() -> void:
	print("persistence:")
	var c := Campaign.start(0, 4)
	c.garage.apply_build(c.availability_context(), "es1:RAPTOR")
	c.garage.apply_rename("Lucky")
	SquadRoster.apply_assign(c.garage, c.garage.selected, "p5_0")
	c.apply_salvage(["es1:ATC50"])
	var back := Campaign.from_dict(JSON.parse_string(JSON.stringify(c.to_dict())))
	_expect(JSON.stringify(back.garage.to_dict()) == JSON.stringify(c.garage.to_dict()), "Earthsiege campaign save keeps the garage")
	_expect(str(back.garage.selected_entry().name) == "Lucky" and str(back.garage.selected_entry().pilot_id) == "p5_0", "name and pilot saved")
	var legacy := c.to_dict()
	legacy.erase("garage")
	legacy["armory"] = {"es1:ATC50": 9}
	_expect(int(Campaign.from_dict(legacy).garage.stock.get("es1:ATC50", 0)) == 9, "saves from before the garage keep their armory")
	var e2 := CampaignES2.start(1, 4)
	e2.garage.apply_select(2)
	_expect(CampaignES2.from_dict(JSON.parse_string(JSON.stringify(e2.to_dict()))).garage.selected == 2, "Earthsiege 2 save keeps the garage")
	var prov = load("res://games/starsiege/campaign_provider.gd")
	var ss = prov.start("human")
	ss.garage.apply_build({}, "es1:RAPTOR")
	_expect(prov.restore(JSON.parse_string(JSON.stringify(ss.to_dict()))).garage.vehicles.size() == ss.garage.vehicles.size(), "Starsiege save keeps the garage")
	var career := {"name": "OLD", "hangar": {"hercs": [Garage.make_entry("es1:RAPTOR")], "selected": 0, "armory": {"es1:ATC20": 3}}}
	MissionLaunch.ensure_campaign_state(career)
	var migrated := MissionLaunch.campaign_for(career).garage
	_expect(not career.has("hangar") and _vehicle_ids(migrated) == ["es1:RAPTOR"] and int(migrated.stock.get("es1:ATC20", 0)) == 3,
		"an ES1 shell career's old hangar moves into its campaign garage")


func _check_saga_carry() -> void:
	print("saga carries the garage:")
	var saga := Saga.new()
	saga.stage = 1
	saga.campaign = CampaignES2.start(1, 5)
	saga.campaign.apply_salvage(["es2:LAS400"])
	var es2_hercs: int = saga.campaign.garage.vehicles.size()
	saga.apply_carry(saga.availability_context(), saga.campaign.garage)
	saga.advance()
	_expect(saga.needs_choice() and not (saga.carried.garage as Dictionary).is_empty(), "Starsiege waits for the side; the garage waits with it")
	var waiting := Saga.from_dict(JSON.parse_string(JSON.stringify(saga.to_dict())))
	waiting.choose("human")
	var g: Garage = waiting.campaign.garage
	_expect(_vehicle_ids(g).filter(func(id): return id == "es2:OUTLAW").size() == es2_hercs, "the Outlaws reach Starsiege")
	_expect(int(g.stock.get("es2:LAS400", 0)) == 1 and (waiting.carried.garage as Dictionary).is_empty(), "the armory too, merged once")


func _check_hangar_screen() -> void:
	print("Hangar screen:")
	var c := Campaign.start(0, 6)
	c.garage.salvage_kg = 10000000
	var saves := [0]
	var router := HangarRouter.new()
	add_child(router)
	var screen := router.go("hangar", {"garage": c.garage, "availability": c.availability_context,
		"heading": "test", "on_done": func() -> void: pass, "on_changed": func() -> void: saves[0] += 1}) as HangarScreen
	await get_tree().process_frame
	_expect(screen != null and screen.hangar != null, "opens with the 3D hangar")
	var before := c.garage.vehicles.size()
	screen.call("_select_herc", 2)
	screen._build.select_vehicle("es1:RAPTOR")
	screen.call("_build_selected_type")
	_expect(c.garage.vehicles.size() == before + 1 and saves[0] >= 2, "select + build through the screen, saved each time")
	c.apply_salvage(["es1:ELF"])
	var point := _first_fitting_point(c.garage.selected_entry(), "es1:ELF")
	screen.call("_arm", point, "es1:ELF")
	print("    ELF on point %d: %s, armory %s, status '%s'" % [point, c.garage.selected_entry().loadout, c.garage.stock.get("es1:ELF"), screen.status_text()])
	_expect(c.garage.selected_entry().loadout[point] == "es1:ELF" and int(c.garage.stock.get("es1:ELF", 0)) == 0, "arming through the screen uses the armory unit")
	screen.call("_scrap")
	_expect(c.garage.vehicles.size() == before and int(c.garage.stock.get("es1:ELF", 0)) == 1, "scrap through the screen returns it")
	router.queue_free()

extends Node
## Headless check of campaign availability (docs/formats/campaign_availability.md): arena without
## limits; Earthsiege career start (CAR_INIT Hercs + TECH_0 releases + equivalents only); Earthsiege 2
## tech unlocks (Ogre) and script awards; foreign later-era Hercs only when equivalent; salvage
## add / arm / unarm through the garage; saga carry-over; Starsiege planet inventories (tanks included).
##   godot --headless --audio-driver Dummy --path game res://tests/availability_check.tscn

var _failures := 0


func _ready() -> void:
	_check_arena()
	_check_es1_start()
	_check_es1_progress()
	_check_es2_unlocks()
	_check_foreign_equivalence()
	_check_salvage_stock()
	_check_saga_carry()
	_check_starsiege_inventory()
	_check_cybrid_weapon_rule()
	print("availability_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


static func _ids(offers: Array) -> Array:
	return offers.map(func(o): return str(o.vehicle.id))


static func _reason(offers: Array, vid: String) -> String:
	for o in offers:
		if str(o.vehicle.id) == vid:
			return str(o.reason)
	return ""


func _check_arena() -> void:
	print("arena / skirmish:")
	var all := Packs.pilotable([], "").filter(func(v): return CampaignAvailability.FIELDED_CATEGORIES.has(str(v.get("category", "herc"))))
	_expect(CampaignAvailability.offered_vehicles({}).size() == all.size(), "every enabled Herc/tank/armed vehicle offered (%d)" % all.size())
	var limited := CampaignAvailability.offered_weapons({}).filter(func(o): return o.count != CampaignAvailability.UNLIMITED)
	_expect(limited.is_empty(), "every weapon unlimited")


func _check_es1_start() -> void:
	print("Earthsiege career start:")
	var ctx := Es1Tech.make_context(0, true, Es1Tech.make_start_armory())
	var offers := CampaignAvailability.offered_vehicles(ctx)
	var native := _ids(offers).filter(func(id): return str(id).begins_with("es1:"))
	print("    native: ", native)
	native.sort()   # Roadrunner and Gunslinger weigh the same: their order is not defined
	_expect(native == ["es1:GUNSLING", "es1:RAPTOR", "es1:ROADRUNN"], "native = the TECH_0 start types")
	var older := offers.filter(func(o): return o.reason == CampaignAvailability.REASON_OLDER)
	_expect(older.is_empty(), "no older designs before Earthsiege")
	var best := Packs.combat_rating(Packs.vehicle("es1:RAPTOR"))
	for o in offers:
		if not str(o.vehicle.id).begins_with("es1:"):
			print("    %-24s %.2f  %s" % [o.vehicle.id, Packs.combat_rating(o.vehicle), o.reason])
	_expect(offers.all(func(o): return str(o.vehicle.id).begins_with("es1:") or str(o.reason).begins_with("equivalent to")),
		"foreign entries are equivalents (best native rating %.2f)" % best)
	_expect(CampaignAvailability.make_weapon_count(ctx, "es1:LAS100") == CampaignAvailability.UNLIMITED, "LAS100 released")
	_expect(CampaignAvailability.make_weapon_count(ctx, "es1:MLRS6_SARH") == CampaignAvailability.UNLIMITED, "MLRS6 rack released (by base id)")
	_expect(CampaignAvailability.make_weapon_reason(ctx, "es1:PBEAM") == "", "PBEAM not released yet")
	_expect(CampaignAvailability.make_weapon_reason(ctx, "es1:GREN") == "", "GREN never released")


func _check_es1_progress() -> void:
	print("Earthsiege career progress (TECH_0.DAT):")
	var at8 := Es1Tech.make_released_vehicles(8, true)
	var at8_bad := Es1Tech.make_released_vehicles(8, false)
	_expect(at8.has("es1:TOMAHAWK") and not at8_bad.has("es1:TOMAHAWK"), "Tomahawk early at 8 with good standing only")
	_expect(Es1Tech.make_released_vehicles(9, false).has("es1:TOMAHAWK"), "Tomahawk at 9 regardless")
	_expect(Es1Tech.make_released_vehicles(31, false).has("es1:COLOSSUS"), "Colossus by mission 31")
	_expect(Es1Tech.make_released_weapons(14, false).has("es1:PBEAM"), "PBEAM by mission 14")


func _check_es2_unlocks() -> void:
	print("Earthsiege 2 unlocks:")
	var c := CampaignES2.start(1, 7)
	var atc50_before := int(c.garage.stock.get("es2:ATC50", 0))   # WEAPONS.DAT's starting inventory
	var before := _ids(CampaignAvailability.offered_vehicles(c.availability_context()))
	_expect(before.has("es2:OUTLAW") and not before.has("es2:OGRE"), "start: Outlaw (HERCS.DAT), no Ogre")
	var vars := c.prepared_vars()
	vars[62] = 2
	vars[22] = 1
	c.record_result(true, vars)
	var ctx := c.availability_context()
	var offers := CampaignAvailability.offered_vehicles(ctx)
	_expect(_reason(offers, "es2:OGRE") == CampaignAvailability.REASON_UNLOCKED, "Ogre unlocked by var62 == 2")
	_expect(c.mission_vars[62] == 0, "tech var reset")
	_expect(int(ctx.salvage_stock.get("es2:ATC50", 0)) == atc50_before + 1, "var22 award -> one more ATC50 in stock")
	_expect(_reason(offers, "es1:RAPTOR") == CampaignAvailability.REASON_OLDER, "Earthsiege Raptor = older design")
	_expect(CampaignAvailability.make_weapon_reason(ctx, "es2:LAS400") == "", "LAS400 still locked")
	var back := CampaignES2.from_dict(JSON.parse_string(JSON.stringify(c.to_dict())))
	_expect((back.unlocks.vehicles as Array).has("es2:OGRE"), "unlocks survive a save")


func _check_foreign_equivalence() -> void:
	print("foreign later-era Hercs only when equivalent:")
	var ctx := Es1Tech.make_context(0, true, {})
	var best := Packs.combat_rating(Packs.vehicle("es1:RAPTOR"))
	var wrong := 0
	for v in Packs.pilotable([], "herc"):
		if str(v.pack) == "es1" or CombatRating.vehicle_kind(v) != CombatRating.KIND_HERC:
			continue
		var offered := CampaignAvailability.is_vehicle_offered(ctx, str(v.id))
		if offered != (Packs.combat_rating(v) <= best + CampaignAvailability.RATING_TOLERANCE):
			wrong += 1
	_expect(wrong == 0, "offered exactly when rated <= best native (Raptor %.2f)" % best)
	_expect(not CampaignAvailability.is_vehicle_offered(ctx, "es2:OGRE"), "Ogre (stronger) not offered at the ES1 start")
	var tanks := CampaignAvailability.offered_vehicles(ctx).filter(func(o): return CombatRating.vehicle_kind(o.vehicle) == "tank")
	var late := Es1Tech.make_context(31, true, {})
	var late_tanks := CampaignAvailability.offered_vehicles(late).filter(func(o): return CombatRating.vehicle_kind(o.vehicle) == "tank")
	print("    tanks at start %d, after mission 31 %d" % [tanks.size(), late_tanks.size()])
	_expect(late_tanks.size() > 0 and late_tanks.size() >= tanks.size(), "tanks stay available, more as the campaign goes on")


func _check_salvage_stock() -> void:
	print("salvage stock: add, arm, unarm (Earthsiege campaign garage):")
	var c := Campaign.start(0, 5)
	var g := c.garage
	var point := _large_point(g.selected_entry())
	_expect(point >= 0, "selected Herc has a large hardpoint")
	var v := Packs.vehicle(str(g.selected_entry().vehicle))
	var loot := _make_locked_weapon(c.availability_context(), int(WeaponFit.hardpoint_masks(v)[point]))
	print("    salvaged weapon: ", loot)
	_expect(loot != "", "a later-era weapon the career has no access to")
	_expect(not g.can_arm(c.availability_context(), point, loot), "can't be armed before salvage")
	c.apply_salvage([loot, loot])
	_expect(CampaignAvailability.make_weapon_count(c.availability_context(), loot) == 2, "two salvaged units in stock")
	g.apply_arm(c.availability_context(), point, loot)
	_expect(int(g.stock.get(loot, 0)) == 1 and g.selected_entry().loadout[point] == loot, "arming uses one")
	g.apply_arm(c.availability_context(), point, "")
	_expect(int(g.stock.get(loot, 0)) == 2, "unarming returns it")
	var las := int(g.stock.get("es1:LAS100", 0))
	g.apply_arm(c.availability_context(), point, "es1:LAS100")
	_expect(int(g.stock.get("es1:LAS100", 0)) == las, "released weapons are unlimited (stock untouched)")
	g.stock[loot] = 1
	g.apply_arm(c.availability_context(), point, loot)
	g.apply_select(g.selected + 1)
	var other := _large_point(g.selected_entry())
	_expect(other >= 0 and not g.can_arm(c.availability_context(), other, loot), "a 1-unit stock can't go on two Hercs")
	_expect(BattleSalvage.is_component_destroyed([{"name": "WEAPON 2", "hp": 0.0}], "WEAPON 2")
		and not BattleSalvage.is_component_destroyed([{"name": "WEAPON 2", "hp": 1.0}], "WEAPON 2"), "destroyed weapon components are not salvaged")


## A foreign (non-Cybrid) weapon fitting `mask` that `ctx` doesn't offer (stronger than anything unlocked).
static func _make_locked_weapon(ctx: Dictionary, mask: int) -> String:
	for w in Packs.weapons_for_mask(mask, false):
		if str(w.pack) != "es1" and CampaignAvailability.make_weapon_reason(ctx, str(w.id)) == "":
			return str(w.id)
	return ""


static func _large_point(e: Dictionary) -> int:
	var masks := WeaponFit.hardpoint_masks(Packs.vehicle(str(e.get("vehicle", ""))))
	for i in masks.size():
		if int(masks[i]) >= 31:
			return i
	return -1


func _check_saga_carry() -> void:
	print("saga carry-over:")
	var saga := Saga.new()
	saga.stage = 0
	saga.campaign = Campaign.start(0, 3)
	saga.campaign.apply_salvage(["starsiege:BLAS"])
	var es1_hercs: int = saga.campaign.garage.vehicles.size()
	saga.apply_carry(saga.availability_context(), saga.campaign.garage)
	saga.advance()
	_expect(saga.campaign is CampaignES2, "next stage is Earthsiege 2")
	var ctx := saga.availability_context()
	var offers := CampaignAvailability.offered_vehicles(ctx)
	_expect(_reason(offers, "es1:RAPTOR") == CampaignAvailability.REASON_CARRIED, "Earthsiege Hercs carried over")
	_expect(CampaignAvailability.make_weapon_count(ctx, "starsiege:BLAS") == 1, "salvage stock carried over (garage armory)")
	var g: Garage = saga.campaign.garage
	_expect(g.vehicles.size() == Es2Tech.make_start_garage().vehicles.size() + es1_hercs, "the Earthsiege garage's Hercs joined the ES2 garage")
	var back := Saga.from_dict(JSON.parse_string(JSON.stringify(saga.to_dict())))
	_expect((back.carried.vehicles as Array).has("es1:RAPTOR"), "carry-over survives a save")
	_expect((back.campaign.garage as Garage).vehicles.size() == g.vehicles.size(), "merged garage survives a save")


func _check_starsiege_inventory() -> void:
	print("Starsiege planet inventories:")
	var prov = load("res://games/starsiege/campaign_provider.gd")
	var c = prov.start("human")
	var ctx: Dictionary = c.availability_context()
	print("    planet %s vehicles %s" % [c.current_planet(), ctx.unlocked_vehicles])
	_expect((ctx.unlocked_vehicles as Array).has("starsiege:pi_eman"), "starts with the stash Emancipator")
	_expect(not (ctx.unlocked_vehicles as Array).has("starsiege:rb_aven"), "no Avenger yet")
	SSInventory.apply_calls(c.inventory, [["inventoryvehicleadjust", "mars", 31, 1]])
	var after: Dictionary = c.availability_context()
	_expect(_reason(CampaignAvailability.offered_vehicles(after), "starsiege:rb_aven") == CampaignAvailability.REASON_UNLOCKED,
		"HA1's Avenger tank offered after updatePlanetInventory")
	_expect(CampaignAvailability.make_weapon_count(after, "starsiege:LAS") == 2, "Mars stocks two lasers")
	c.apply_salvage(["starsiege:PBW"])
	_expect(CampaignAvailability.make_weapon_count(c.availability_context(), "starsiege:PBW") == 1, "salvage goes to the stash")


func _check_cybrid_weapon_rule() -> void:
	print("cybrid_weapons_on_hercs by match mode:")
	var cybrid_only := Packs.weapons.values().filter(func(w): return w.get("cybrid_only", false))
	_expect(not cybrid_only.is_empty(), "the catalog has Cybrid-only weapons")
	var wid := str(cybrid_only[0].id)
	for mode in ["skirmish", "vs"]:
		_expect(CampaignAvailability.allows_cybrid_weapons(CampaignAvailability.make_open_context(mode), "herc"),
			"%s: Cybrid weapons on Hercs" % mode)
	for mode in ["coop", "campaign"]:
		_expect(not CampaignAvailability.allows_cybrid_weapons(CampaignAvailability.make_open_context(mode), "herc"),
			"%s: Cybrid weapons stay on Cybrids" % mode)
	_expect(CampaignAvailability.allows_cybrid_weapons({}, "cybrid"), "Cybrids always mount them")
	var campaign := Es1Tech.make_context(31, true, {wid: 1})
	_expect(CampaignAvailability.offered_weapons(campaign).all(func(o): return str(o.weapon.id) != wid),
		"campaign: %s not offered to a Herc even in stock" % wid)
	var editor := LoadoutEditor.new()
	var herc := _herc_with_mask(WeaponFit.weapon_mask(cybrid_only[0]))
	editor.setup(herc, [], CampaignAvailability.make_open_context("vs"))
	var vs_has := _editor_offers(editor, wid)
	editor.setup(herc, [], CampaignAvailability.make_open_context("coop"))
	var coop_has := _editor_offers(editor, wid)
	editor.free()
	_expect(vs_has and not coop_has, "loadout editor on %s: versus lists %s, co-op doesn't" % [herc, wid])


static func _herc_with_mask(mask: int) -> String:
	for v in Packs.pilotable([], "herc"):
		if WeaponFit.hardpoint_masks(v).any(func(m): return int(m) >= mask):
			return str(v.id)
	return ""


static func _editor_offers(editor: LoadoutEditor, wid: String) -> bool:
	for ids in editor._choices:
		if (ids as Array).has(wid):
			return true
	return false

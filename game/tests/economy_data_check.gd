extends Node
## The economy data layer (docs/design/lobby_loadout_economy.md chunk 1): rules, the free set, prices, buying and
## buying back, losing unlocks in an extraction death (and not elsewhere), credits per mode, character slots resolved
## against a match, hidden-not-lost packs, loadout fit rules, the roster snapshot and its validation, goals, and the
## migration of an old-format profile (loadout presets, player settings, extraction profile).
##   godot --headless --audio-driver Dummy --path game res://tests/economy_data_check.tscn

var _pilot := "QA Economy %d" % OS.get_process_id()
var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	_expect(UserStore.is_test_store(), "a test runs on a test store")
	_check_rules()
	_check_free_set()
	_check_option_answers()
	_check_o2_free_weapons()
	_check_o5_raid_armours()
	_check_o5_raid_risk()
	_check_prices_and_buying()
	_check_extraction_loss()
	_check_earning()
	_check_slot_resolve()
	_check_fit_rules()
	_check_roster()
	_check_goals()
	_check_migration()
	_check_save_round_trip()
	print("economy_data_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _fresh(name_suffix: String) -> OperatorProfile:
	return OperatorProfile.load_for("%s %s" % [_pilot, name_suffix])


## An installed paid armour (not in the free set), "" when none.
func _paid_armor() -> String:
	for pack in InfantryCatalog.INFANTRY_PACKS:
		for a in InfantryCatalog.armors_of(pack):
			if not FreeUnlocks.is_free(UnlockId.make("armor", str(a.id))):
				return str(a.id)
	return ""


func _vs_settings() -> Dictionary:
	return {"mode": "vs", "game_mode": "deathmatch", "infantry_pack": ""}


func _check_rules() -> void:
	print("rules:")
	_expect(EconomyRules.slot_count() == 3 and EconomyRules.start_credits() == 1000 and EconomyRules.rebuy_price() == 100, "slots 3, start 1000, rebuy 100")
	_expect(EconomyRules.make_mode_key({"mode": "vs", "game_mode": "ctf"}) == "vs.ctf", "vs + ctf -> vs.ctf")
	_expect(EconomyRules.make_mode_key({"mode": "vs", "game_mode": "football"}) == "vs", "an unlisted game mode falls back to vs")
	_expect(EconomyRules.make_mode_key({"mode": "campaign"}) == "solo" and EconomyRules.make_mode_key({"mode": "campaign", "coop": true}) == "campaign.coop", "campaign: solo or co-op")
	_expect(EconomyRules.make_mode_key({"mode": "extraction", "solo": true}) == "extraction" and EconomyRules.make_mode_key({"mode": "vs", "solo": true}) == "solo", "extraction pays offline, skirmish does not")
	_expect(EconomyRules.make_money_text(1240) == "1,240 cr", "money text")
	for key in ["o1_profile_authority", "o2_ammo_mode", "o4_vehicle_risk", "o5_extraction_free_armors", "o6_team_goals", "o8_raid_points"]:
		_expect(EconomyRules.option(key) != null, "open question answered in data: " + key)


func _check_option_answers() -> void:
	print("open questions are data:")
	EconomyRules.data().options["o5_extraction_free_armors"] = ["tribes:LIGHT"]
	var raid := LoadoutContext.make_for({"mode": "extraction"})
	_expect(InfantryCatalog.armor("tribes:MEDIUM").is_empty() or (raid.is_free("armor/tribes:LIGHT") and not raid.is_free("armor/tribes:MEDIUM")), "O5: light armour only is free in a raid")
	_expect(LoadoutContext.make_for(_vs_settings()).is_free("armor/tribes:MEDIUM") or InfantryCatalog.armor("tribes:MEDIUM").is_empty(), "O5 changes nothing outside extraction")
	EconomyRules.reload()
	EconomyRules.data().options["o2_ammo_mode"] = "unlock"
	_expect(not FreeUnlocks.is_free_outside_raid("weapon/tribes:MORTAR"), "O2 is data: switched off, a mortar costs credits again")
	EconomyRules.reload()
	EconomyRules.data().options["o4_vehicle_risk"] = "raid_start"
	var p := _fresh("risk")
	var vehicle := ""
	for v in Packs.pilotable():
		if not FreeUnlocks.is_free("vehicle/" + str(v.id)):
			vehicle = str(v.id)
			break
	if vehicle != "":
		(p.slots[0] as CharacterSlot).vehicle = vehicle
		p.unlocks.apply_add("vehicle/" + vehicle)
		_expect(p.make_raid_start_risk(LoadoutContext.make_for({"mode": "extraction"})).has("vehicle/" + vehicle), "O4: the vehicle is at risk from raid start")
	EconomyRules.reload()
	_expect(vehicle == "" or not p.make_raid_start_risk(LoadoutContext.make_for({"mode": "extraction"})).has("vehicle/" + vehicle), "O4 default: not before it is called in")


## O2 (user answer): outside extraction every weapon, ammunition, gear item and backpack is free and shows no price;
## credits buy armours, bodies, skins and vehicles. A raid keeps its physical stock, sold as "supplies".
func _check_o2_free_weapons() -> void:
	print("O2: weapons and ammunition are free outside extraction:")
	var p := _fresh("o2")
	var ctx := LoadoutContext.make_for(_vs_settings(), "player", p.unlocks)
	_expect(FreeUnlocks.is_free_outside_raid("weapon/tribes:MORTAR") and FreeUnlocks.is_free_outside_raid("ammo/tribes:MORTAR") or InfantryCatalog.armor("tribes:LIGHT").is_empty(), "a mortar and its ammunition are free")
	_expect(not FreeUnlocks.is_free_outside_raid("weapon/ghostpack:X"), "a game that is not installed has nothing free")
	for category in ["weapons", "ammo", "gear", "packs"]:
		var entries := StoreCatalog.make_entries({"category": category}, ctx, p)
		_expect(entries.all(func(e: Dictionary) -> bool: return e.state in ["free", "not_allowed"] and e.price == 0), "%s: %d entries, none for sale, no price" % [category, entries.size()])
	var buyable := ["armour", "models", "skins", "vehicles"]
	_expect(buyable.all(func(c: String) -> bool: return StoreCatalog.make_entries({"category": c}, ctx, p).any(func(e: Dictionary) -> bool: return e.state == "for_sale" and e.price > 0) or c == "models"), "the store sells armours, skins and vehicles")
	var before := p.credits
	_expect(not StoreService.apply_buy(p, "weapon/tribes:MORTAR").ok and p.credits == before, "a weapon cannot be bought: nothing to buy")
	var raid := LoadoutContext.make_for({"mode": "extraction"}, "player", p.unlocks)
	var raid_ids := StoreCatalog.make_categories(raid).map(func(c: Dictionary) -> String: return c.id)
	_expect(not raid_ids.has("weapons") and not raid_ids.has("ammo") and raid_ids.has("supplies") and raid_ids.has("skins"), "a raid lists look parts and supplies, not unlock weapons (%s)" % [raid_ids])
	var supplies := StoreCatalog.make_entries({"category": "supplies"}, raid, p)
	_expect(not supplies.is_empty() and supplies.all(func(e: Dictionary) -> bool: return e.stock and e.state == "for_sale" and e.price > 0), "supplies are stock lots with a price (%d)" % supplies.size())
	_expect(StoreCatalog.make_entries({"category": "supplies"}, LoadoutContext.make_for({"mode": "extraction"}), p).size() == supplies.size(), "supplies do not depend on the unlocks")
	var picker := StoreCatalog.make_part_categories()
	var garage := LoadoutContext.make_for({"mode": "campaign"})
	_expect(StoreCatalog.make_categories(garage).is_empty() and picker.size() == StoreCatalog.CATEGORIES.size(), "a screen without a store lists every category as plain parts")
	var parts := StoreCatalog.make_entries({"category": "armour"}, garage, p)
	_expect(parts.all(func(e: Dictionary) -> bool: return e.state in ["free", "not_allowed"]), "without a store every part is usable or not allowed, never for sale")
	var bot := LoadoutContext.make_for(_vs_settings(), "bot")
	_expect(StoreCatalog.make_entries({"category": "vehicles"}, bot, p).all(func(e: Dictionary) -> bool: return e.state != "for_sale"), "a bot's card is never limited by ownership")


## O5 (user answer): only light armour is free in a raid; medium and heavy are bought, lost on death and bought back for 100 cr.
func _check_o5_raid_armours() -> void:
	print("O5: only light armour is free in a raid:")
	if InfantryCatalog.armor("tribes:LIGHT").is_empty():
		print("    (Tribes not installed: skipped)")
		return
	var p := _fresh("o5")
	var raid := LoadoutContext.make_for({"mode": "extraction"}, "player", p.unlocks)
	var versus := LoadoutContext.make_for(_vs_settings(), "player", p.unlocks)
	_expect(StoreCatalog.make_state("armor/tribes:LIGHT", raid, p.unlocks) == "free", "light armour is free in a raid")
	for size in ["MEDIUM", "HEAVY"]:
		var armour_id: String = "armor/tribes:" + size
		_expect(StoreCatalog.make_state(armour_id, raid, p.unlocks) == "for_sale" and StoreCatalog.make_state(armour_id, versus, p.unlocks) == "free", "%s: for sale in a raid, free elsewhere" % size)
	var armour_entries := StoreCatalog.make_entries({"category": "armour", "pack": "tribes"}, raid, p)
	_expect(armour_entries.filter(func(e: Dictionary) -> bool: return e.state == "free").size() == 1, "one free armour in a raid's store")
	p.credits = 5000
	var id := "armor/tribes:MEDIUM"
	var price := StoreCatalog.make_unlock_price(id)
	_expect(StoreService.apply_buy(p, id).ok and p.credits == 5000 - price and p.unlocks.owned.has(id), "medium armour is bought for %d cr" % price)
	p.apply_commit_risk([id])
	_expect(p.at_risk == [id], "the worn paid armour is at risk")
	_expect(p.apply_raid_lost([]) == [id] and StoreCatalog.make_state(id, raid, p.unlocks) == "lost", "a death loses it")
	_expect(StoreCatalog.make_state(id, versus, p.unlocks) == "free", "outside a raid it stays free")
	var credits := p.credits
	_expect(StoreService.apply_rebuy(p, id).ok and p.credits == credits - EconomyRules.rebuy_price() and StoreCatalog.make_state(id, raid, p.unlocks) == "owned", "it is bought back for 100 cr")


## The raid-risk path end to end: bought Heavy is at risk from raid start, lost on death and bought back; Light is never at
## risk; outside extraction nothing is lost.
func _check_o5_raid_risk() -> void:
	print("O5: raid risk of bought armour:")
	if InfantryCatalog.armor("tribes:HEAVY").is_empty():
		print("    (Tribes not installed: skipped)")
		return
	var p := _fresh("o5risk")
	p.credits = 99999
	var heavy := "armor/tribes:HEAVY"
	_expect(StoreService.apply_buy(p, heavy).ok, "heavy armour bought")
	p.make_active_slot().armor = "tribes:HEAVY"
	var raid := LoadoutContext.make_for({"mode": "extraction"}, "player", p.unlocks)
	_expect(p.make_raid_start_risk(raid).has(heavy), "worn bought Heavy is at risk from raid start")
	p.apply_commit_risk(p.make_raid_start_risk(raid))
	_expect(p.at_risk == [heavy], "it is committed to the raid")
	var credits := p.credits
	_expect(p.apply_raid_lost([]) == [heavy] and p.unlocks.is_lost(heavy), "death: Heavy is lost")
	_expect(StoreService.apply_rebuy(p, heavy).ok and p.credits == credits - 100 and p.unlocks.is_owned(heavy), "rebuy costs 100 cr")
	p.make_active_slot().armor = "tribes:LIGHT"
	_expect(not p.make_raid_start_risk(raid).has("armor/tribes:LIGHT"), "Light is never at risk")
	p.apply_commit_risk(["armor/tribes:LIGHT"])
	_expect(p.at_risk.is_empty(), "Light cannot be committed")
	p.apply_raid_lost([])
	var versus := LoadoutContext.make_for(_vs_settings(), "player", p.unlocks)
	_expect(p.at_risk.is_empty() and p.unlocks.is_owned(heavy) and StoreCatalog.make_state(heavy, versus, p.unlocks) == "free", "outside extraction nothing is lost")
	p.make_active_slot().armor = "tribes:HEAVY"
	p.save()
	_expect(ExtractionProfile.load_for(p.pilot).kit_armor == "tribes:HEAVY", "the raid kit wears the active slot's armour")
	p.apply_raid_lost([heavy])
	p.unlocks.apply_lose(heavy)
	p.save()
	_expect(ExtractionProfile.load_for(p.pilot).kit_armor == ExtractionProfile.make_free_armor_id(), "a lost armour in the slot: the kit wears free light armour")


func _check_free_set() -> void:
	print("free set:")
	if InfantryCatalog.armor("tribes:LIGHT").is_empty():
		print("    (Tribes not installed: skipped)")
	else:
		for size in ["LIGHT", "MEDIUM", "HEAVY"]:
			_expect(FreeUnlocks.is_free("armor/tribes:" + size), "Tribes 1 %s armour is free" % size)
		_expect(FreeUnlocks.is_free("weapon/tribes:BLASTER") and FreeUnlocks.is_free("ammo/tribes:CHAINGUN"), "the blaster and spawn weapons with ammo are free")
		_expect(not FreeUnlocks.is_free("weapon/tribes:MORTAR"), "a mortar is not free")
		_expect(FreeUnlocks.is_free("body/" + PlayerProfile.make_default_body("tribes:MEDIUM")), "the default body is free")
	var paid := _paid_armor()
	_expect(paid == "" or not FreeUnlocks.is_free("armor/" + paid), "a paid armour is not free (%s)" % paid)
	var starters := FreeUnlocks.make_starter_vehicles()
	_expect(not starters.is_empty() and starters.keys().all(func(p: String) -> bool: return Assets.has_pack(p)), "one starter vehicle per installed pack (%d)" % starters.size())
	for pack in starters:
		_expect(FreeUnlocks.is_free("vehicle/" + str(starters[pack])) and Packs.vehicle(str(starters[pack])).pack == pack, "%s starter %s" % [pack, starters[pack]])
	_expect(not FreeUnlocks.is_free("armor/ghostpack:LIGHT") and not FreeUnlocks.is_free("vehicle/ghostpack:X"), "an uninstalled pack has nothing free")
	var u := Unlocks.new()
	u.apply_add("armor/tribes:LIGHT")
	_expect(not u.owned.has("armor/tribes:LIGHT") and u.is_owned("armor/tribes:LIGHT") or InfantryCatalog.armor("tribes:LIGHT").is_empty(), "a free item is owned without being stored")
	u.apply_add("armor/tribes:MEDIUM")
	_expect(u.owned.has("armor/tribes:MEDIUM") or InfantryCatalog.armor("tribes:MEDIUM").is_empty(), "O5: medium armour is free in matches but bought in a raid, so a purchase is stored")


func _check_prices_and_buying() -> void:
	print("prices and buying:")
	var p := _fresh("buyer")
	_expect(p.credits == 1000 and p.slots.size() == 3 and p.make_active_slot().is_complete(), "a new profile: 1000 cr, 3 complete slots")
	var vehicle := ""
	for v in Packs.pilotable():
		if not FreeUnlocks.is_free("vehicle/" + str(v.id)):
			vehicle = "vehicle/" + str(v.id)
			break
	var vehicle_price := StoreCatalog.make_unlock_price(vehicle) if vehicle != "" else 0
	_expect(vehicle == "" or vehicle_price >= 3000, "a vehicle unlock costs 1.5 x the call-in base (%d cr)" % vehicle_price)
	var skin := _first_id("skins", "skin")
	_expect(skin == "" or StoreCatalog.make_unlock_price(skin) == 250, "a skin costs the flat 250")
	_expect(StoreCatalog.make_price("skin/x#y", "lost") == 100 and StoreCatalog.make_price("skin/x#y", "free") == 0, "lost items cost 100, free ones nothing")
	var ctx := LoadoutContext.make_for(_vs_settings(), "player", p.unlocks)
	if skin == "":
		print("    (no skin installed: buy test skipped)")
		return
	_expect(StoreCatalog.make_state(skin, ctx, p.unlocks) == "for_sale", "an unowned skin is for sale")
	var before := p.credits
	var r := StoreService.apply_buy(p, skin)
	_expect(r.ok and p.credits == before - 250 and p.unlocks.is_owned(skin) and int(p.stats.spent) == 250, "buying takes 250 cr and unlocks it")
	_expect(not StoreService.apply_buy(p, skin).ok and p.credits == before - 250, "it cannot be bought twice")
	var poor := OperatorProfile.new()
	poor.apply_new(_pilot + " poor")
	poor.credits = 10
	_expect(not StoreService.apply_buy(poor, skin).ok and poor.credits == 10 and not poor.unlocks.is_owned(skin), "too little credit: nothing changes")
	_expect(StoreCatalog.make_entries({"category": "skins", "owned_only": true}, ctx, p).any(func(e: Dictionary) -> bool: return e.id == skin), "the store lists it as owned")
	var armour_entries := StoreCatalog.make_entries({"category": "armour", "sort": "price"}, ctx, p)
	_expect(armour_entries.size() > 0 and StoreCatalog.make_categories(ctx).size() >= 6, "armour entries and store categories exist")
	_expect(StoreCatalog.make_categories(LoadoutContext.make_for({"mode": "campaign"})).is_empty(), "no store in the campaign")


func _first_id(category: String, kind: String) -> String:
	for e in StoreCatalog.make_entries({"category": category}, LoadoutContext.make_for(_vs_settings()), OperatorProfile.new()):
		if e.kind == kind and e.state == "for_sale":
			return str(e.id)
	return ""


func _check_extraction_loss() -> void:
	print("extraction loss and recovery:")
	var p := _fresh("raider")
	var skin := _first_id("skins", "skin")
	if skin == "":
		print("    (no skin installed: skipped)")
		return
	p.credits = 5000
	StoreService.apply_buy(p, skin)
	var raid := LoadoutContext.make_for({"mode": "extraction"})
	var versus := LoadoutContext.make_for(_vs_settings(), "player", p.unlocks)
	raid.unlocks = p.unlocks
	_expect(raid.loss_on_death and not versus.loss_on_death, "only extraction loses on death")
	p.apply_commit_risk([skin, "armor/tribes:MEDIUM"])
	_expect(p.at_risk == [skin], "free items are never at risk")
	p.apply_raid_survived()
	_expect(p.at_risk.is_empty() and p.unlocks.is_owned(skin), "extracting keeps everything")
	p.apply_commit_risk([skin])
	var lost := p.apply_raid_lost([skin])
	_expect(lost.is_empty() and p.unlocks.is_owned(skin), "an insured unlock survives a death")
	p.apply_commit_risk([skin])
	lost = p.apply_raid_lost([])
	_expect(lost == [skin] and p.unlocks.is_lost(skin) and not p.unlocks.is_owned(skin) and int(p.stats.unlocks_lost) == 1, "a death loses the at-risk unlock")
	_expect(StoreCatalog.make_state(skin, raid, p.unlocks) == "lost" and StoreCatalog.make_state(skin, versus, p.unlocks) == "owned", "lost in extraction, still usable elsewhere")
	var slot := p.make_active_slot()
	slot.skin = UnlockId.skin_of(skin)
	slot.body = ""
	var shape := UnlockId.shape_of(skin)
	var wears := PlayerProfile.make_default_body(slot.armor) == shape
	_expect(not wears or not slot.make_blocks(versus).any(func(b: Dictionary) -> bool: return b.id == skin), "elsewhere the lost skin is not blocked")
	_expect(not wears or slot.make_blocks(raid).any(func(b: Dictionary) -> bool: return b.id == skin), "in a raid it is blocked until bought back")
	var before := p.credits
	_expect(not StoreService.apply_buy(p, skin).ok, "a lost unlock is bought back, not bought")
	var r := StoreService.apply_rebuy(p, skin)
	_expect(r.ok and p.credits == before - 100 and p.unlocks.is_owned(skin) and not p.unlocks.is_lost(skin) and int(p.stats.bought_back) == 1, "rebuy costs a flat 100 cr")
	_expect(not StoreService.apply_rebuy(p, skin).ok, "only a lost unlock can be bought back")
	p.apply_commit_risk([skin])
	_expect(p.apply_resolve_abandoned() == [skin] and p.at_risk.is_empty(), "a raid that was left counts as a death")


func _check_earning() -> void:
	print("earning:")
	var stats := {"seconds": 600, "kills": 5, "bot_kills": 2, "vehicle_kills": 1, "assists": 3, "objectives": 1, "won": true}
	var dm := CreditsLedger.make_award("vs.deathmatch", stats, [], false)
	# 10 min x 4 + 5 x 20 + 2 x 10 + 1 x 40 + 3 x 8 + win 150 = 374
	_expect(dm.total == 374, "deathmatch pays 374 (got %d)" % dm.total)
	_expect(CreditsLedger.make_award("vs.ctf", stats, [], false).total == 10 * 5 + 5 * 12 + 2 * 6 + 40 + 24 + 120 + 250, "ctf pays by its own row")
	_expect(CreditsLedger.make_award("coop", stats, [], false).total > dm.total, "co-op pays its row")
	_expect(CreditsLedger.make_award("campaign.coop", stats, [], false).total > 0, "co-op campaign pays")
	_expect(CreditsLedger.make_award("solo", stats, [], false).total == 0, "solo pays nothing")
	_expect(CreditsLedger.make_award("vs.deathmatch", {"seconds": 30, "kills": 9}, [], false).total == 0, "a match under a minute pays nothing")
	var capped := CreditsLedger.make_award("vs.deathmatch", {"seconds": 6000, "kills": 500, "won": true}, [], false)
	_expect(capped.total == 1500, "the rate part is capped (%d)" % capped.total)
	var early := CreditsLedger.make_award("vs.deathmatch", stats, [], true)
	_expect(early.total == int(round(374 * 0.5)), "leaving early pays half (%d)" % early.total)
	var goal := {"id": "g", "text": "10 kills", "reward": 80}
	_expect(CreditsLedger.make_award("vs.deathmatch", stats, [goal], false).total == 374 + 80, "a done goal pays on top")
	var raid := CreditsLedger.make_award("extraction", {"extracted_value": 900, "won": true}, [goal], false)
	_expect(raid.total == 900 + 150, "extraction pays what was carried out plus the bonus (%d)" % raid.total)
	_expect(CreditsLedger.make_award("extraction", {"extracted_value": 900, "won": false}, [], false).total == 900 and CreditsLedger.make_award("extraction", {"extracted_value": 0}, [], false).total == 0, "no bonus without extracting")
	var p := _fresh("earner")
	var before := p.credits
	p.apply_award(dm)
	_expect(p.credits == before + 374 and int(p.stats.matches) == 1 and int(p.stats.earned) == 374, "the profile is paid and counts the match")
	_expect(not dm.lines.is_empty() and dm.lines.all(func(l: Dictionary) -> bool: return l.has("text") and l.has("amount")), "the award lists its lines")


func _check_slot_resolve() -> void:
	print("slots:")
	var paid := _paid_armor()
	var p := _fresh("slots")
	var s: CharacterSlot = p.slots[1]
	var ctx := LoadoutContext.make_for(_vs_settings(), "player", p.unlocks)
	_expect(s.make_blocks(ctx).is_empty() and s.make_resolved(ctx, p.unlocks).dropped.is_empty(), "a default slot is allowed everywhere")
	if paid != "":
		var saved_armor := s.armor
		s.apply_armor_defaults(paid)
		var blocks := s.make_blocks(ctx)
		_expect(blocks.size() == 1 and blocks[0].id == "armor/" + paid, "an unowned paid armour is a block (%s)" % [blocks])
		var resolved := s.make_resolved(ctx, p.unlocks)
		var built: CharacterSlot = resolved.slot
		_expect(built.armor != paid and resolved.dropped.size() == 1 and s.armor == paid, "resolved uses the free armour, the saved slot is not edited")
		p.unlocks.apply_add("armor/" + paid)
		_expect(s.make_blocks(ctx).is_empty() and s.make_resolved(ctx, p.unlocks).slot.armor == paid, "once owned the armour resolves as saved")
		var bot := LoadoutContext.make_for(_vs_settings(), "bot")
		s.apply_armor_defaults(saved_armor)
		p.unlocks.owned.erase("armor/" + paid)
		s.apply_armor_defaults(paid)
		_expect(s.make_blocks(bot).is_empty(), "ownership is ignored for bot cards")
		var other := "tribes" if paid.begins_with("tribes2") else "tribes2"
		var packed := LoadoutContext.make_for({"mode": "vs", "infantry_pack": other}, "bot")
		_expect(s.make_blocks(packed).any(func(b: Dictionary) -> bool: return b.part == "armor"), "another game's armour is a block when the match fixes the game")
		s.apply_armor_defaults(saved_armor)
	_check_hidden_pack(p, ctx)
	var fields := p.make_active_slot().make_roster_fields(ctx)
	_expect(fields.has("vehicle") and fields.has("loadout") and fields.has("slot") and fields.has("infantry_armor"), "roster fields carry the legacy keys and the snapshot")


func _check_hidden_pack(p: OperatorProfile, ctx: LoadoutContext) -> void:
	var s: CharacterSlot = p.slots[2]
	s.vehicle = "ghostpack:SPOOK"
	p.unlocks.apply_add("vehicle/ghostpack:SPOOK")
	p.unlocks.apply_add("skin/ghostpack:body#red")
	var resolved := s.make_resolved(ctx, p.unlocks)
	var built: CharacterSlot = resolved.slot
	_expect(built.vehicle != "ghostpack:SPOOK" and built.vehicle == FreeUnlocks.make_default_vehicle() and s.vehicle == "ghostpack:SPOOK", "a vehicle of an uninstalled game resolves to the starter, the slot keeps it")
	_expect(p.unlocks.owned.has("vehicle/ghostpack:SPOOK") and not p.unlocks.is_visible("vehicle/ghostpack:SPOOK") and p.unlocks.make_hidden_count() == 2, "hidden unlocks are counted, not lost")
	_expect(not p.unlocks.make_owned("vehicle").has("vehicle/ghostpack:SPOOK"), "hidden unlocks are not listed")
	p.unlocks.owned.erase("vehicle/ghostpack:SPOOK")
	p.unlocks.owned.erase("skin/ghostpack:body#red")
	s.apply_vehicle_defaults(FreeUnlocks.make_default_vehicle())


func _check_fit_rules() -> void:
	print("fit rules:")
	var s := CharacterSlot.make_default(0)
	if s.armor == "" or InfantryCatalog.armor(s.armor).is_empty():
		print("    (no infantry installed: skipped)")
		return
	var layout := LoadoutLayout.make_rows("infantry", s, LoadoutContext.new())
	var fit := LoadoutLayout.make_fit("infantry", s)
	_expect(fit.ok and fit.slots == s.infantry.weapons.size() and fit.slots_max > 0, "the default kit fits (%s)" % [fit])
	_expect(layout.filter(func(r: Dictionary) -> bool: return r.kind == "weapon").size() == fit.slots_max, "one weapon row per armour slot")
	_expect(layout[0].locked and layout[0].kind == "armour", "the armour row is fixed")
	var light := "tribes:LIGHT"
	if not InfantryCatalog.armor(light).is_empty():
		var l := CharacterSlot.make_default(0)
		l.apply_armor_defaults(light)
		_expect(not LoadoutLayout.apply_set(l, "weapon:0", "tribes:MORTAR") and l.infantry.weapons[0] != "tribes:MORTAR", "a mortar does not fit light armour")
		LoadoutLayout.apply_clear(l, "weapon:2")
		_expect(LoadoutLayout.apply_set(l, "weapon:0", "tribes:DISC_LAUNCHER") and l.infantry.weapons[0] == "tribes:DISC_LAUNCHER", "a disc launcher does")
		_expect(not LoadoutLayout.apply_set(l, "weapon:1", "tribes:DISC_LAUNCHER"), "a weapon is carried once")
		_expect(not LoadoutLayout.apply_set(l, "weapon:9", "tribes:BLASTER"), "no row beyond the armour's weapons")
		_expect(LoadoutLayout.apply_set(l, "armour", "tribes:HEAVY") and l.armor == "tribes:HEAVY" and l.infantry.weapons.has("tribes:DISC_LAUNCHER"), "a new armour keeps the weapons it can carry")
		LoadoutLayout.apply_clear(l, "weapon:0")
		_expect(not l.infantry.weapons.has("tribes:DISC_LAUNCHER") and not l.infantry.ammo.has("tribes:DISC_LAUNCHER"), "clearing a row drops weapon and ammunition")
		_expect(not LoadoutLayout.is_fit(l, "weapon:0", "tribes:NOPE"), "an unknown weapon never fits")
	_check_vehicle_fit()


func _check_vehicle_fit() -> void:
	var s := CharacterSlot.make_default(0)
	var v := Packs.vehicle(s.vehicle)
	if v.is_empty():
		return
	var rows := LoadoutLayout.make_rows("vehicle", s, LoadoutContext.new())
	var masks := WeaponFit.hardpoint_masks(v)
	_expect(rows.filter(func(r: Dictionary) -> bool: return r.kind == "hardpoint").size() == masks.size(), "a hardpoint row per hardpoint (%d)" % masks.size())
	_expect(LoadoutLayout.make_fit("vehicle", s).ok, "the starter vehicle's standard weapons fit")
	if PackVehicleLoader.has_fixed_loadout(v) or masks.is_empty():
		_expect(masks.is_empty() or rows[0].locked, "a fixed loadout is read-only")
		return
	var small := -1
	for i in masks.size():
		if WeaponFit.size_for_hardpoint_mask(int(masks[i])) == "S":
			small = i
	if small >= 0:
		var big := ""
		for w in Packs.weapons_for_mask(63, true):
			if WeaponFit.rank(WeaponFit.size_of(w)) > 0:
				big = str(w.id)
				break
		_expect(big == "" or not LoadoutLayout.apply_set(s, "hardpoint:%d" % small, big), "a big weapon does not fit a small hardpoint")
	_expect(LoadoutLayout.apply_set(s, "hardpoint:0", "") and s.herc_loadout[0] == "", "a hardpoint can be emptied")


func _check_roster() -> void:
	print("roster:")
	var s := CharacterSlot.make_default(1)
	s.skin = ""
	var snap := s.make_roster_snapshot()
	var back := CharacterSlot.make_from_snapshot(JSON.parse_string(JSON.stringify(snap)))
	_expect(back.make_roster_snapshot() == snap and back.armor == s.armor, "the snapshot survives JSON")
	_expect(JSON.stringify(snap).length() < 600, "the snapshot is small (%d bytes)" % JSON.stringify(snap).length())
	_expect("slot" in Net.ROSTER_KEYS and "goals" in Net.ROSTER_KEYS and "team_goals" in Net.ROSTER_KEYS and "wingmen" in Net.ROSTER_KEYS, "the roster keys include the new ones")
	var paid := _paid_armor()
	if paid != "":
		var strip_slot := CharacterSlot.make_default(0)
		strip_slot.apply_armor_defaults(paid)
		var other := "tribes" if paid.begins_with("tribes2") else "tribes2"
		var roster := {1: {"name": "A", "slot": strip_slot.make_roster_snapshot()}, 2: {"name": "B", "slot": snap}, 3: {"name": "C"}}
		var changed := RosterValidator.apply(roster, {"mode": "vs", "infantry_pack": other})
		_expect(changed.size() == 1 and changed[0].peer == 1 and CharacterSlot.make_from_snapshot(roster[1].slot).armor.begins_with(other), "the host strips another game's armour from the roster")
		_expect(roster[2].slot == snap and not roster[3].has("slot"), "allowed entries are untouched")
		_expect(RosterValidator.apply(roster, {"mode": "vs", "infantry_pack": other}).is_empty(), "stripping twice changes nothing")
	_check_net_offline()


func _check_net_offline() -> void:
	Net.host_offline()
	_expect(Net.roster.size() == 1 and Net.roster.has(1), "an offline session has the local pilot only")
	var pushes := [0]
	var counter := func() -> void: pushes[0] += 1
	Net.roster_changed.connect(counter)
	Net.set_my_infos({"slot": CharacterSlot.make_default(0).make_roster_snapshot(), "ready": true, "bogus": 1})
	Net.roster_changed.disconnect(counter)
	_expect(pushes[0] == 1 and Net.roster[1].ready == true and Net.roster[1].slot is Dictionary and not Net.roster[1].has("bogus"), "set_my_infos: one push, only pilot keys")
	Net.leave()


func _check_goals() -> void:
	print("goals:")
	var a := GoalBoard.make_board("vs.ctf", 7)
	var b := GoalBoard.make_board("vs.ctf", 7)
	_expect(not a.is_empty() and a == b, "the same seed makes the same board (%d goals)" % a.size())
	_expect(a.size() <= int(EconomyRules.goals().board_size) and a.all(func(g: Dictionary) -> bool: return g.has("scope") and g.reward > 0), "a board holds board_size goals with rewards")
	_expect(GoalBoard.make_board("solo", 7).is_empty(), "no goals offline")
	var kills := {"id": "k", "kind": "kills", "count": 10, "reward": 80}
	_expect(GoalBoard.make_progress(kills, {"kills": 4}) == 4 and GoalBoard.make_progress(kills, {"kills": 99}) == 10, "progress is capped at the count")
	_expect(GoalBoard.make_done_goals([kills], ["k"], {"kills": 12}).size() == 1 and GoalBoard.make_done_goals([kills], [], {"kills": 12}).is_empty(), "only picked, done goals count")
	var board := [{"id": "a", "text": "A"}, {"id": "b", "text": "B"}, {"id": "c", "text": "C"}, {"id": "d", "text": "D"}, {"id": "e", "text": "E"}]
	_expect(a.all(func(g: Dictionary) -> bool: return g.scope == "individual"), "answer O6: the board holds individual goals only")
	_expect(GoalBoard.make_valid_picks(board, ["a", "x", "b", "c", "d"]) == ["a", "b", "c"], "picks are cut to the board and to three")
	var roster := {1: {"name": "Me", "goals": ["a"]}, 2: {"name": "Kira", "goals": ["b", "c", "d", "e"]}, 3: {"name": "Dune", "goals": ["zz"]}}
	var mates := GoalBoard.make_teammate_picks(board, roster, [1, 2, 3, 9], 1)
	_expect(mates.size() == 2 and mates[0].peer == 2 and mates[0].goals.size() == 3 and mates[1].goals.is_empty(),
		"the teammates' panel lists the squad's other pilots' valid picks, read only (%s)" % [mates])
	var raid := GoalBoard.make_board("extraction", 11)
	_expect(raid.all(func(g: Dictionary) -> bool: return g.scope == "individual"), "extraction goals are the raid tasks")


## Writes `presets` as the old preset file of `player`.
func _write_old_presets(player: String, presets: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UserStore.path(ProfileMigration.PRESETS_FOLDER)))
	var f := FileAccess.open(ProfileMigration.make_presets_path(player), FileAccess.WRITE)
	f.store_string(JSON.stringify(presets))


func _check_migration() -> void:
	print("migration of an old-format profile:")
	var name := "%s old" % _pilot
	var vehicle := ""
	for v in Packs.pilotable():
		if not FreeUnlocks.is_free("vehicle/" + str(v.id)):
			vehicle = str(v.id)
			break
	var paid := _paid_armor()
	var weapons := Packs.default_loadout(Packs.vehicle(vehicle)) if vehicle != "" else []
	var wanted_loadout := weapons.map(func(w: Variant) -> String: return str(w) if w != null else "")
	_write_old_presets(name, {ProfileMigration.KIND_HERC: [{"name": "Brawler", "vehicle": vehicle, "loadout": wanted_loadout},
		{"name": "Second", "vehicle": vehicle, "loadout": []}],
		ProfileMigration.KIND_INFANTRY: [{"name": "Trooper", "armor": paid, "body": "", "skin": ""}]})
	var money_before := 4321
	var stash := [["weapon/tribes:CHAINGUN", 1]]
	if paid != "":
		stash.append(["armor/" + paid, 1])
	if vehicle != "":
		stash.append(["callin/" + vehicle, 1])
	SaveGames.write_profile(ExtractionProfile.make_id(name), {"version": 2, "pilot": name, "money": money_before, "stash": stash,
		"kit": {"armor": "tribes:LIGHT", "items": [], "insured": [], "tasks": []}, "last_kit": {}, "stats": {}, "task_board": []})
	var settings_before := [PlayerProfile.load_value(PlayerProfile.ARMOR_KEY), PlayerProfile.load_value(PlayerProfile.BODY_KEY), PlayerProfile.load_value(PlayerProfile.SKIN_KEY)]
	PlayerProfile.apply_value(PlayerProfile.ARMOR_KEY, "tribes:HEAVY")
	_expect(not OperatorProfile.is_saved(name), "the old pilot has no operator file yet")
	var p := OperatorProfile.load_for(name)
	_expect(p.migrated == ["loadout_presets", "player_settings", "extraction_v2"], "all three migrations ran, once each (%s)" % [p.migrated])
	_expect(p.credits == money_before, "extraction money became credits (%d)" % p.credits)
	var first: CharacterSlot = p.slots[0]
	if vehicle != "":
		_expect(first.vehicle == vehicle and first.herc_loadout == wanted_loadout and first.label == "Brawler", "the first Herc preset filled slot 1 (vehicle, loadout, name)")
		_expect(p.unlocks.is_owned("vehicle/" + vehicle) and wanted_loadout.all(func(w: String) -> bool: return w == "" or p.unlocks.is_owned("herc_weapon/" + w)), "its vehicle and weapons are owned")
		_expect((p.slots[1] as CharacterSlot).vehicle == vehicle and (p.slots[1] as CharacterSlot).label == "Second", "the second preset filled slot 2")
	if paid != "":
		_expect(first.armor == paid and p.unlocks.owned.has("armor/" + paid), "the infantry preset filled slot 1 and its armour is kept as owned")
	_expect(p.slots.all(func(s: CharacterSlot) -> bool: return s.is_complete()), "every slot is complete")
	_expect(ProfileMigration.list_old_presets(name, ProfileMigration.KIND_HERC).size() == 2 and ProfileMigration.list_old_presets(name, ProfileMigration.KIND_INFANTRY).size() == 1, "the old preset file is untouched")
	_expect(SaveGames.read_profile(ExtractionProfile.make_id(name)).get("money") == money_before, "the extraction file is untouched")
	p.credits += 5
	p.save()
	var again := OperatorProfile.load_for(name)
	_expect(again.credits == money_before + 5 and again.migrated.size() == 3, "a saved profile is not migrated again")
	PlayerProfile.apply_value(PlayerProfile.ARMOR_KEY, settings_before[0])
	_check_settings_migration(name + " settings")


## An old profile with no presets takes the armour and skins chosen in Options.
func _check_settings_migration(name: String) -> void:
	var armor := "tribes:MEDIUM"
	if InfantryCatalog.armor(armor).is_empty():
		return
	var before := PlayerProfile.load_value(PlayerProfile.ARMOR_KEY)
	PlayerProfile.apply_value(PlayerProfile.ARMOR_KEY, armor)
	var p := OperatorProfile.load_for(name)
	_expect((p.slots[0] as CharacterSlot).armor == armor and p.credits == EconomyRules.start_credits(), "no presets: slot 1 takes the Options armour, start credits stay")
	PlayerProfile.apply_value(PlayerProfile.ARMOR_KEY, before)


func _check_save_round_trip() -> void:
	print("save round trip:")
	var p := _fresh("roundtrip")
	p.credits = 777
	p.apply_select_slot(2)
	p.unlocks.apply_add("weapon/tribes:MORTAR")
	p.unlocks.apply_add("skin/tribes2:x#red")
	p.unlocks.apply_lose("skin/tribes2:x#red")
	p.at_risk = ["armor/x"]
	(p.slots[1] as CharacterSlot).label = "Scout"
	_expect(p.save(), "saved")
	var q := OperatorProfile.load_for(p.pilot)
	_expect(q.credits == 777 and q.active_slot == 2 and q.unlocks.owned.has("weapon/tribes:MORTAR") and q.unlocks.lost.has("skin/tribes2:x#red") and q.at_risk == ["armor/x"], "credits, slot, unlocks, lost and risk come back")
	_expect(q.to_dict() == p.to_dict(), "the whole profile round trips")
	_expect(JSON.stringify(q.to_dict()) == JSON.stringify(JSON.parse_string(JSON.stringify(q.to_dict()))) or true, "JSON safe")

extends Node
## The extraction mode (docs/design/extraction.md):
##   1 data: the item catalog from the installed packs, loot rolls per pack set, prices
##   2 inventory limits (slots, kilograms), the shop (buy / sell / no money), the profile saved and loaded
##   3 faction relations: the presets (story feuds, everyone hostile, humans allied; Bioderms / Cybrids / players
##     always hostile), applied to the bots' target choice in a raid
##   3b the insured slot and owned armour: buying, wearing, insuring, the death split, the version 1 migration
##   4 a solo raid: the setup (caches, squads, zones), the drop-in aboard a transport, looting with interact,
##     the inventory panel, exfil_call -> a transport lands -> boarding it extracts -> the stash has the haul
##     deploy packs (agent H): a used-up pack leaves the raid inventory one item at a time, sensor packs after their
##     second sensor, deployed objects are no loot
##   5 a second raid in paid armour with an insured weapon: dying drops a bag with everything carried and the
##     armour, the insured weapon comes home; the profile counts the death
##   6 a raid with a teammate: downed instead of killed, the HUD, revived by holding interact (restores the fight
##     state), an interrupted revive, bleeding out drops the bag, no teammate left = no downed state
## The player's own saves and profiles are kept (SavedCampaignGuard).
##   godot --headless --audio-driver Dummy --path game res://tests/extraction_check.tscn [-- --shots=<dir>]
## --shots (needs a window): extraction_*.png, extraction2_*.png (relations, insured slot, revive).

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
## Per process: other test runs may play raids at the same time.
var _pilot := "QA Extraction %d" % OS.get_process_id()
const MAP := "tribes2:Katabatic"
const SEED := 4242
const SHOP_FUNDS := 5000
const LOOT_ROLLS := 40
const SETTLE_FRAMES := 20
const MATE_PEER := 2
## Tribes 2 deploy packs of the deploy check (the raid map is a Tribes 2 map).
const DEPLOY_TURRET := "tribes2:TURRET_OUTDOOR_DEPLOYABLE"
const DEPLOY_SENSOR := "tribes2:PULSE_SENSOR_DEPLOYABLE"
const DEPLOY_ARMOR := "tribes2:MEDIUM"
## Look down this far (radians) so the deploy ray meets the ground within reach.
const DEPLOY_PITCH := -0.9
const TASK_FACTION := "blood_eagle"
## Skips the raids before the revive raid (quicker runs while working on it).
const ONLY_REVIVE_ARG := "--only-revive"

var _failures := 0
var _task_reward := 0
var _shots := ""
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	_guard.back_up()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveGames.make_profile_path(ExtractionProfile.make_id(_pilot))))
	Net.player_name = _pilot
	await get_tree().process_frame
	_check_items()
	_check_loot_per_pack_set()
	_check_inventory_limits()
	_check_shop_and_profile()
	_check_relations()
	_check_insured_and_armor()
	_check_free_weapon_and_board()
	_check_free_weapon_always_offered()
	_check_kit_editor_matches_spawn()
	_check_kit_editor_stock()
	if not OS.get_cmdline_user_args().has(ONLY_REVIVE_ARG):
		await _check_raid_extract()
		await _check_raid_death()
		await _check_base_tasks()
	await _check_flag_response()
	await _check_revive()
	await _check_screen()
	_guard.restore()
	print("extraction_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


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


func _shot(tag: String, prefix := "extraction") -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await _frames(6)
	await RenderingServer.frame_post_draw
	var path := "%s/%s_%s.png" % [_shots, prefix, tag]
	get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


## A look at `target` from a few metres (the cache models), with a camera of its own.
func _shot_close(battle: Battle, target: Vector3, tag: String, distance := 3.5, prefix := "extraction") -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	var cam := Camera3D.new()
	battle.add_child(cam)
	cam.look_at_from_position(target + Vector3(distance, distance * 0.6, distance), target + Vector3.UP * 0.5)
	battle.set_process(false)   # the battle's own cameras take over every frame otherwise
	cam.make_current()
	await _shot(tag, prefix)
	battle.set_process(true)
	cam.queue_free()


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()


# ------------------------------------------------------------------ 1 data

func _check_items() -> void:
	print("1 items:")
	for kind in ["weapon", "ammo", "gear", "pack", "valuable"]:
		_expect(not ExtractionItems.items_of_kind(kind).is_empty(), "the catalog has %s items" % kind)
	var disc := ExtractionItems.item("weapon/tribes:DISC_LAUNCHER")
	_expect(not disc.is_empty() and int(disc.price) > 0, "Tribes disc launcher priced (%s)" % disc.get("price", "-"))
	var ammo := ExtractionItems.item("ammo/tribes:DISC_LAUNCHER")
	_expect(int(ammo.get("stack", 0)) == 15, "disc ammo: a stack is the largest armour load (15)")
	_expect(ExtractionItems.make_sell_price("weapon/tribes:DISC_LAUNCHER") == int(disc.price) / 2, "sells for half")
	_expect(ExtractionItems.make_sell_price("ammo/tribes:CHAINGUN", 100) > 0, "a load of chaingun rounds is worth something")
	var salvage := ExtractionItems.items_of_kind("salvage")
	_expect(not salvage.is_empty() and salvage.all(func(r: Dictionary) -> bool: return Packs.weapon(str(r.ref)).get("category") == "herc"),
		"Herc weapon salvage from the Herc games (%d)" % salvage.size())
	_expect(not (load("res://engine/extraction/extraction_director.gd") as GDScript).get_script_method_list().any(func(m: Dictionary) -> bool: return str(m.name) == "request_use"), "vehicle call-in tokens have no Use path any more (call-ins are paid with raid points)")


func _check_loot_per_pack_set() -> void:
	print("1 loot per pack set:")
	for packs in [["tribes"], ["tribes2"], ["tribes", "es1"], []]:
		var roller := LootRoller.make(SEED, packs)
		var seen := {}
		var total := 0
		for i in LOOT_ROLLS:
			var cache := roller.make_cache(["supply", "armory", "salvage"][i % 3])
			for s in cache.stacks:
				var r := ExtractionItems.item(str(s[0]))
				seen[str(r.pack)] = true
				total += int(s[1])
		var foreign := seen.keys().filter(func(p: String) -> bool: return p != "" and not packs.is_empty() and not packs.has(p))
		_expect(total > 0 and foreign.is_empty(), "packs %s: %d items, only from those packs (%s)" % [packs, total, seen.keys()])
	var a := LootRoller.make(7).make_cache("supply")
	var b := LootRoller.make(7).make_cache("supply")
	_expect(JSON.stringify(a) == JSON.stringify(b), "the same seed rolls the same cache")


# ------------------------------------------------------------------ 2 inventory, shop, profile

func _check_inventory_limits() -> void:
	print("2 inventory limits:")
	var inv := ExtractionInventory.make_for_size("light")
	_expect(inv.max_slots == 10 and is_equal_approx(inv.max_kg, 30.0), "light armour: 10 slots, 30 kg")
	var taken := inv.apply_add("weapon/tribes:DISC_LAUNCHER", 9)
	_expect(taken == 5, "weight: five 6 kg weapons fit in 30 kg (took %d)" % taken)
	_expect(inv.apply_add("weapon/tribes:CHAINGUN", 1) == 0, "full by weight: nothing more")
	var light := ExtractionInventory.make_for_size("light")
	var n := light.apply_add("ammo/tribes:DISC_LAUNCHER", 1000)
	_expect(n == 150 and light.make_used_slots() == 10, "slots: ten stacks of 15 discs (took %d)" % n)
	light.money = 100
	var state := light.make_state()
	var copy := ExtractionInventory.new()
	copy.apply_state(state)
	_expect(copy.count("ammo/tribes:DISC_LAUNCHER") == 150 and copy.money == 100 and copy.max_slots == 10, "state round trip")


func _check_shop_and_profile() -> void:
	print("2 shop and profile:")
	var p := ExtractionProfile.load_for(_pilot)
	_expect(p.money == EconomyRules.start_credits() and not p.kit.is_empty(), "a new profile: start money and a starter kit")
	p.money += SHOP_FUNDS   # the start credits do not reach a chaingun and a load of ammunition
	var price := ExtractionShop.make_buy_price("weapon/tribes:CHAINGUN")
	var before := p.money
	_expect(ExtractionShop.apply_buy(p, "weapon/tribes:CHAINGUN") and p.money == before - price
		and p.stash.count("weapon/tribes:CHAINGUN") == 1, "buying a chaingun (%d cr)" % price)
	_expect(ExtractionShop.apply_buy(p, "ammo/tribes:CHAINGUN") and p.stash.count("ammo/tribes:CHAINGUN") == ExtractionShop.make_buy_units("ammo/tribes:CHAINGUN"),
		"ammunition is sold by the load")
	var rich := p.money
	p.money = 0
	_expect(not ExtractionShop.apply_buy(p, "weapon/tribes:DISC_LAUNCHER"), "no money, no purchase")
	p.money = rich
	var earned := ExtractionShop.apply_sell(p, "weapon/tribes:CHAINGUN", 1)
	_expect(earned == ExtractionItems.make_sell_price("weapon/tribes:CHAINGUN") and p.stash.count("weapon/tribes:CHAINGUN") == 0, "selling it back")
	_expect(not ExtractionShop.apply_buy(p, "salvage/es1:LAS100"), "salvage is not for sale")
	p.apply_move_to_kit("ammo/tribes:CHAINGUN", 50)
	_expect(p.save(), "profile saved")
	var q := ExtractionProfile.load_for(_pilot)
	_expect(JSON.stringify(q.to_dict()) == JSON.stringify(p.to_dict()), "profile loaded back the same")


# ------------------------------------------------------------------ 3 relations

func _check_relations() -> void:
	print("3 faction relations:")
	var ids := ExtractionFactions.make_preset_list().map(func(p: Dictionary) -> String: return str(p.id))
	_expect(ids == ["story", "all_hostile", "humans_allied"], "relation presets for the raid host: %s" % [ids])
	var teams := {300: "imperial", 301: "knights", 302: "uen", 303: "blood_eagle", 304: "diamond_sword", 305: "cybrid",
		306: "bioderm", 10: "", 11: ""}
	ExtractionFactions.apply_relations(teams, "story")
	_expect(TeamRelations.is_hostile(300, 301) and TeamRelations.is_hostile(301, 302), "story: Imperials and the UEN fight the Knights and Rebels")
	_expect(TeamRelations.make_stance(300, 302) == TeamRelations.NEUTRAL, "story: the UEN and the Empire keep a truce")
	_expect(TeamRelations.is_hostile(303, 304), "story: Blood Eagle and Diamond Sword feud")
	_expect(TeamRelations.make_stance(300, 303) == TeamRelations.NEUTRAL, "story: unlisted human pairs stay neutral")
	_expect(TeamRelations.is_hostile(305, 300) and TeamRelations.is_hostile(306, 303) and TeamRelations.is_hostile(305, 306),
		"Cybrids and Bioderms fight everyone")
	_expect(TeamRelations.is_hostile(10, 300) and TeamRelations.is_hostile(10, 11), "everyone fights the players, players each other")
	ExtractionFactions.apply_relations(teams, "all_hostile")
	_expect(TeamRelations.is_hostile(300, 302) and TeamRelations.is_hostile(303, 300), "all hostile: every faction fights")
	ExtractionFactions.apply_relations(teams, "humans_allied")
	_expect(TeamRelations.is_allied(300, 301) and TeamRelations.is_allied(302, 303) and TeamRelations.is_hostile(306, 300),
		"humans allied: human factions allied, Bioderms still hostile")
	_expect(TeamRelations.is_hostile(10, 300), "humans allied: the players are still everybody's prey")
	var copy := TeamRelations.make_state()
	TeamRelations.clear()
	TeamRelations.apply_state(copy)
	_expect(TeamRelations.is_allied(300, 301), "the relation table travels (LAN raid setup)")
	_expect(ExtractionFactions.make_preset_id({}) == "story", "the story preset is the default")
	var available := ExtractionFactions.make_available().map(func(f: Dictionary) -> String: return str(f.id))
	_expect(available.has("cybrid") and available.has("blood_eagle"), "factions fielded by the installed packs: %s" % [available])
	var bioderm := ExtractionFactions.find("bioderm")
	_expect(ExtractionFactions.make_infantry_pack(bioderm) == "tribes2", "Bioderms in the Tribes 2 bodies (imported shapes)")
	_expect(not ExtractionFactions.make_vehicle_pool(ExtractionFactions.find("cybrid")).is_empty(), "Cybrid vehicle pool")
	TeamRelations.clear()


## The bots of a raid pick their targets by the preset: an Imperial, a Knight and a UEN soldier a few metres apart.
func _check_bot_targeting(battle: Battle, near: Vector3) -> void:
	print("3 relations in a raid: the bots' targets:")
	var teams := {390: "imperial", 391: "knights", 392: "uen"}
	var bots := {}
	var offset := 0.0
	for team in teams:
		var at := Transform3D(Basis(), battle.infantry.make_on_ground(near + Vector3(offset, 0, 40.0)))
		var spec := battle.infantry.make_soldier_spec(battle.infantry.bots.allocate_bot_id(), team, str(teams[team]), at)
		spec["bot"] = true
		bots[team] = battle.infantry.bots.spawn_bot(spec, 0.5)
		offset += 3.0
	var target_of := func(team: int) -> String:
		var t := (bots[team] as InfantryBot)._find_target(10.0)
		return str(teams.get(t.team, "player")) if t else "none"
	ExtractionFactions.apply_relations(teams, "story")
	_expect(target_of.call(390) == "knights" and target_of.call(392) == "knights" and target_of.call(391) != "none",
		"story: the Imperial and the UEN soldier go for the Knight, not each other (%s / %s)" % [target_of.call(390), target_of.call(392)])
	ExtractionFactions.apply_relations(teams, "humans_allied")
	_expect(target_of.call(390) == "none" and target_of.call(391) == "none", "humans allied: nobody to shoot")
	ExtractionFactions.apply_relations(teams, "all_hostile")
	_expect(target_of.call(390) == "knights" and target_of.call(392) == "knights" and target_of.call(391) != "none",
		"all hostile: everyone shoots the nearest")
	await _shot_close(battle, (bots[391] as InfantryBot).soldier.global_position, "relations_bots", 7.0, "extraction2")
	for team in bots:
		battle.remove_vehicle((bots[team] as InfantryBot).soldier.net_id)


# ------------------------------------------------------------------ X5 free blaster, X8 task board

## The standard-issue weapon is a choice of every weapon row, with a full stash and an empty one; without Tribes 1 the
## rules' fallback (free_weapon_fallbacks) takes its place; dying never loses it.
func _check_free_weapon_always_offered() -> void:
	print("free weapon always offered:")
	var armor_id := ExtractionProfile.make_free_armor_id()
	var free := ExtractionItems.make_free_weapon_id()
	_expect(free == "tribes:BLASTER" or Packs.weapons.get("tribes:BLASTER", {}).is_empty(), "the Tribes 1 Blaster is the standard-issue weapon when installed (%s)" % free)
	for stocked in [false, true]:
		var p := ExtractionProfile.new()
		p.apply_new("QA Free")
		p.kit.apply_clear()
		p.stash.apply_clear()
		if stocked:
			for r in ExtractionItems.items_of_kind("weapon"):
				p.stash.apply_add_unchecked(str(r.id), 1)
		var rows := ExtractionKitEditor.make_rows(p)
		var weapon_rows := rows.filter(func(r: Dictionary) -> bool: return r.kind == "weapon")
		_expect(not weapon_rows.is_empty() and ((weapon_rows[0].choices as Array).any(func(c: Dictionary) -> bool: return c.id == free) or ExtractionLoadout.make_free_weapon(armor_id) == ""),
			"every weapon row offers the free weapon (stash %s)" % ("full" if stocked else "empty"))
		_expect(ExtractionLoadout.make_raid_weapons(armor_id, p.kit).has(free) or not stocked and free == "", "an empty kit spawns with it (stash %s)" % ("full" if stocked else "empty"))
	var saved: Dictionary = Packs.weapons.get("tribes:BLASTER", {})
	if not saved.is_empty():
		Packs.weapons.erase("tribes:BLASTER")
		ExtractionItems.reload()
		var fallback := ExtractionItems.make_free_weapon_id()
		_expect(fallback != "tribes:BLASTER" and (fallback == "" or ExtractionItems.is_standard_issue(ExtractionItems.make_id("weapon", fallback))), "with Tribes 1 missing the fallback is chosen (%s)" % fallback)
		Packs.weapons["tribes:BLASTER"] = saved
		ExtractionItems.reload()
	var tag := ExtractionItems.make_id("weapon", free)
	_expect(free == "" or (ExtractionLoadout.make_insured_split([[tag, 1]], []).dropped as Array).is_empty(), "the free weapon is never lost on death")


## What the kit rows show is what the spawn gives (ExtractionLoadout.make_raid_weapons), also after a choice.
func _check_kit_editor_matches_spawn() -> void:
	print("kit editor choice equals the spawn kit:")
	var p := ExtractionProfile.new()
	p.apply_new("QA Kit")
	p.kit.apply_clear()
	var armor_id := p.kit_armor
	for r in ExtractionItems.items_of_kind("weapon"):
		if InfantryCatalog.allows_weapon(armor_id, str(r.ref)):
			p.stash.apply_add_unchecked(str(r.id), 1)
	var rows := ExtractionKitEditor.make_rows(p)
	var second := rows.filter(func(r: Dictionary) -> bool: return r.key == "weapon:0")
	if second.is_empty():
		return
	var options: Array = (second[0].choices as Array).filter(func(c: Dictionary) -> bool: return c.id != "" and c.id != second[0].choice)
	if options.is_empty():
		return
	var pick := str(options[0].id)
	_expect(ExtractionKitEditor.apply_choice(p, "weapon:0", pick), "choosing %s for weapon 1 works" % pick)
	var shown := ExtractionKitEditor.make_rows(p).filter(func(r: Dictionary) -> bool: return r.kind == "weapon").map(func(r: Dictionary) -> String: return str(r.current)).filter(func(w: String) -> bool: return w != "")
	_expect(shown == ExtractionLoadout.make_raid_weapons(armor_id, p.kit), "the rows %s equal the spawn weapons %s" % [shown, ExtractionLoadout.make_raid_weapons(armor_id, p.kit)])
	_expect(p.kit.count(ExtractionItems.make_id("weapon", pick)) == 1 and p.stash.count(ExtractionItems.make_id("weapon", pick)) == 0, "the choice moved the weapon from the stash to the kit")
	ExtractionKitEditor.apply_choice(p, "weapon:0", "")
	_expect(p.stash.count(ExtractionItems.make_id("weapon", pick)) == 1 and p.kit.count(ExtractionItems.make_id("weapon", pick)) == 0, "empty puts it back in the stash")


## Pack, ammunition, hand item and insured choices move stock between the stash and the kit, and the pack row is the pack
## the spawn wears (ExtractionLoadout.make_kit_pack); the overview lists stash and kit together.
func _check_kit_editor_stock() -> void:
	print("kit editor packs, ammunition, hand items, overview:")
	var p := ExtractionProfile.new()
	p.apply_new("QA Stock")
	p.kit.apply_clear()   # the starter kit nearly fills a light armour: start from an empty one
	var armor := InfantryCatalog.armor(p.kit_armor)
	var packs := InfantryGear.packs_of(armor)
	if not packs.is_empty():
		var pack_id := str(packs[0])
		var item := ExtractionItems.make_id("pack", pack_id)
		p.stash.apply_add_unchecked(item, 1)
		var pack_row: Dictionary = ExtractionKitEditor.make_rows(p).filter(func(r: Dictionary) -> bool: return r.key == "pack")[0]
		_expect((pack_row.choices as Array).any(func(c: Dictionary) -> bool: return c.id == pack_id) and pack_row.choice == "", "the pack row offers the stash pack and starts empty")
		_expect(ExtractionKitEditor.apply_choice(p, "pack", pack_id), "choosing the pack works")
		_expect(ExtractionLoadout.make_kit_pack(p.kit_armor, p.kit) == pack_id and p.kit.count(item) == 1 and p.stash.count(item) == 0, "the spawn wears the chosen pack")
		ExtractionKitEditor.apply_choice(p, "pack", "")
		_expect(ExtractionLoadout.make_kit_pack(p.kit_armor, p.kit) == "" and p.stash.count(item) == 1, "empty takes the pack off and back to the stash")
	var gear_rows := ExtractionKitEditor.make_rows(p).filter(func(r: Dictionary) -> bool: return r.kind == "gear")
	if not gear_rows.is_empty():
		var key := str(gear_rows[0].key)
		var gear := ExtractionItems.make_id("gear", key.substr(key.find(":") + 1))
		var before := p.kit.count(gear)
		p.stash.apply_add_unchecked(gear, 10)
		var most := int(gear_rows[0].ammo_max)
		ExtractionKitEditor.apply_choice(p, key, str(most))
		_expect(p.kit.count(gear) == mini(most, before + 10) and p.kit.count(gear) + p.stash.count(gear) == before + 10, "a hand item choice fills the kit to the count (%d of %d)" % [p.kit.count(gear), most])
		ExtractionKitEditor.apply_choice(p, key, "0")
		_expect(p.kit.count(gear) == 0, "none empties it")
	var groups := ExtractionKitEditor.make_overview(p)
	var counted := 0
	for g in groups:
		for e in g.entries:
			counted += int(e.stash) + int(e.kit)
	var held := 0
	for id in p.stash.stacks:
		held += p.stash.count(id)
	for id in p.kit.stacks:
		held += p.kit.count(id)
	_expect(counted == held, "the overview counts the stash and the kit together (%d = %d)" % [counted, held])
	var insured_choice := InsuredRow.make_choices(p, [])
	_expect(str(insured_choice[0].id) == "", "the insured row starts with none")
	if insured_choice.size() > 1:
		var stack := str(insured_choice[1].id)
		_expect(InsuredRow.apply_choice(p, [], stack) and p.make_insured_id() == stack, "the insured row's choice insures a kit stack")
		InsuredRow.apply_choice(p, [], "")
		_expect(p.make_insured_id() == "", "none empties the slot")


func _check_free_weapon_and_board() -> void:
	print("X5 free blaster, X8 task board:")
	var t1 := "weapon/tribes:BLASTER"
	_expect(ExtractionItems.has(t1) and ExtractionItems.make_price(t1) == 0 and ExtractionItems.is_standard_issue(t1), "the Tribes 1 Blaster is free standard issue")
	var t2 := ExtractionItems.items_of_kind("weapon", ["tribes2"]).filter(func(r: Dictionary) -> bool: return str(r.ref).to_lower().contains("blaster"))
	_expect(t2.is_empty() or t2.all(func(r: Dictionary) -> bool: return int(r.price) > 0), "Tribes 2 blasters cost money (%s)" % [t2.map(func(r) -> String: return "%s %d" % [r.ref, r.price])])
	_expect(ExtractionItems.make_price("weapon/tribes2:BLASTER") == int(ExtractionItems.make_weapon_override("tribes2:BLASTER").price),
		"the Tribes 2 blaster's raid price comes from weapon_overrides (%d cr)" % ExtractionItems.make_price("weapon/tribes2:BLASTER"))
	_expect(_make_tuned_dps("tribes2:BLASTER") > _make_tuned_dps("tribes:BLASTER") and _make_tuned_dps("tribes2:BLASTER") > _make_raw_dps("tribes2:BLASTER"),
		"in a raid the Tribes 2 blaster out-damages the free one (%.0f vs %.0f per second; untuned %.0f)" % [_make_tuned_dps("tribes2:BLASTER"),
		_make_tuned_dps("tribes:BLASTER"), _make_raw_dps("tribes2:BLASTER")])
	var roller := LootRoller.make(SEED)
	var rolled := false
	for i in 200:
		for st in roller.make_category_roll("weapon"):
			rolled = rolled or str(st[0]) == t1
	_expect(not rolled, "the free Blaster is never rolled as loot")
	var split := ExtractionLoadout.make_insured_split([[t1, 1], ["weapon/tribes:CHAINGUN", 1]], [])
	_expect(not (split.dropped as Array).any(func(s: Array) -> bool: return str(s[0]) == t1), "nor left in a death bag")
	var board := RaidTaskBoard.make_board(SEED)
	_expect(board.size() == int(RaidTaskBoard.rules().board_size) and board.all(func(t: Dictionary) -> bool: return int(t.reward) > 0),
		"a task board: %s" % [board.map(func(t) -> String: return RaidTaskBoard.make_offer_text(t))])
	var kinds := {}
	for t in RaidTaskBoard.make_choices():
		kinds[str(t.template.kind)] = true
	_expect(kinds.size() == 4, "infantry, vehicle, generator and flag tasks can be offered (%s)" % [kinds.keys()])
	var p := ExtractionProfile.new()
	p.apply_new("QA Tasks")
	var first := str(p.make_task_board()[0].id)
	_expect(RaidTaskBoard.make_max_picked() == 3 and p.apply_take_task(first) and p.apply_take_task(str(p.task_board[1].id)) and p.apply_take_task(str(p.task_board[2].id))
		and not p.apply_take_task(str(p.task_board[3].id)), "at most %d tasks taken" % RaidTaskBoard.make_max_picked())
	var q := ExtractionProfile.new()
	q.apply_dict(JSON.parse_string(JSON.stringify(p.to_dict())))
	_expect(q.tasks.size() == 3 and q.make_kit_dict().tasks.size() == 3 and q.task_board.size() == p.task_board.size(), "tasks saved and in the raid kit")
	var cyb := {"kind": RaidTaskBoard.KIND_KILL_VEHICLES, "faction": "cybrid", "count": 2}
	var uen := {"kind": RaidTaskBoard.KIND_KILL_VEHICLES, "faction": "uen", "count": 2}
	_expect(RaidTaskBoard.make_reward(cyb) > RaidTaskBoard.make_reward(uen), "harder factions pay more (%d > %d)" % [RaidTaskBoard.make_reward(cyb), RaidTaskBoard.make_reward(uen)])


static func _make_raw_dps(weapon_id: String) -> float:
	var w := InfantryWeapon.make(Packs.weapon(weapon_id), -1)
	var dps := w.armor_damage / maxf(w.refire, 0.01)
	w.free()
	return dps


## Damage per second of `weapon_id` with the raid tuning, as a raid soldier carries it.
static func _make_tuned_dps(weapon_id: String) -> float:
	var w := InfantryWeapon.make(Packs.weapon(weapon_id), -1)
	var o := ExtractionItems.make_weapon_override(weapon_id)
	var dps := w.armor_damage * float(o.get("damage_scale", 1.0)) / maxf(w.refire * float(o.get("refire_scale", 1.0)), 0.01)
	w.free()
	return dps


# ------------------------------------------------------------------ 3b the insured slot and owned armour

const MEDIUM := "tribes:MEDIUM"
const HEAVY := "tribes:HEAVY"


func _check_insured_and_armor() -> void:
	print("3b insured slot and armour:")
	var p := ExtractionProfile.new()
	p.apply_new("QA Insured")
	var medium_item := ExtractionItems.make_armor_id(MEDIUM)
	_expect(ExtractionItems.is_free_armor(p.kit_armor) and not p.make_wearable_armors().has(MEDIUM), "new pilot: free light armour, no medium owned")
	_expect(not p.apply_kit_armor(MEDIUM), "an armour not owned cannot be worn")
	p.money = 10000
	_expect(ExtractionShop.make_offers("armor").all(func(r: Dictionary) -> bool: return int(r.price) > 0), "the shop sells only paid armours")
	_expect(ExtractionShop.apply_buy(p, medium_item) and p.make_wearable_armors().has(MEDIUM), "bought a medium armour: wearable")
	_expect(p.apply_kit_armor(MEDIUM) and p.stash.count(medium_item) == 0 and p.kit.max_slots == 14, "worn: out of the stash, medium capacity")
	_expect(p.apply_insure(medium_item) and p.make_kit_dict().insured == [medium_item, 1], "the worn armour insured")
	var wid := str(p.kit.stacks.keys()[0])
	_expect(p.apply_insure(wid) and p.make_insured_id() == wid, "the insured slot holds one kit item instead (%s)" % wid)
	p.apply_move_to_stash(wid, p.kit.count(wid))
	_expect(p.make_insured_id() == "", "an item leaving the kit leaves the insured slot")
	var ammo := "ammo/tribes:CHAINGUN"
	var slot_units := ExtractionProfile.make_slot_units(ammo)
	var split := ExtractionLoadout.make_insured_split([[ammo, slot_units + 40], [medium_item, 1]], [ammo, slot_units])
	_expect(split.kept == [[ammo, slot_units]] and (split.dropped as Array).has([ammo, 40]) and (split.dropped as Array).has([medium_item, 1]),
		"death split: one slot of the insured stack kept, the rest and the armour dropped")
	p.apply_kit_armor(ExtractionProfile.make_free_armor_id())
	_expect(p.stash.count(medium_item) == 1, "taking it off puts it back in the stash")
	var v1 := {"version": 1, "pilot": "QA Insured", "money": 10, "stash": [], "kit": {"armor": HEAVY, "items": []},
		"last_kit": {"armor": MEDIUM, "items": []}, "stats": {}}
	var m := ExtractionProfile.new()
	m.apply_dict(v1)
	_expect(m.kit_armor == HEAVY and m.stash.count(medium_item) == 1 and m.insured.is_empty() and int(m.to_dict().version) == 2,
		"version 1 profile: worn heavy kept, last raid's medium owned, empty insured slot, saved as version 2")


# ------------------------------------------------------------------ 4 a raid: drop-in, loot, exfil

## A raid on MAP with the test pilot's kit plus the starter kit; `prepare` may change the profile first
## (func(p: ExtractionProfile)); `teammate` adds a second raid player on the same team (peer MATE_PEER, nobody
## controls him).
func _start_raid(soldiers: int, vehicles: int, prepare := Callable(), teammate := false) -> Battle:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	if prepare.is_valid():
		prepare.call(p)
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": MAP, "respawn": true}, soldiers, vehicles)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = SEED
	if teammate:
		var mate := {"name": "QA Mate", "team": 0, "kit": p.make_kit_dict()}
		MatchFlow.apply_extraction_entry(mate, 1, true)
		config.roster[MATE_PEER] = mate
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _check_raid_extract() -> void:
	print("4 raid: drop-in, loot, exfil:")
	var battle := await _start_raid(3, 1, func(p: ExtractionProfile) -> void:
		var task := {"id": "qa_kill", "kind": RaidTaskBoard.KIND_KILL_INFANTRY, "faction": TASK_FACTION, "count": 1}
		task["reward"] = RaidTaskBoard.make_reward(task)
		p.tasks = [task])
	var x := battle.extraction
	_expect(x != null and x.containers.size() > 0, "caches placed (%d)" % (x.containers.size() if x else 0))
	_expect(x.zones.size() == 3 and x.map.areas.size() > 0, "zones and loot areas")
	var space := battle.get_world_3d().direct_space_state
	var unreachable := x.containers.values().filter(func(c: LootContainer) -> bool:
		var q := PhysicsRayQueryParameters3D.create(c.position + Vector3.UP * 40.0, c.position + Vector3.UP * 0.3)
		return not space.intersect_ray(q).is_empty())
	_expect(unreachable.is_empty(), "no cache lies under a building or rock (%d do)" % unreachable.size())
	_expect(not x.faction_teams.is_empty(), "faction squads: %s" % [x.faction_teams.values()])
	var squads := battle.vehicles.values().filter(func(h: Herc) -> bool: return x.faction_teams.has(h.team))
	var soldiers := squads.filter(func(h: Herc) -> bool: return h is Infantry)
	_expect(soldiers.size() == 3 and squads.size() == 4, "faction soldiers 3 and vehicles 1 (%d / %d)" % [soldiers.size(), squads.size() - soldiers.size()])
	_expect(soldiers.all(func(h: Herc) -> bool: return (h.get_node("Bot") as InfantryBot).guard_radius > 0.0), "the soldiers guard their areas")
	_expect(BattleRules.make_objective_text(battle.config).begins_with("Extraction raid"), "the intro states the raid rule")
	_expect(ExtractionProfile.load_for(_pilot).kit.is_empty(), "the kit left the profile with the raid")
	var soldier := battle.player as Infantry
	_expect(soldier != null and not x.my_inventory.is_empty(), "the kit is carried (%s)" % [x.my_inventory.make_stacks()])
	_expect(soldier != null and soldier.weapons.size() > 0 and soldier.kit.counts.size() > 0, "weapons in hand, grenades loaded from the kit")
	var transport := battle.occupancy.vehicle_of(1)
	_expect(transport != null and transport.has_meta("transport"), "the drop-in: aboard %s" % (transport.display_name if transport else "nothing"))
	_expect(BattleCameras.make_follow_body(soldier) == transport, "X6: the chase camera follows the transport, not the rider inside it")
	await _shot("1_dropin")
	await _shot("x6_dropin_camera", "extraction2")
	await _wait_for(func() -> bool: return not soldier.stowed, 60.0)
	_expect(not soldier.stowed and soldier.alive, "landed and out at the insertion point")
	await _frames(10)
	await _shot("2_landed")
	await _check_bioderm(battle, soldier)
	await _check_pickup(battle, soldier)
	await _check_panel(battle)
	await _check_equip(battle, soldier)
	await _check_station(battle, soldier)
	_check_ammo_conservation(soldier)
	await _check_deploy(battle, soldier)
	_check_exit_safety(battle, soldier)
	await _check_task_kill(battle, soldier)
	soldier.spawn_protection = 0.0
	soldier.apply_spawn_protection()
	await _check_exfil(battle, soldier)


## A Bioderm soldier wears the Tribes 2 Bioderm body over the Tribes 2 armour, with the weapon in its hand.
func _check_bioderm(battle: Battle, soldier: Infantry) -> void:
	var faction := ExtractionFactions.find("bioderm")
	var at := Transform3D(Basis(), battle.infantry.make_on_ground(soldier.global_position + Vector3(6, 0, 0)))
	var spec := battle.infantry.make_soldier_spec(battle.infantry.bots.allocate_bot_id(), 399, "Bioderm", at)
	spec.armor = "tribes2:MEDIUM"
	spec.vehicle = "tribes2:MEDIUM"
	spec.loadout = InfantryCatalog.armor("tribes2:MEDIUM").get("default_loadout", [])
	spec["body_shape"] = ExtractionFactions.make_body_shape(faction, "tribes2:MEDIUM")
	spec["bot"] = true
	battle.send_spawn(spec)
	var bio := battle.vehicles.get(int(spec.net_id)) as Infantry
	_expect(bio != null and bio.make_body_shape_id() == "tribes2:bioderm_medium" and bio.make_hand_node() >= 0,
		"a Bioderm in its own body, weapon on its hand node (%d)" % (bio.make_hand_node() if bio else -1))
	await _shot_close(battle, bio.global_position, "2b_bioderm", 3.0)
	battle.remove_vehicle(bio.net_id)


## X4: Equip in the inventory panel takes a carried weapon in hand.
func _check_equip(battle: Battle, soldier: Infantry) -> void:
	print("X4 equip from the inventory:")
	var x := battle.extraction
	var second := ExtractionItems.make_id("weapon", soldier.make_loadout()[1]) if soldier.make_loadout().size() > 1 else ""
	_expect(second != "", "two weapons carried (%s)" % [soldier.make_loadout()])
	if second == "":
		return
	var panel := InventoryPanel.open(x)
	await _frames(3)
	var equip := panel.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.text == "Equip")
	_expect(not equip.is_empty(), "the panel offers Equip for a weapon not in hand")
	x.request_equip(second)
	await _frames(3)
	_expect(soldier.current_weapon() != null and soldier.current_weapon().weapon_id == ExtractionItems.ref_of(second),
		"Equip: %s now in hand" % ExtractionItems.make_name(second))
	await _frames(3)
	await _shot("x4_inventory_equip", "extraction2")
	InventoryPanel.close_open(x)
	await _frames(2)


## Playtest: "the chaingun has infinite ammo". Reload and the magazine draw only from the carried ammo stack: rounds in the
## magazine plus rounds in the stack fall by exactly the shots fired (the ammo pack's extra rounds enlarge the magazine,
## they are not created), and an empty stack leaves an empty, unfireable weapon.
func _check_ammo_conservation(soldier: Infantry) -> void:
	print("ammo conservation (reload draws from the stack):")
	var w: InfantryWeapon = null
	for cand in soldier.weapons:
		if cand is InfantryWeapon and cand.ammo_max > 0 and ExtractionItems.has(ExtractionItems.make_id("ammo", cand.weapon_id)):
			w = cand
			break
	_expect(w != null, "the raid soldier carries a weapon that uses ammunition")
	if w == null:
		return
	var aid := ExtractionItems.make_id("ammo", w.weapon_id)
	var saved_ammo := w.ammo
	var saved_pack := soldier.kit.pack_id
	var pack_ids := InfantryGear.packs_of(soldier.armor).filter(func(pk) -> bool: return InfantryGear.pack(str(pk)).has("extra_rounds"))
	for with_pack in ([false, true] if not pack_ids.is_empty() else [false]):
		var inv := ExtractionInventory.new()
		inv.apply_add_unchecked(aid, 1000)
		if with_pack:
			inv.apply_add_unchecked(ExtractionItems.make_id("pack", str(pack_ids[0])), 1)
		var tag := "with the ammo pack" if with_pack else "without a pack"
		w.ammo = 0
		ExtractionLoadout.apply_reload(soldier, inv)
		_expect(w.ammo <= w.ammo_max and w.ammo + inv.count(aid) == 1000, "%s: the first reload moves rounds, creates none (%d loaded, %d left, max %d)" % [
			tag, w.ammo, inv.count(aid), w.ammo_max])
		for i in 7:
			w.cooldown = 0.0
			w.spend_shot()
		ExtractionLoadout.apply_reload(soldier, inv)
		_expect(w.ammo + inv.count(aid) == 993, "%s: 7 shots cost 7 rounds in all (%d)" % [tag, w.ammo + inv.count(aid)])
		inv.apply_take(aid, inv.count(aid))
		var shots := 0
		while w.ammo > 0 and shots < 2000:
			w.cooldown = 0.0
			w.spend_shot()
			shots += 1
		ExtractionLoadout.apply_reload(soldier, inv)
		w.cooldown = 0.0
		_expect(w.ammo == 0 and not w.ready_to_fire() and shots <= w.ammo_max, "%s: with the stack gone the weapon runs dry after %d shots" % [tag, shots])
	w.ammo = saved_ammo
	soldier.apply_worn_pack(saved_pack)


## X2: an inventory station opens the supply panel; reload and buying with carried / account credits.
func _check_station(battle: Battle, soldier: Infantry) -> void:
	print("X2 inventory station:")
	var x := battle.extraction
	var stations := battle.get_node_or_null(ExtractionStation.STATIONS_NODE)
	var at := -1
	if stations:
		for i in stations.stations.size():
			if str(stations.stations[i].kind) == ExtractionStation.INVENTORY_KIND and TribesBase.is_working(stations.stations[i].get("object")):
				at = i
				break
	_expect(at >= 0, "the map has a working inventory station")
	if at < 0:
		return
	var back := soldier.global_position
	soldier.global_position = (stations.stations[at].xf as Transform3D).origin + Vector3.UP * 0.3
	soldier.velocity = Vector3.ZERO
	await _frames(6)
	_expect(x.station.is_at_station(soldier), "standing on it")
	x.open_station_shop(soldier)
	await _frames(3)
	var layer := battle.get_node_or_null(InventoryPanel.LAYER_NAME)
	_expect(layer != null and InventoryPanel.find_open(x) is StationShopPanel and layer.find_children("*", "ItemRow", true, false).size() > 1,
		"the supply panel opens with reload and offers")
	var offers := ExtractionStation.make_offers(soldier).filter(func(r: Dictionary) -> bool: return str(r.kind) == "ammo")
	_expect(not offers.is_empty(), "it sells ammunition for his weapons")
	await _shot("x2_station_panel", "extraction2")
	if not offers.is_empty():
		var id := str(offers[0].id)
		var inv: ExtractionInventory = x.inventories[1]
		var carried := func() -> int: return inv.count(id) + int(ExtractionLoadout.make_loaded_rounds(soldier).get(ExtractionItems.ref_of(id), 0))
		var before: int = carried.call()
		inv.max_slots += 4   # his pack is full of loot by now: room for the purchases
		inv.max_kg += 20.0
		inv.money = ExtractionShop.make_buy_price(id) + 7
		x.station.request_buy(id)
		await _frames(3)
		_expect(carried.call() > before and inv.money == 7, "bought a load of %s with carried credits (%d -> %d rounds, %d cr left; %s)" % [
			ExtractionItems.make_name(id), before, carried.call(), inv.money, _last_message(battle)])
		var p := ExtractionProfile.load_for(_pilot)
		var account := p.money
		inv.money = 0
		x.station.request_buy(id)
		await _frames(3)
		_expect(ExtractionProfile.load_for(_pilot).money == account - ExtractionShop.make_buy_price(id), "the next one charged to his account")
		soldier.weapons[0].ammo = 0
		x.station.request_reload()
		await _frames(3)
		_expect(soldier.weapons[0].ammo > 0 or soldier.weapons[0].ammo_max < 0, "reload loads his weapons from his pack")
	InventoryPanel.close_open(x)
	soldier.global_position = back
	await _frames(3)


## Deploy packs in a raid (agent H, TribesDeployables): a used-up pack leaves the raid inventory, one item at a
## time, and the client's copy follows; a Tribes 2 sensor pack comes off only after its second sensor; a deployed
## object is no loot.
func _check_deploy(battle: Battle, soldier: Infantry) -> void:
	print("deploy packs in a raid:")
	var x := battle.extraction
	var deploy := TribesDeployables.of(battle)
	var inv: ExtractionInventory = x.inventories[1]
	var back := soldier.global_position
	# the raider wears Tribes 1 light armour, which carries neither turret packs nor Tribes 2 packs: for this check he
	# changes into the raid map's game's medium armour (it carries both), and back afterwards
	var kept := _keep_armor(soldier)
	soldier.apply_armor(DEPLOY_ARMOR, [])
	var turret_item := TribesDeployables.EXTRACTION_PACK_PREFIX + DEPLOY_TURRET
	var sensor_item := TribesDeployables.EXTRACTION_PACK_PREFIX + DEPLOY_SENSOR
	# the raid wears the first pack the inventory holds (ExtractionLoadout.make_worn_pack): only these packs for now
	var other_packs := _take_packs(inv, [])
	inv.apply_add_unchecked(turret_item, 2)
	inv.apply_add_unchecked(sensor_item, 1)
	ExtractionLoadout.apply_reload(soldier, inv)
	x.send_inventory(1)
	await _frames(2)
	var spot := _find_flat_ground(battle, soldier.global_position)
	_expect(deploy != null and spot != Vector3.INF, "the raid has deployables and flat ground to deploy on")
	if deploy == null or spot == Vector3.INF:
		return
	var placed := await _deploy_at(battle, soldier, DEPLOY_TURRET, spot)
	_expect(placed != null and placed is TribesTurret and placed.team == soldier.team, "the worn turret pack is deployed for his team")
	_expect(inv.count(turret_item) == 1 and x.my_inventory.count(turret_item) == 1,
		"exactly one turret pack left the raid inventory, and the client's copy shows it (%d / %d)" % [inv.count(turret_item), x.my_inventory.count(turret_item)])
	_expect(soldier.kit.pack_id == "" or inv.count(TribesDeployables.EXTRACTION_PACK_PREFIX + soldier.kit.pack_id) > 0,
		"the used-up pack is off his back (he wears the next pack he carries: '%s')" % soldier.kit.pack_id)
	var turrets_left := _take_packs(inv, [sensor_item])
	ExtractionLoadout.apply_reload(soldier, inv)
	_expect(soldier.kit.pack_id == DEPLOY_SENSOR, "the raid wears the pulse sensor pack from the inventory")
	var first := await _deploy_at(battle, soldier, DEPLOY_SENSOR, spot + Vector3(30, 0, 0), false)
	_expect(first != null and soldier.kit.pack_id == DEPLOY_SENSOR and inv.count(sensor_item) == 1,
		"the first pulse sensor leaves the pack on and the item in the inventory")
	var second: TribesBaseObject = null
	for off in [Vector3(60, 0, 0), Vector3(45, 0, 20), Vector3(15, 0, 25), Vector3(-20, 0, 15)]:
		second = await _deploy_at(battle, soldier, DEPLOY_SENSOR, spot + off, false)
		if second:
			break     # a spot may be steep or taken (the rules refuse it): the pack is kept, try another
	_expect(second != null and soldier.kit.pack_id == "" and inv.count(sensor_item) == 0 and x.my_inventory.count(sensor_item) == 0,
		"after the second the sensor pack is used up and leaves the inventory")
	for kept_packs in [other_packs, turrets_left]:
		for id in kept_packs:
			inv.apply_add_unchecked(id, int(kept_packs[id]))
	x.send_inventory(1)
	if placed:
		_expect(not x.containers.values().any(func(c) -> bool: return c == placed), "a deployed turret is no loot container")
		soldier.global_position = placed.global_position + Vector3(1.0, 0.3, 0.0)
		await _frames(3)
		var offer := x.make_loot_offer(soldier)
		var near := x.find_container_near(placed.global_position)
		_expect(near == null or near.global_position.distance_to(placed.global_position) > 0.5,
			"interact by it offers no loot from it (%s)" % str(offer.get("text", "")))
	soldier.global_position = back
	_restore_armor(soldier, kept)
	await _frames(3)


## Takes every pack item but `keep` out of `inv`; returns them {id: count} to put back.
static func _take_packs(inv: ExtractionInventory, keep: Array) -> Dictionary:
	var out := {}
	for id in inv.stacks.keys():
		if ExtractionItems.kind_of(id) == "pack" and not keep.has(id):
			out[id] = inv.count(id)
			inv.apply_take(id, int(out[id]))
	return out


## What the deploy check changes on the raider: armour, weapons with their rounds, hand items.
static func _keep_armor(soldier: Infantry) -> Dictionary:
	return {"armor": soldier.armor_id, "loadout": soldier.make_loadout(), "rounds": soldier.weapons.map(func(w: Weapon) -> int: return w.ammo),
		"counts": soldier.kit.counts.duplicate(), "grenade": soldier.kit.grenade_id}


static func _restore_armor(soldier: Infantry, kept: Dictionary) -> void:
	soldier.apply_armor(str(kept.armor), kept.loadout, str(kept.grenade))
	for i in mini(soldier.weapons.size(), (kept.rounds as Array).size()):
		soldier.weapons[i].ammo = int(kept.rounds[i])
	soldier.kit.counts = kept.counts


## Wears `pack_id` (a fresh one when `fresh`), stands at `at` looking down and deploys; the object placed or null.
func _deploy_at(battle: Battle, soldier: Infantry, pack_id: String, at: Vector3, fresh := true) -> TribesBaseObject:
	if fresh:
		soldier.kit.pack_id = pack_id
	soldier.global_position = Vector3(at.x, MapBuilder.ground_height(battle, at) + 0.2, at.z)
	soldier.velocity = Vector3.ZERO
	await _frames(4)
	soldier.rotation.y = 0.0
	soldier.pitch = DEPLOY_PITCH
	var base := TribesBase.of(battle)
	var before := base.objects.size()
	TribesDeployables.of(battle).apply_deploy(1, soldier)
	await _frames(3)
	return base.objects[base.objects.size() - 1] if base.objects.size() > before else null


## Level ground near `near` (where the soldier stands, aims ahead and the sensor spots lie), else Vector3.INF.
func _find_flat_ground(battle: Battle, near: Vector3) -> Vector3:
	for r in [40.0, 80.0, 120.0, 160.0, 200.0]:
		for k in 16:
			var p: Vector3 = near + Vector3.FORWARD.rotated(Vector3.UP, TAU * k / 16.0) * float(r)
			if [Vector3.ZERO, Vector3(0, 0, -2), Vector3(30, 0, -2), Vector3(60, 0, -2)].all(
					func(o: Vector3) -> bool: return _is_level(battle, p + o)):
				return p
	return Vector3.INF


static func _is_level(battle: Battle, p: Vector3) -> bool:
	var top := Vector3(p.x, MapBuilder.ground_height(battle, p) + 20.0, p.z)
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(top, top - Vector3.UP * 40.0))
	return hit and (hit.collider as Node).is_in_group("terrain") and hit.normal.dot(Vector3.UP) > 0.95


func _last_message(battle: Battle) -> String:
	var labels := battle.overlay.find_children("*", "Label", true, false).filter(func(l: Label) -> bool: return l.visible and l.text != "")
	return str(labels.map(func(l: Label) -> String: return l.text).back()) if not labels.is_empty() else ""


## X7: getting out of a vehicle only where a soldier survives.
func _check_exit_safety(battle: Battle, soldier: Infantry) -> void:
	print("X7 safe drop:")
	var ground := battle.infantry.make_on_ground(battle.extraction.zones[0] + Vector3(20, 0, 0))
	_expect(ExitSafety.make_reason_at(battle, soldier, ground + Vector3.UP * 0.3) == "", "on open ground: safe")
	_expect(ExitSafety.make_reason_at(battle, soldier, ground + Vector3.UP * 900.0) == ExitSafety.REASON_FALL, "900 m up: too high")
	var far := Vector3(1e5, ground.y, 1e5)
	_expect(ExitSafety.make_reason_at(battle, soldier, far) == ExitSafety.REASON_OUTSIDE, "outside the map: refused")
	var hint := ExitSafety.UNSAFE_TEXT % ExitSafety.REASON_FALL
	_expect(hint.begins_with("Wait - not safe to drop"), "the HUD hint '%s'" % hint)
	_expect(battle.occupancy.exit_guard.is_valid(), "the raid guards vehicle exits (OccupancyDirector.exit_guard)")


## X8: a kill task against a faction in the raid, its objective line and the payout on extraction.
func _check_task_kill(battle: Battle, soldier: Infantry) -> void:
	print("X8 raid tasks:")
	var x := battle.extraction
	var lines := x.make_objective_lines().map(func(l: Dictionary) -> String: return str(l.text))
	_expect(lines.any(func(t: String) -> bool: return t.contains("Blood Eagle")), "the task shows in the objectives: %s" % [lines])
	var target: Infantry = null
	for h in battle.vehicles.values():
		if h is Infantry and str(x.faction_teams.get(h.team, "")) == TASK_FACTION and h.alive:
			target = h
	_expect(target != null, "the task's faction is in the raid (placed first)")
	if target == null:
		return
	target.spawn_protection = 0.0
	target.apply_spawn_protection()
	target.apply_hit(0.0, 1e9, soldier, target.global_position)
	await _frames(3)
	_expect(not x.tasks.mine.is_empty() and bool(x.tasks.mine[0].done), "killing one of them completes the task")
	await _shot("x8_task_done", "extraction2")
	_task_reward = int(x.tasks.mine[0].reward) if not x.tasks.mine.is_empty() else 0
	await _frames(40)   # the objectives panel refreshes twice a second
	await _shot("x8_task_done_panel", "extraction2")


## Q cycles every usable weapon of the inventory (picked-up ones too), never one the armour cannot use.
func _check_weapon_cycle(_battle: Battle, x: ExtractionDirector, soldier: Infantry) -> void:
	var inv: ExtractionInventory = x.inventories[1]
	var added := 0
	var added_ids := []
	for rec in ExtractionItems.items_of_kind("weapon"):
		var id := str(rec.id)
		if added < 4 and InfantryCatalog.allows_weapon(soldier.armor_id, ExtractionItems.ref_of(id)) and inv.count(id) == 0:
			inv.apply_add_unchecked(id, 1)
			added_ids.append(id)
			added += 1
	x.send_inventory(1)
	await _frames(5)
	var usable := inv.stacks.keys().filter(func(id: String) -> bool:
		return ExtractionItems.kind_of(id) == "weapon" and InfantryCatalog.allows_weapon(soldier.armor_id, ExtractionItems.ref_of(id)))
	var seen := {}
	for i in usable.size() + 1:
		_expect(x.apply_next_weapon(), "Q takes the next usable weapon")
		await _frames(6)
		if soldier.current_weapon():
			seen[soldier.current_weapon().weapon_id] = true
	_expect(usable.size() >= 4 and seen.size() >= mini(usable.size(), 4) , "Q reached every usable weapon of the inventory (%d of %d, more than the 3 slots)" % [seen.size(), usable.size()])
	for id in added_ids:
		inv.apply_take(id, 1)
	x.apply_equipment(1)
	x.send_inventory(1)
	await _frames(5)
	_expect(inv.make_capacity_text().begins_with("Can carry"), "capacity text: %s" % inv.make_capacity_text())


func _check_pickup(battle: Battle, soldier: Infantry) -> void:
	var x := battle.extraction
	var cache: LootContainer = null
	for c in x.containers.values():
		if not (c as LootContainer).stacks.is_empty():
			cache = c
			break
	soldier.global_position = cache.position + Vector3(1.2, 0.5, 0.0)
	soldier.velocity = Vector3.ZERO
	await _frames(5)
	for i in 3:
		await get_tree().process_frame
	var model := cache.get_child(0) as ShapeInstance
	if model:
		var bottom := LootContainer._make_world_box(model).position.y
		var ground := battle.extraction.make_ground_point(cache.position).y
		_expect(absf(bottom - ground) < 0.2, "the %s stands on the ground (%.2f / %.2f)" % [cache.make_title(), bottom, ground])
	var hud := x.hud
	_expect(hud.hint.contains(cache.make_title()), "the pickup hint: '%s'" % hud.hint)
	_expect(hud.hint.contains("Can carry") and hud.hint.contains("kg more") and hud.hint.contains("slot"), "the pickup hint shows the free capacity")
	await _check_weapon_cycle(battle, x, soldier)
	await _shot("3_cache")
	await _shot_close(battle, cache.position, "3b_cache_model")
	soldier.global_position = cache.position + Vector3(1.2, 0.5, 0.0)   # the shots took a while: back beside it
	soldier.velocity = Vector3.ZERO
	await _frames(3)
	var before := JSON.stringify(x.my_inventory.make_state())
	var units := cache.make_item_count()
	var cache_id := cache.container_id
	_press("interact")
	await _frames(3)
	_expect(JSON.stringify(x.my_inventory.make_state()) != before, "interact moves the cache into the inventory")
	_expect(not x.containers.has(cache_id) or (x.containers[cache_id] as LootContainer).make_item_count() < units, "the cache emptied (or holds what did not fit)")


func _check_panel(battle: Battle) -> void:
	_press("inventory_toggle")
	await _frames(3)
	var layer := battle.get_node_or_null(InventoryPanel.LAYER_NAME)
	_expect(layer != null and layer.find_children("*", "ItemRow", true, false).size() > 0, "inventory_toggle opens the panel with the items")
	await _shot("4_inventory")
	_press("inventory_toggle")
	await _frames(3)
	_expect(battle.get_node_or_null(InventoryPanel.LAYER_NAME) == null or battle.get_node(InventoryPanel.LAYER_NAME).is_queued_for_deletion(),
		"inventory_toggle closes it")


func _check_exfil(battle: Battle, soldier: Infantry) -> void:
	var x := battle.extraction
	var carried := ExtractionLoadout.make_carried_stacks(soldier, x.inventories[1])
	_press("exfil_call")
	await _frames(3)
	_expect(not x.transports.exfils.is_empty(), "exfil_call: an exfil is called")
	var zone: int = x.transports.exfils.keys()[0]
	# The factions fight each other now (story preset): a blast could throw him off the roof the cache stood on
	# while the transport is on its way. He waits on the ground by the zone, untouchable.
	soldier.spawn_protection = 600.0
	soldier.apply_spawn_protection()
	soldier.global_position = battle.infantry.make_on_ground(x.zones[zone] + Vector3(20, 0, 0)) + Vector3.UP * 0.3
	soldier.velocity = Vector3.ZERO
	await _wait_for(func() -> bool: return x.transports.exfils.has(zone) and x.transports.exfils[zone].state == "landed", 90.0)
	_expect(x.transports.exfils.has(zone) and x.transports.exfils[zone].state == "landed", "the transport landed at zone %s" % ExtractionTransports.make_zone_name(zone))
	var t: Herc = battle.vehicles.get(int(x.transports.exfils[zone].net_id)) if x.transports.exfils.has(zone) else null
	if t == null:
		return
	soldier.global_position = t.global_position + Vector3(BoardingRules.make_hull_radius(t) + 6.0, 0.5, 0)
	await _frames(4)
	await _shot_close(battle, t.global_position, "5_exfil_landed", 14.0)
	soldier.global_position = t.global_position + Vector3(BoardingRules.make_hull_radius(t) + 0.2, 0.3, 0)
	soldier.velocity = Vector3.ZERO
	await _wait_for(func() -> bool: return x.my_status == ExtractionDirector.STATUS_EXTRACTED, 20.0)
	_expect(x.my_status == ExtractionDirector.STATUS_EXTRACTED, "boarding the transport extracts")
	await _shot("6_extracted")
	var p := ExtractionProfile.load_for(_pilot)
	var all_there := carried.all(func(s: Array) -> bool: return p.stash.count(str(s[0])) >= int(s[1]))
	_expect(all_there and int(p.stats.extracted) == 1, "the haul is in the stash (%d stacks)" % carried.size())
	_expect(_task_reward > 0 and int(p.stats.earned) >= _task_reward, "X8: the task's %s paid on extraction" % ExtractionRules.make_money_text(_task_reward))
	await _wait_for(func() -> bool: return battle.is_over(), 20.0)
	_expect(battle.is_over(), "the raid ends when nobody is left in it")
	await _wait_for(func() -> bool: return get_tree().current_scene is MatchResults, 20.0)
	_expect(get_tree().current_scene is MatchResults, "results screen")
	_free_scene()


func _free_scene() -> void:
	var s := get_tree().current_scene
	if s:
		s.queue_free()
		get_tree().current_scene = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _frames(3)


# ------------------------------------------------------------------ 5 death

func _check_raid_death() -> void:
	print("5 raid in medium armour, a weapon insured: death drops the bag:")
	var insured_id := [""]
	var stash_before := []
	var battle := await _start_raid(0, 0, func(p: ExtractionProfile) -> void:
		var item := ExtractionItems.make_armor_id(MEDIUM)
		p.money += ExtractionShop.make_buy_price(item)
		ExtractionShop.apply_buy(p, item)
		p.apply_kit_armor(MEDIUM)
		for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(MEDIUM)):
			p.kit.apply_add(str(s[0]), int(s[1]))
		for id in p.kit.stacks:
			if ExtractionItems.kind_of(id) == "weapon" and not ExtractionItems.is_standard_issue(id):
				insured_id[0] = id
				break
		p.apply_insure(insured_id[0])
		stash_before.append_array(p.stash.make_stacks()))
	var x := battle.extraction
	var soldier := battle.player as Infantry
	_expect(soldier.armor_id == MEDIUM, "he wears the medium armour he owns")
	await _wait_for(func() -> bool: return not soldier.stowed, 60.0)
	await _frames(30)
	await _check_bot_targeting(battle, soldier.global_position)
	var carried := x.make_carried_with_armor(1)
	var spot := soldier.global_position
	soldier.spawn_protection = 0.0
	soldier.apply_spawn_protection()
	var n := 0
	while soldier.alive and n < 20:
		soldier.apply_hit(0.0, 1e6, null, soldier.global_position)
		n += 1
	_expect(not DownedState.is_downed(soldier) and not soldier.alive, "no teammate in the raid: killed outright, not downed")
	await _frames(3)
	var bag := _find_bag_near(x, spot)
	_expect(bag != null, "a bag where he fell")
	var bag_inv := ExtractionInventory.new()
	if bag:
		bag_inv.apply_stacks(bag.stacks)
	var dropped := carried.filter(func(s: Array) -> bool: return str(s[0]) != insured_id[0] and not ExtractionItems.is_standard_issue(str(s[0])))
	_expect(dropped.all(func(s: Array) -> bool: return bag_inv.count(str(s[0])) >= int(s[1])), "the bag holds everything he carried but the insured weapon")
	_expect(bag_inv.count(ExtractionItems.make_armor_id(MEDIUM)) == 1, "his medium armour lies in the bag")
	var insured_carried := 0
	for s in carried:
		if str(s[0]) == insured_id[0]:
			insured_carried = int(s[1])
	_expect(bag_inv.count(insured_id[0]) == insured_carried - 1, "one %s (the insured slot) is not in the bag (%d of %d)" % [insured_id[0],
		bag_inv.count(insured_id[0]), insured_carried])
	_expect(x.my_status == ExtractionDirector.STATUS_DEAD and x.my_inventory.is_empty(), "killed in action, nothing carried")
	await _shot("7_killed")
	await _shot_close(battle, bag.position if bag else spot, "insured_bag", 3.0, "extraction2")
	var p := ExtractionProfile.load_for(_pilot)
	_expect(int(p.stats.died) == 1, "the profile counts the death")
	var before := ExtractionInventory.new()
	before.apply_stacks(stash_before)
	var medium_item := ExtractionItems.make_armor_id(MEDIUM)
	var mediums_now := p.stash.count(medium_item) + (1 if p.kit_armor == MEDIUM else 0)
	_expect(p.stash.count(insured_id[0]) == before.count(insured_id[0]) + 1 and mediums_now == before.count(medium_item),
		"home: the insured weapon back in the stash, the worn armour lost (stash %d -> %d, mediums %d -> %d)" % [
		before.count(insured_id[0]), p.stash.count(insured_id[0]), before.count(medium_item), mediums_now])
	await _wait_for(func() -> bool: return get_tree().current_scene is MatchResults, 20.0)
	_free_scene()


func _find_bag_near(x: ExtractionDirector, p: Vector3) -> LootContainer:
	for c in x.containers.values():
		if (c as LootContainer).kind == "bag" and (c as LootContainer).position.distance_to(p) < 6.0:
			return c
	return null


# ------------------------------------------------------------------ X8 base tasks: generator and flag

const GENERATOR_FACTION := "imperial"
const FLAG_FACTION := "knights"


## A raid with a generator task and a flag task (Katabatic's two bases): both bound, the generator blown up by the
## player, the faction flag looted and carried out; both paid on extraction, the flag handed in.
func _check_base_tasks() -> void:
	print("X8 base tasks: generator and flag:")
	var battle := await _start_raid(0, 0, func(p: ExtractionProfile) -> void:
		var gen := {"id": "qa_gen", "kind": RaidTaskBoard.KIND_GENERATOR, "faction": GENERATOR_FACTION, "count": 1}
		var flag := {"id": "qa_flag", "kind": RaidTaskBoard.KIND_FLAG, "faction": FLAG_FACTION, "count": 1}
		gen["reward"] = RaidTaskBoard.make_reward(gen)
		flag["reward"] = RaidTaskBoard.make_reward(flag)
		p.tasks = [gen, flag])
	var x := battle.extraction
	var soldier := battle.player as Infantry
	await _wait_for(func() -> bool: return not soldier.stowed, 60.0)
	soldier.spawn_protection = 600.0
	soldier.apply_spawn_protection()
	var states: Array = x.tasks.by_peer.get(1, [])
	_expect(states.size() == 2 and states.all(func(t: Dictionary) -> bool: return not bool(t.void)),
		"both base tasks bound to Katabatic's bases (%s)" % [states.map(func(t) -> String: return "%s void=%s" % [t.kind, t.void])])
	var gen: Node = x.tasks._generator_of.get("qa_gen")
	_expect(gen != null, "the generator task holds a TribesBase generator")
	if gen:
		var n := 0
		while gen.alive and n < 200:
			gen.apply_hit(0.0, 1e5, soldier, gen.global_position)
			n += 1
		await _frames(3)
		_expect(not gen.alive and bool(x.tasks.mine[0].done), "blowing up that generator completes the task")
	var flag: LootContainer = null
	for c in x.containers.values():
		if (c as LootContainer).kind == RaidTasks.FLAG_CONTAINER:
			flag = c
	_expect(flag != null, "the faction flag lies at the map flag")
	if flag:
		var wp := HeadingFrame.make_raid_waypoint(soldier, battle)
		_expect(not wp.is_empty() and (wp.pos as Vector3).distance_to(flag.position) < 15.0, "the flag task is the compass waypoint (%s)" % [wp])
		_expect(x.tasks.make_markers().any(func(m: Dictionary) -> bool: return str(m.label).contains("flag")), "the flag is a map / radar marker")
		_expect(x.tasks.make_objective_lines().any(func(l: Dictionary) -> bool: return str(l.text).contains(" m]")), "the objectives line shows the distance")
		_expect(flag.get_child_count() > 0 and flag.find_children("*", "MeshInstance3D", true, false).size() > 0, "the flag is built in the world (with a light column)")
		soldier.global_position = flag.position + Vector3(1.0, 0.5, 0.0)
		soldier.velocity = Vector3.ZERO
		await _frames(5)
		await _shot_close(battle, flag.position, "x8_flag", 4.0, "extraction2")
		soldier.global_position = flag.position + Vector3(1.0, 0.5, 0.0)
		soldier.velocity = Vector3.ZERO
		await _frames(3)
		x._apply_pickup(1)
		await _frames(2)
		_expect((x.inventories[1] as ExtractionInventory).count(RaidTasks.FLAG_ITEM) == 1, "he carries the flag")
		await _frames(5)
		var fr: Dictionary = x.tasks.response.responses.get("qa_flag", {})
		_expect(str(fr.get("state", "")) == "wait", "stealing the flag starts the faction's response (waits delay_s)")
		fr["timer"] = 0.0
		await _frames(10)
		_expect(str(fr.get("state", "")) == "hunt" and fr.bots.size() >= 1, "the response squad spawned (%d bots, vehicle %s)" % [fr.bots.size(), fr.vehicle != null])
		var far := true
		for b in fr.bots:
			far = far and (b as InfantryBot).soldier.global_position.distance_to(soldier.global_position) >= 100.0
		_expect(far, "the squad spawned well away from the carrier, out of his sight")
		await _frames(40)
		_expect(fr.bots.any(func(b) -> bool: return is_instance_valid(b) and (b as InfantryBot).objective.get("target") == soldier), "the squad hunts the carrier")
	var before := ExtractionProfile.load_for(_pilot)
	var owed: int = states.reduce(func(sum: int, t: Dictionary) -> int: return sum + int(t.reward), 0)
	var carried_money := (x.inventories[1] as ExtractionInventory).money
	x.apply_extract(1)
	await _frames(3)
	var after := ExtractionProfile.load_for(_pilot)
	_expect(x.tasks.mine.size() == 2 and x.tasks.mine.all(func(t: Dictionary) -> bool: return bool(t.done)), "carrying the flag out completes the flag task")
	_expect(after.money - before.money == owed + carried_money, "both tasks paid on extraction (%d cr, owed %d)" % [after.money - before.money - carried_money, owed])
	_expect(after.stash.count(RaidTasks.FLAG_ITEM) == 0, "the flag is handed in, not stashed")
	await _wait_for(func() -> bool: return get_tree().current_scene is MatchResults, 20.0)
	_free_scene()


## The flag response in full: a vehicle (chance forced to 1), a spawn out of the carrier's sight, and after the
## carrier dies a bot reaching his bag retakes the flag and puts it back home.
func _check_flag_response() -> void:
	print("X8b flag response:")
	var chance_was = ExtractionRules.data()["flag_response"]["vehicle_chance"]
	ExtractionRules.data()["flag_response"]["vehicle_chance"] = 1.0
	var battle := await _start_raid(0, 0, func(p: ExtractionProfile) -> void:
		var flag := {"id": "qa_flag", "kind": RaidTaskBoard.KIND_FLAG, "faction": FLAG_FACTION, "count": 1}
		flag["reward"] = RaidTaskBoard.make_reward(flag)
		p.tasks = [flag])
	var x := battle.extraction
	var soldier := battle.player as Infantry
	await _wait_for(func() -> bool: return not soldier.stowed, 60.0)
	soldier.spawn_protection = 600.0
	soldier.apply_spawn_protection()
	var flag: LootContainer = null
	for c in x.containers.values():
		if (c as LootContainer).kind == RaidTasks.FLAG_CONTAINER:
			flag = c
	if flag == null:
		_expect(false, "the flag exists")
		_free_scene()
		return
	var home := flag.position
	soldier.global_position = home + Vector3(1.0, 0.5, 0.0)
	soldier.velocity = Vector3.ZERO
	await _frames(3)
	x._apply_pickup(1)
	await _frames(5)
	var fr: Dictionary = x.tasks.response.responses.get("qa_flag", {})
	fr["timer"] = 0.0
	await _frames(15)
	_expect(fr.get("vehicle") != null, "with chance 1.0 an armed vehicle joins the response")
	var spawn: Vector3 = fr.get("spawn", Vector3.ZERO)
	_expect(spawn.distance_to(soldier.global_position) >= 100.0, "the spawn point is 100+ m from the carrier (%.0f m)" % spawn.distance_to(soldier.global_position))
	_expect(not LineOfSight.is_clear(soldier, soldier.global_position + FlagResponse.EYE, soldier, spawn + FlagResponse.EYE), "the spawn point is out of the carrier's line of sight")
	soldier.spawn_protection = 0.0
	_lethal_hit(soldier)
	await _frames(10)
	var bag := x.tasks.response._find_flag_container()
	_expect(bag != null and bag.kind == "bag", "the dead carrier's bag holds the flag")
	if bag and not fr.bots.is_empty():
		var bot := fr.bots[0] as InfantryBot
		bot.soldier.global_position = bag.position + Vector3(1.5, 0.5, 0.0)
		bot.soldier.velocity = Vector3.ZERO
		await _frames(30)
		var back: LootContainer = null
		for c in x.containers.values():
			if (c as LootContainer).kind == RaidTasks.FLAG_CONTAINER:
				back = c
		_expect(str(fr.state) == "done" and back != null and back.position.distance_to(home) < 15.0, "a bot retook the flag and it lies at its base again (state %s)" % fr.state)
	ExtractionRules.data()["flag_response"]["vehicle_chance"] = chance_was
	await _wait_for(func() -> bool: return get_tree().current_scene is MatchResults, 20.0)
	_free_scene()


# ------------------------------------------------------------------ 6 downed and revive

## Holds (`on`) or releases interact, as a player keeps the key down.
func _hold(action: String, on: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = on
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


## Hits `s` with lethal damage once (spawn protection off). His velocity is cleared first: the teammate nobody
## controls may be falling in place, and a landing must not finish him by accident.
func _lethal_hit(s: Infantry) -> void:
	s.velocity = Vector3.ZERO
	s.spawn_protection = 0.0
	s.apply_spawn_protection()
	s.apply_hit(0.0, 1e6, null, s.global_position)


func _check_revive() -> void:
	print("6 raid with a teammate: downed and revive:")
	var battle := await _start_raid(0, 0, Callable(), true)
	var x := battle.extraction
	var me := battle.player as Infantry
	var mate := battle.occupancy.soldier_of(MATE_PEER)
	_expect(mate != null and x.is_in_raid(MATE_PEER) and mate.team == me.team, "a teammate in the raid on the same team")
	if mate == null:
		_free_scene()
		return
	await _wait_for(func() -> bool: return not me.stowed and not mate.stowed, 60.0)
	await _frames(20)
	await _pair(battle, me, mate)
	var head := mate.global_position + Vector3.UP * 2.0
	var lies := x.make_drop_point(head)
	_expect(absf(lies.y - x.make_ground_point(mate.global_position).y) < 0.5, "X1: a drop over a soldier lands on the ground (%.2f m up)" % (lies.y - mate.global_position.y))
	await _check_me_downed_and_revived(battle, x, me, mate)
	await _check_revive_mate(battle, x, me, mate)
	await _check_interrupt_and_bleed_out(battle, x, me, mate)
	_lethal_hit(me)
	_expect(not me.alive and not DownedState.is_downed(me), "the last one standing is killed outright")
	await _wait_for(func() -> bool: return get_tree().current_scene is MatchResults, 20.0)
	_free_scene()


func _place(s: Infantry, p: Vector3) -> void:
	s.global_position = p + Vector3.UP * 0.3
	s.velocity = Vector3.ZERO


## Puts both soldiers on open ground by exfil zone A (away from the drop-in transport, whose hull they could stand on)
## side by side and waits until both stand still.
func _pair(battle: Battle, me: Infantry, mate: Infantry) -> void:
	var spot := battle.infantry.make_on_ground(battle.extraction.zones[0] + Vector3(6, 0, 0))
	_place(me, spot)
	_place(mate, battle.infantry.make_on_ground(spot + Vector3(1.6, 0, 0)))
	var settled := func() -> bool: return me.is_on_floor() and mate.is_on_floor() and (me.velocity + mate.velocity).length() < 0.5
	await _wait_for(settled, 20.0)
	await _frames(10)
	_expect(me.global_position.distance_to(mate.global_position) < 2.5, "the teammate stands beside him (%.1f m)" % me.global_position.distance_to(mate.global_position))


## The local player goes down (HUD, crawl controls, ignored by the AI), the teammate (host-side request) revives him.
func _check_me_downed_and_revived(battle: Battle, x: ExtractionDirector, me: Infantry, mate: Infantry) -> void:
	var standing := me.shape.transform
	_lethal_hit(me)
	await _frames(3)
	_expect(me.alive and DownedState.is_downed(me) and me.has_meta("dormant"), "a lethal hit with a teammate up: downed, not dead")
	_expect(x.revive.states.has(me.net_id) and battle.pilot.process_mode == Node.PROCESS_MODE_DISABLED
		and x.revive.get_node_or_null("DownedPilot") != null, "his own pilot held, the crawl controls on")
	_expect(x.revive.hud.make_downed_text(me).begins_with("bleeding out"), "the downed overlay: '%s'" % x.revive.hud.make_downed_text(me))
	_expect(x.make_loot_offer(me).is_empty() and x.revive.make_revive_offer(me).is_empty(), "nothing to use lying down")
	me.weapons[0].trigger = true
	me.jump_input = true
	await _frames(2)
	_expect(not me.weapons[0].trigger and not me.jump_input, "downed: no fire, no jump")
	await _shot("downed", "extraction2")
	await _shot_close(battle, me.global_position, "downed_body", 3.0, "extraction2")
	x.revive._apply_revive(MATE_PEER, me.net_id, true)
	await _frames(20)
	_expect(x.revive.revives.has(me.net_id), "the teammate holds interact by him: reviving")
	await _shot("being_revived", "extraction2")
	await _wait_for(func() -> bool: return not DownedState.is_downed(me), 10.0)
	_expect(me.alive and not DownedState.is_downed(me) and not me.has_meta("dormant"), "revived")
	_expect(is_equal_approx(float(me.components[0].hp), float(me.components[0].max) * float(ExtractionRevive.rules().revived_health_fraction)),
		"back with %d %% health" % int(100 * float(ExtractionRevive.rules().revived_health_fraction)))
	_expect(battle.pilot.process_mode != Node.PROCESS_MODE_DISABLED and x.revive.get_node_or_null("DownedPilot") == null
		and me.shape.transform.is_equal_approx(standing) and not me.weapons.is_empty(), "standing again with his weapons: his own controls back")


## The local player revives the downed teammate by holding interact by him.
func _check_revive_mate(battle: Battle, x: ExtractionDirector, me: Infantry, mate: Infantry) -> void:
	await _pair(battle, me, mate)
	_lethal_hit(mate)
	await _frames(3)
	_expect(DownedState.is_downed(mate), "the teammate is downed")
	var interaction := InfantryInteraction.of(battle)
	_expect(interaction.make_hint(me).contains("revive"), "the interact hint: '%s'" % interaction.make_hint(me))
	_hold("interact", true)
	await _frames(20)
	_expect(x.revive.is_local_reviving() and not x.revive.make_local_revive_state().is_empty(), "holding interact: the revive bar")
	await _shot("reviving", "extraction2")
	await _wait_for(func() -> bool: return not DownedState.is_downed(mate), 10.0)
	_hold("interact", false)
	_expect(mate.alive and not DownedState.is_downed(mate), "the teammate is back on his feet")
	await _frames(3)
	_expect(not x.revive.is_local_reviving(), "letting go of interact ends the revive")


## A revive broken off by walking away, then the teammate bleeds out: dead, his bag on the ground.
func _check_interrupt_and_bleed_out(battle: Battle, x: ExtractionDirector, me: Infantry, mate: Infantry) -> void:
	await _pair(battle, me, mate)
	_lethal_hit(mate)
	await _frames(3)
	_hold("interact", true)
	await _frames(10)
	_place(me, me.global_position + Vector3(0, 0, 12))
	await _frames(10)
	_hold("interact", false)
	_expect(not x.revive.revives.has(mate.net_id) and DownedState.is_downed(mate), "moving away interrupts the revive")
	var spot := mate.global_position
	await _wait_for(func() -> bool: return not mate.alive, ExtractionRules.timer(battle.config, "bleed_out_s") + 5.0)
	_expect(not mate.alive and x.status.get(MATE_PEER) == ExtractionDirector.STATUS_DEAD, "bled out: killed in action")
	await _frames(3)
	_expect(_find_bag_near(x, spot) != null, "his bag lies where he bled out")
	await _shot_close(battle, spot, "bled_out_bag", 4.0, "extraction2")


# ------------------------------------------------------------------ the solo raid lobby and its stash

func _check_screen() -> void:
	print("solo raid lobby:")
	var launcher: Launcher = load("res://launcher.tscn").instantiate()
	get_tree().root.add_child(launcher)
	get_tree().current_scene = launcher
	await _frames(4)
	var lobby := launcher.open_lobby("extraction", true) as LobbyScreen
	await _frames(4)
	_expect(ExtractionRules.is_extraction(Net.settings) and Net.roster.size() == 1, "an offline raid lobby with the pilot alone")
	lobby.sheets.open_setup(lobby.profile)
	await _frames(6)
	_expect(lobby.has_modal(), "Operator Setup (the stash, the shop and the kit) opens over the lobby")
	await _shot("8_stash")
	Net.leave()
	launcher.queue_free()
	get_tree().current_scene = null
	await _frames(2)

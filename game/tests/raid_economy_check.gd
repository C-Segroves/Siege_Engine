extends Node
## The raid economy end to end, on one wallet (the OperatorProfile credits the store and the credits badge use):
##   raid 1: credits and a contraband item picked up through the loot window's host side (LootTransfer) are carried (the
##           raid HUD's inventory money), the extraction pays the credits into the wallet exactly once, the item reaches
##           the stash; Operator Setup's Sell (OperatorState.request_sell / apply_sell) turns it into its sell price in the
##           same wallet and the item leaves the stash.
##   raid 2: killed while carrying credits: the credits are dropped in the bag, the wallet does not change.
##   godot --audio-driver Dummy --path game res://tests/raid_economy_check.tscn

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const MAP := "tribes2:Katabatic"
const SEED := 4242
const SETTLE_FRAMES := 20
const WALLET := 777
const PILE := 135
const LOOT := "valuable/nav_computer"

var _pilot := "QA RaidEco %d" % OS.get_process_id()
var _failures := 0
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	_guard.back_up()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveGames.make_profile_path(ExtractionProfile.make_id(_pilot))))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveGames.make_profile_path(OperatorProfile.make_id(_pilot))))
	Net.player_name = _pilot
	var op := OperatorProfile.load_for(_pilot)
	op.credits = WALLET
	op.save()
	await get_tree().process_frame
	await _run()
	_guard.restore()
	print("raid_economy_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_expect(ExtractionItems.kind_of(LOOT) == "valuable" and ExtractionItems.make_sell_price(LOOT, 1) > 0, "the contraband item has a sell price from the rules (%d cr)" % ExtractionItems.make_sell_price(LOOT, 1))
	_expect(ExtractionProfile.load_for(_pilot).money == WALLET, "the extraction profile reads the operator's wallet, not a second one")
	# ---- raid 1: extract
	var battle := await _start_raid()
	var x := battle.extraction
	var me := battle.player as Infantry
	await _wait_for(func() -> bool: return not me.stowed, 60.0)
	await _frames(20)
	var inv: ExtractionInventory = x.inventories[1]
	inv.max_kg = 500.0
	inv.max_slots = 40
	var carried_before := inv.money
	var bag := _drop_bag(x, me, [[LOOT, 1]], PILE)
	_expect(bag != null, "a bag with credits and contraband lies beside the player")
	x.loot.apply_take_all(1, bag.container_id)
	await _frames(4)
	_expect(inv.money == carried_before + PILE and inv.count(LOOT) == 1, "the loot window's take-all put the credits and the item in the kit (%d cr carried)" % inv.money)
	_expect(OperatorProfile.load_for(_pilot).credits == WALLET, "carried credits are not in the wallet yet")
	var paid_expected := inv.money
	x.apply_extract(1)
	await _frames(4)
	var op := OperatorProfile.load_for(_pilot)
	_expect(op.credits == WALLET + paid_expected, "extraction paid exactly the carried %d cr into the wallet (%d)" % [paid_expected, op.credits - WALLET])
	_expect(ExtractionProfile.load_for(_pilot).money == op.credits, "and the extraction profile still sees the same wallet")
	var ex := ExtractionProfile.load_for(_pilot)
	_expect(ex.stash.count(LOOT) == 1, "the contraband came home to the stash")
	await _free_scene()
	# ---- sell through Operator Setup's state
	var state := OperatorState.make_for(op, LoadoutContext.make_for({"mode": ExtractionRules.MODE}))
	_expect(state.extraction != null and state.can_sell(LOOT), "the stash tab can sell the contraband")
	var asked := []
	state.confirm_requested.connect(func(message: String, _t: String, on_confirm: Callable) -> void:
		asked.append(message)
		on_confirm.call())
	var wallet_before := op.credits
	var options := state.make_sell_options(LOOT)
	_expect(options.size() >= 1 and str(options[0].label).begins_with("Sell 1") and str(options[0].label).contains(" cr"), "the row menu offers Sell 1 with its price: %s" % str(options.map(func(o): return o.label)))
	state.request_sell_option(LOOT, options.back())
	var price := ExtractionItems.make_sell_price(LOOT, 1)
	_expect(asked.size() == 1 and str(asked[0]).contains("Sell"), "selling asks first")
	_expect(op.credits == wallet_before + price, "the wallet rose by the sell price (%d cr)" % price)
	_expect(OperatorProfile.load_for(_pilot).credits == wallet_before + price and ExtractionProfile.load_for(_pilot).stash.count(LOOT) == 0,
		"saved: the credits are in the wallet and the item left the stash")
	_expect(not state.can_sell(LOOT), "nothing left to sell")
	# ---- raid 2: die with credits
	var wallet2 := OperatorProfile.load_for(_pilot).credits
	battle = await _start_raid()
	x = battle.extraction
	me = battle.player as Infantry
	await _wait_for(func() -> bool: return not me.stowed, 60.0)
	await _frames(20)
	inv = x.inventories[1]
	inv.money += PILE
	var spot := me.global_position
	me.spawn_protection = 0.0
	me.apply_spawn_protection()
	var n := 0
	while me.alive and n < 20:
		me.apply_hit(0.0, 1e6, null, me.global_position)
		n += 1
	await _frames(4)
	_expect(x.my_status == ExtractionDirector.STATUS_DEAD, "killed in action")
	var lost := x.find_container_near(spot)
	_expect(lost != null and lost.money >= PILE, "the carried credits lie in the bag where he fell")
	_expect(OperatorProfile.load_for(_pilot).credits == wallet2 and ExtractionProfile.load_for(_pilot).money == wallet2, "the wallet is unchanged by the lost credits")
	await _free_scene()


# ------------------------------------------------------------------ helpers

func _drop_bag(x: ExtractionDirector, s: Infantry, stacks: Array, money: int) -> LootContainer:
	for c in x.containers.values().duplicate():
		if (c as LootContainer).position.distance_to(s.global_position) < 12.0:
			x.apply_container_contents((c as LootContainer).container_id, [], 0)
	x.drop_stacks(stacks, money, s.global_position)
	return x.find_container_near(s.global_position)


func _start_raid() -> Battle:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": MAP, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = SEED
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


func _free_scene() -> void:
	var s := get_tree().current_scene
	if s:
		s.queue_free()
		get_tree().current_scene = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _frames(3)


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

extends Node
## The loot window (LootWindow, LootTransfer; "E on the items on the ground opens a window for that collection and
## your inventory in a separate window"): in a solo raid with a teammate,
##   interact opens it on a bag; Take 1, a stack, Take all; a refusal says why; Put back; drag and drop; credits
##   and ammunition merge; two players cannot take the same item and the open window follows the other's take;
##   closing leaves the rest; hits close it only when the setting says so; keys and pad (accept, secondary, zone, back)
##   godot --audio-driver Dummy --path game res://tests/loot_window_check.tscn [-- --shots=<dir>]
## --shots (needs a window): loot_window_desktop.png and loot_window_narrow.png.

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const MAP := "tribes2:Katabatic"
const SEED := 4242
const SETTLE_FRAMES := 20
const MATE_PEER := 2
const GUN := "weapon/tribes:DISC_LAUNCHER"
const AMMO := "ammo/tribes:DISC_LAUNCHER"
const AMMO_STACK := 15
const BAG_CREDITS := 120
const ROOMY_KG := 500.0
const ROOMY_SLOTS := 40
const DESKTOP_SIZE := Vector2i(1280, 720)
const NARROW_SIZE := Vector2i(700, 900)

var _pilot := "QA Loot %d" % OS.get_process_id()
var _failures := 0
var _shots := ""
var _guard := SavedCampaignGuard.new()
var _messages: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	_guard.back_up()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveGames.make_profile_path(ExtractionProfile.make_id(_pilot))))
	Net.player_name = _pilot
	await get_tree().process_frame
	await _run()
	_guard.restore()
	print("loot_window_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	var battle := await _start_raid()
	var x := battle.extraction
	var me := battle.player as Infantry
	var mate := battle.occupancy.soldier_of(MATE_PEER)
	_expect(x != null and me != null and mate != null, "a raid with a teammate")
	if mate == null:
		return
	await _wait_for(func() -> bool: return not me.stowed and not mate.stowed, 60.0)
	await _frames(20)
	x.notified.connect(func(text: String) -> void: _messages.append(text))
	_make_roomy(x.inventories[1])
	await _check_open_and_take(battle, x, me, mate)
	await _check_refusal_and_put_back(x, me)
	await _check_drag_and_drop(x, me)
	await _check_take_all_and_merge(x, me)
	await _check_two_players(battle, x, me, mate)
	await _check_close_leaves_rest(x, me)
	await _check_close_on_damage(x, me)
	await _check_keys(x, me)
	await _check_screens(x, me)
	await _free_scene()


# ------------------------------------------------------------------ checks

func _check_open_and_take(battle: Battle, x: ExtractionDirector, me: Infantry, mate: Infantry) -> void:
	print("open on interact, take one / a stack:")
	await _pair(battle, me, mate)
	var bag := _drop_bag(x, me, [[GUN, 2], [AMMO, 40]], BAG_CREDITS)
	_expect(bag != null, "a bag lies beside the player")
	var offer := InfantryInteraction.of(battle).make_offer(me)
	_expect(not offer.is_empty() and str(offer.text).begins_with("loot"), "interact offers the bag: '%s'" % offer.get("text", ""))
	_expect(InfantryInteraction.of(battle).apply_interact(me), "interact acts")
	await _frames(4)
	var w := LootWindow.find_open(x)
	_expect(w != null and w.container_id == bag.container_id, "interact opened the loot window on the bag")
	if w == null:
		return
	_expect(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and battle.pilot.process_mode == Node.PROCESS_MODE_DISABLED and not get_tree().paused,
		"the mouse is free, the controls held, the game not paused")
	_expect(w.container_pane.rows.get_child_count() == 3 and w.kit_pane.rows.get_child_count() > 0, "the bag (credits, gun, ammo) and the kit are listed")
	_expect(w.kit_pane.summary.text.contains("kg") and w.kit_pane.summary.text.contains("slots") and w.container_pane.summary.text.contains("items"),
		"weight, slots and the bag's size are shown")
	_expect(w.sheet.primary_button.text == "Take all" and not w.find_children("*", "ItemRow", true, false).is_empty(), "the shared sheet and item rows")
	var guns := x.my_inventory.count(GUN)
	_press_button(w.container_pane, "Take 1", GUN)
	await _frames(4)
	_expect(x.my_inventory.count(GUN) == guns + 1 and _count_in(bag, GUN) == 1, "Take 1 moved one gun")
	var rounds := x.my_inventory.count(AMMO)
	_press_button(w.container_pane, "Stack %d" % AMMO_STACK, AMMO)
	await _frames(4)
	_expect(x.my_inventory.count(AMMO) == rounds + AMMO_STACK and _count_in(bag, AMMO) == 40 - AMMO_STACK,
		"Take stack moved %d rounds, merged into the ammunition carried" % AMMO_STACK)
	var credits := x.my_inventory.money
	_press_button(w.container_pane, "Take all", LootTransfer.MONEY_ID)
	await _frames(4)
	_expect(x.my_inventory.money == credits + BAG_CREDITS and bag.money == 0, "credits merge into the wallet (%d)" % x.my_inventory.money)
	w.close()
	await _frames(2)
	_expect(LootWindow.find_open(x) == null and (DisplayServer.get_name() == "headless" or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
		and battle.pilot.process_mode == Node.PROCESS_MODE_INHERIT, "closing frees the mouse and the controls")


func _check_refusal_and_put_back(x: ExtractionDirector, me: Infantry) -> void:
	print("a refusal says why, put back:")
	var bag := x.find_container_near(me.global_position)
	var w := LootWindow.open(x, bag.container_id)
	await _frames(4)
	var inv: ExtractionInventory = x.inventories[1]
	inv.max_kg = inv.make_used_kg()
	x.send_inventory(1)
	await _frames(4)
	_messages.clear()
	var guns := x.my_inventory.count(GUN)
	_press_button(w.container_pane, "Take 1", GUN)
	await _frames(4)
	_expect(x.my_inventory.count(GUN) == guns and _messages.any(func(m: String) -> bool: return m.contains("Too heavy")),
		"over the weight limit: refused with the reason (%s)" % [_messages])
	_expect(w.container_pane.rows.find_children("*", "Label", true, false).any(func(l: Label) -> bool: return l.text.contains("will not fit")),
		"the row says it will not fit")
	_make_roomy(inv)
	inv.max_slots = inv.make_used_slots()
	x.send_inventory(1)
	await _frames(4)
	_messages.clear()
	_press_button(w.container_pane, "Take 1", GUN)
	await _frames(4)
	_expect(x.my_inventory.count(GUN) == guns and _messages.any(func(m: String) -> bool: return m.contains("No free slot")),
		"every slot used: refused with the reason (%s)" % [_messages])
	_make_roomy(inv)
	x.send_inventory(1)
	await _frames(4)
	var held := x.my_inventory.count(AMMO)
	var in_bag := _count_in(bag, AMMO)
	_press_button(w.kit_pane, "Put 1", AMMO)
	await _frames(4)
	_expect(_count_in(bag, AMMO) == in_bag + 1 and x.my_inventory.count(AMMO) == held - 1, "Put 1 moved a round back into the bag")
	w.close()
	await _frames(2)


func _check_drag_and_drop(x: ExtractionDirector, me: Infantry) -> void:
	print("drag and drop:")
	var bag := x.find_container_near(me.global_position)
	var w := LootWindow.open(x, bag.container_id)
	await _frames(4)
	var rounds := x.my_inventory.count(AMMO)
	var in_bag := _count_in(bag, AMMO)
	var row_data := {"from": LootWindow.SIDE_CONTAINER, "item": AMMO, "units": in_bag}
	_expect(w.kit_pane.make_accepts(row_data) and not w.container_pane.make_accepts(row_data), "a bag row is accepted by the kit window only")
	w.kit_pane.apply_drop(row_data)
	await _frames(4)
	_expect(x.my_inventory.count(AMMO) == rounds + in_bag and _count_in(bag, AMMO) == 0, "dropping a bag row on the kit takes all of it")
	w.container_pane.apply_drop({"from": LootWindow.SIDE_KIT, "item": AMMO, "units": 5})
	await _frames(4)
	_expect(_count_in(bag, AMMO) == 5, "dropping kit rounds on the bag puts them back")
	var row := w.kit_pane.rows.get_child(0) as Control
	var dragged = w._make_drag_data(Vector2.ZERO, row, row_data, "row")
	_expect(dragged is Dictionary and dragged.item == AMMO, "a row hands its item to the drag")
	w.close()
	await _frames(2)


func _check_take_all_and_merge(x: ExtractionDirector, me: Infantry) -> void:
	print("take all:")
	var bag := _drop_bag(x, me, [[AMMO, 10], [GUN, 1]], 30)
	var bag_id := bag.container_id
	var rounds := x.my_inventory.count(AMMO)
	var credits := x.my_inventory.money
	var w := LootWindow.open(x, bag.container_id)
	await _frames(4)
	w.sheet.primary_button.pressed.emit()
	await _frames(6)
	_expect(x.my_inventory.count(AMMO) == rounds + 10 and x.my_inventory.money == credits + 30, "Take all took the rounds (merged) and the credits")
	_expect(not x.containers.has(bag_id), "the emptied bag is gone")
	_expect(LootWindow.find_open(x) == null, "the window closes when its container is emptied")


func _check_two_players(battle: Battle, x: ExtractionDirector, me: Infantry, mate: Infantry) -> void:
	print("two players, one item:")
	await _pair(battle, me, mate)
	var bag := _drop_bag(x, me, [[GUN, 1], [AMMO, 7]], 0)
	_make_roomy(x.inventories[MATE_PEER])
	var w := LootWindow.open(x, bag.container_id)
	await _frames(4)
	var mine: int = x.inventories[1].count(GUN)
	var his: int = x.inventories[MATE_PEER].count(GUN)
	_messages.clear()
	x.loot.apply_take(MATE_PEER, bag.container_id, GUN, 1)
	x.loot.apply_take(1, bag.container_id, GUN, 1)
	await _frames(4)
	_expect(x.inventories[MATE_PEER].count(GUN) == his + 1 and x.inventories[1].count(GUN) == mine, "the gun went to the first asker only")
	_expect(_messages.any(func(m: String) -> bool: return m.contains("Already taken")), "the second player was told it is already taken (%s)" % [_messages])
	var texts := w.container_pane.rows.find_children("*", "Label", true, false).map(func(l: Label) -> String: return l.text)
	_expect(not texts.any(func(t: String) -> bool: return t.begins_with("Disc Launcher") and not t.contains("ammo")),
		"the open window followed the other player's take (no gun row left: %s)" % [texts])
	x.loot.apply_take(MATE_PEER, bag.container_id, AMMO, 7)
	await _frames(4)
	_expect(LootWindow.find_open(x) == null, "and it closed when he emptied the bag")


func _check_close_leaves_rest(x: ExtractionDirector, me: Infantry) -> void:
	print("closing leaves the rest:")
	var bag := _drop_bag(x, me, [[GUN, 1], [AMMO, 30]], 50)
	var w := LootWindow.open(x, bag.container_id)
	await _frames(4)
	_press_button(w.container_pane, "Take 1", GUN)
	await _frames(4)
	w.close()
	await _frames(3)
	_expect(x.containers.has(bag.container_id) and _count_in(bag, AMMO) == 30 and bag.money == 50 and _count_in(bag, GUN) == 0,
		"the bag keeps what was left (30 rounds, 50 cr)")
	var here := me.global_position
	LootWindow.open(x, bag.container_id)
	await _frames(3)
	me.global_position = here + Vector3(30, 0, 0)
	await _frames(3)
	_expect(LootWindow.find_open(x) == null, "walking away closes it")
	me.global_position = here
	await _frames(3)


func _check_close_on_damage(x: ExtractionDirector, me: Infantry) -> void:
	print("close on damage (a setting):")
	var bag := x.find_container_near(me.global_position)
	LootSettings.apply_close_on_damage(false)
	LootWindow.open(x, bag.container_id)
	await _frames(3)
	me.damaged.emit(me, null)
	await _frames(2)
	_expect(LootWindow.find_open(x) != null, "off: a hit leaves the window open and the game running")
	LootSettings.apply_close_on_damage(true)
	me.damaged.emit(me, null)
	await _frames(2)
	_expect(LootWindow.find_open(x) == null, "on: a hit closes it")
	LootSettings.apply_close_on_damage(false)


func _check_keys(x: ExtractionDirector, me: Infantry) -> void:
	print("keyboard and pad:")
	var bag := x.find_container_near(me.global_position)
	var w := LootWindow.open(x, bag.container_id)
	await _frames(4)
	var focus := get_viewport().gui_get_focus_owner()
	_expect(focus != null and w.container_pane.is_ancestor_of(focus), "focus starts on the bag's first row")
	var item := str(focus.get_meta(LootWindow.ITEM_META)) if focus else ""
	var held := _held(x, item)
	_press("ui_accept")
	await _frames(4)
	_expect(_held(x, item) > held, "accept took from the focused row (%s)" % item)
	_press("menu_zone_next")
	await _frames(3)
	focus = get_viewport().gui_get_focus_owner()
	_expect(focus != null and w.kit_pane.is_ancestor_of(focus), "menu_zone_next jumps to the kit window")
	item = str(focus.get_meta(LootWindow.ITEM_META)) if focus else ""
	var in_bag := _in_bag(bag, item)
	_press("menu_secondary")
	await _frames(4)
	_expect(_in_bag(bag, item) == in_bag + 1, "menu_secondary put one back (%s)" % item)
	_press("menu_back")
	await _frames(3)
	_expect(LootWindow.find_open(x) == null, "menu_back closes it")
	_press("interact")
	await _frames(4)
	_expect(LootWindow.find_open(x) != null, "the interact key opens it")
	_press("interact")
	await _frames(3)
	_expect(LootWindow.find_open(x) == null, "and closes it")


func _check_screens(x: ExtractionDirector, me: Infantry) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	print("screens:")
	var gear := str(ExtractionItems.items_of_kind("gear")[0].id)
	var bag := _drop_bag(x, me, [[GUN, 2], [AMMO, 40], [gear, 3]], 85)
	var w := LootWindow.open(x, bag.container_id)
	for entry in [["desktop", DESKTOP_SIZE], ["narrow", NARROW_SIZE]]:
		get_window().size = entry[1]
		await _frames(12)
		await RenderingServer.frame_post_draw
		var path := "%s/loot_window_%s.png" % [_shots, entry[0]]
		get_viewport().get_texture().get_image().save_png(path)
		print("  shot ", path)
	w.close()
	await _frames(2)


# ------------------------------------------------------------------ helpers

func _make_roomy(inv: ExtractionInventory) -> void:
	inv.max_kg = ROOMY_KG
	inv.max_slots = ROOMY_SLOTS


## A bag with `stacks` and `money` on the ground by `s`, the bags already there emptied (the host's drop).
func _drop_bag(x: ExtractionDirector, s: Infantry, stacks: Array, money: int) -> LootContainer:
	for c in x.containers.values().duplicate():
		if (c as LootContainer).position.distance_to(s.global_position) < 12.0:
			x.apply_container_contents((c as LootContainer).container_id, [], 0)
	x.drop_stacks(stacks, money, s.global_position)
	return x.find_container_near(s.global_position)


func _count_in(c: LootContainer, id: String) -> int:
	for st in c.stacks:
		if str(st[0]) == id:
			return int(st[1])
	return 0


func _in_bag(c: LootContainer, id: String) -> int:
	return c.money if id == LootTransfer.MONEY_ID else _count_in(c, id)


func _held(x: ExtractionDirector, id: String) -> int:
	return x.my_inventory.money if id == LootTransfer.MONEY_ID else x.my_inventory.count(id)


## Presses the first button named `text` on the row of `item_id` in `pane`.
func _press_button(pane: LootPane, text: String, item_id: String) -> void:
	for b in pane.rows.find_children("*", "Button", true, false):
		if (b as Button).text == text and b.get_meta(LootWindow.ITEM_META, "") == item_id:
			(b as Button).pressed.emit()
			return
	_expect(false, "a '%s' button for %s" % [text, item_id])


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


func _place(s: Infantry, p: Vector3) -> void:
	s.global_position = p + Vector3.UP * 0.3
	s.velocity = Vector3.ZERO


## Both soldiers side by side on open ground by exfil zone A.
func _pair(battle: Battle, me: Infantry, mate: Infantry) -> void:
	var spot := battle.infantry.make_on_ground(battle.extraction.zones[0] + Vector3(6, 0, 0))
	_place(me, spot)
	_place(mate, battle.infantry.make_on_ground(spot + Vector3(1.6, 0, 0)))
	await _wait_for(func() -> bool: return me.is_on_floor() and mate.is_on_floor() and (me.velocity + mate.velocity).length() < 0.5, 20.0)
	await _frames(SETTLE_FRAMES)
	await _wait_for(func() -> bool: return me.is_on_floor() and mate.is_on_floor() and (me.velocity + mate.velocity).length() < 0.5, 20.0)


func _start_raid() -> Battle:
	var p := ExtractionProfile.load_for(_pilot)
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": MAP, "respawn": true}, 0, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = SEED
	var mate := {"name": "QA Mate", "team": 0, "kit": p.make_kit_dict()}
	MatchFlow.apply_extraction_entry(mate, 1, true)
	config.roster[MATE_PEER] = mate
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

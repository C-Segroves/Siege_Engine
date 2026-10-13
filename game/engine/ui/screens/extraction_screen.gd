extends LauncherScreen
## Extraction mode between raids (docs/design/extraction.md section 5): the pilot's profile (ExtractionProfile),
## his raid kit (armour and the items he takes along), his stash and the shop (ExtractionShop), and for a solo raid
## the map and the size of the AI factions. Every change is saved at once. args: {"return_to": "lobby"} when opened
## from the LAN lobby (Done returns there and announces the kit), else the primary action starts a solo raid.

const PAGE_SIZE := 6
const DEFAULT_SOLDIERS := 10
const DEFAULT_VEHICLES := 3
const MAX_VEHICLES := 12
## Maps preferred for the default choice (big Tribes / Tribes 2 / Starsiege maps), by entry name.
const PREFERRED_MAPS := ["Tribes 2 map - Katabatic", "Tribes map - Raindance", "Tribes 2 map", "Tribes map", "Starsiege map"]

var _profile: ExtractionProfile
var _return_to := ""
var _summary: Label
var _armor: OptionButton
var _armors: Array = []
var _kit_box: VBoxContainer
var _tasks_box: VBoxContainer
var _stash_box: VBoxContainer
var _shop_box: VBoxContainer
var _category: OptionButton
var _game: OptionButton
var _games: Array = []
var _map: MapPicker
var _soldiers: HSlider
var _vehicles: HSlider
var _stash_page := 0
var _shop_page := 0


func open(args: Dictionary) -> void:
	_return_to = str(args.get("return_to", ""))
	_profile = ExtractionProfile.load_for(Net.player_name)
	set_page_title("extraction  -  stash and shop")
	if _return_to == "lobby":
		set_back("Back to lobby", _done)
		set_primary("Done", _done)
	else:
		set_back("Back", router.back)
		set_primary("Start raid", _start_raid)
	_summary = Widgets.paragraph("", "DimLabel")
	content.add_child(_summary)
	_build_kit_section()
	_build_tasks_section()
	_build_stash_section()
	_build_shop_section()
	if _return_to != "lobby":
		_build_raid_section()
	_refresh()


# ------------------------------------------------------------------ building

func _build_kit_section() -> void:
	content.add_child(Widgets.section("Raid kit (lost if you die, armour included, except the insured slot)"))
	_armor = Widgets.option_button([])
	_armor.item_selected.connect(func(i: int) -> void: _change(func() -> void: _profile.apply_kit_armor(str(_armors[i]))))
	content.add_child(OptionRow.new("Armor", _armor))
	_kit_box = VBoxContainer.new()
	content.add_child(_kit_box)
	content.add_child(Widgets.button("Re-equip last raid's kit", func() -> void: _change(_profile.apply_refill_last_kit)))


func _build_tasks_section() -> void:
	content.add_child(Widgets.section("Raid tasks (paid when you extract)"))
	_tasks_box = VBoxContainer.new()
	content.add_child(_tasks_box)


## The task board (RaidTaskBoard): Take / Drop per task, at most max_picked taken.
func _fill_tasks() -> void:
	_clear(_tasks_box)
	_tasks_box.add_child(Widgets.label(ExtractionScreenText.make_tasks_summary(_profile), "DimLabel"))
	for task in _profile.make_task_board():
		var id := str(task.id)
		var taken := _profile.is_task_taken(id)
		var button := Widgets.small_button("Drop" if taken else "Take", func() -> void:
			_change(func() -> void: _profile.apply_drop_task(id) if taken else _profile.apply_take_task(id)))
		button.disabled = not taken and _profile.tasks.size() >= RaidTaskBoard.make_max_picked()
		_tasks_box.add_child(ItemRow.make(RaidTaskBoard.make_text(task) + ("   [TAKEN]" if taken else ""),
			ExtractionRules.make_money_text(int(task.reward)), [button]))


func _build_stash_section() -> void:
	content.add_child(Widgets.section("Stash"))
	_stash_box = VBoxContainer.new()
	content.add_child(_stash_box)


func _build_shop_section() -> void:
	content.add_child(Widgets.section("Shop"))
	_category = Widgets.option_button(ExtractionShop.BUY_CATEGORIES.map(func(k: String) -> String:
		return str(ExtractionRules.item_kind(k).get("label", k))))
	_category.item_selected.connect(func(_i: int) -> void: _shop_page = 0; _refresh())
	content.add_child(OptionRow.new("Category", _category))
	_games = [""]
	_games.append_array(Packs.packs.keys())
	_game = Widgets.option_button(_games.map(func(p: String) -> String: return "All games" if p == "" else Packs.pack_name(p)))
	_game.item_selected.connect(func(_i: int) -> void: _shop_page = 0; _refresh())
	content.add_child(OptionRow.new("Game", _game))
	_shop_box = VBoxContainer.new()
	content.add_child(_shop_box)


func _build_raid_section() -> void:
	content.add_child(Widgets.section("Solo raid"))
	_map = MapPicker.new("Map")
	_map.select_index(make_default_map_index())
	content.add_child(_map)
	_soldiers = Widgets.slider(0, InfantryBots.MAX_BOTS, DEFAULT_SOLDIERS)
	content.add_child(OptionRow.new("Faction soldiers", _soldiers).with_value_readout())
	_vehicles = Widgets.slider(0, MAX_VEHICLES, DEFAULT_VEHICLES)
	content.add_child(OptionRow.new("Faction vehicles", _vehicles).with_value_readout())


## The first preferred map installed (an Earthsiege world when none is).
static func make_default_map_index() -> int:
	var entries := MapPicker.make_entries()
	for wanted in PREFERRED_MAPS:
		for i in entries.size():
			if str(entries[i].name).begins_with(wanted):
				return i
	return 0


# ------------------------------------------------------------------ lists

func _refresh() -> void:
	_summary.text = ExtractionScreenText.make_profile_summary(_profile)
	_fill_kit()
	_fill_tasks()
	_fill_stash()
	_fill_shop()


func _clear(box: Container) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _fill_kit() -> void:
	_clear(_kit_box)
	_armors = _profile.make_wearable_armors()
	_armor.clear()
	for armor_id in _armors:
		_armor.add_item(ExtractionScreenText.make_armor_name(armor_id) + ExtractionScreenText.make_armor_cost_text(armor_id))
	_armor.select(maxi(_armors.find(_profile.kit_armor), 0))
	_kit_box.add_child(Widgets.label(ExtractionScreenText.make_kit_summary(_profile), "DimLabel"))
	_kit_box.add_child(Widgets.label(ExtractionScreenText.make_insured_text(_profile), "DimLabel"))
	var ids: Array = _profile.kit.stacks.keys()
	if not ExtractionItems.is_free_armor(_profile.kit_armor):
		ids.push_front(ExtractionItems.make_armor_id(_profile.kit_armor))
	for id in ids:
		var units := maxi(_profile.kit.count(id), 1)
		var insured: bool = id == _profile.make_insured_id()
		var buttons := [Widgets.small_button("Uninsure" if insured else "Insure", func() -> void:
			_change(_profile.apply_uninsure if insured else func() -> void: _profile.apply_insure(id)))]
		if _profile.kit.count(id) > 0:
			buttons.append(Widgets.small_button("To stash", func() -> void: _change(func() -> void: _profile.apply_move_to_stash(id, units))))
		_kit_box.add_child(ItemRow.make(ExtractionItems.make_stack_text(id, units) + ("   [INSURED]" if insured else ""),
			ExtractionScreenText.make_item_detail(id, units), buttons))


func _fill_stash() -> void:
	_clear(_stash_box)
	var ids := _profile.stash.stacks.keys()
	if ids.is_empty():
		_stash_box.add_child(Widgets.label("Empty.", "DimLabel"))
		return
	_stash_page = clampi(_stash_page, 0, (ids.size() - 1) / PAGE_SIZE)
	for id in ids.slice(_stash_page * PAGE_SIZE, (_stash_page + 1) * PAGE_SIZE):
		_stash_box.add_child(_make_stash_row(str(id)))
	_stash_box.add_child(_make_pager(ids.size(), _stash_page, func(p: int) -> void: _stash_page = p; _refresh()))


func _make_stash_row(id: String) -> ItemRow:
	var units := _profile.stash.count(id)
	var lot := ExtractionShop.make_buy_units(id)
	var buttons := [Widgets.small_button("To kit", func() -> void: _move_to_kit(id, lot)),
		Widgets.small_button("Sell", func() -> void: _change(func() -> void: ExtractionShop.apply_sell(_profile, id, units)))]
	return ItemRow.make(ExtractionItems.make_stack_text(id, units), ExtractionScreenText.make_item_detail(id, units), buttons)


func _fill_shop() -> void:
	_clear(_shop_box)
	var offers := ExtractionShop.make_offers(ExtractionShop.BUY_CATEGORIES[_category.selected], str(_games[_game.selected]))
	if offers.is_empty():
		_shop_box.add_child(Widgets.label("Nothing on offer from the installed games.", "DimLabel"))
		return
	_shop_page = clampi(_shop_page, 0, (offers.size() - 1) / PAGE_SIZE)
	for r in offers.slice(_shop_page * PAGE_SIZE, (_shop_page + 1) * PAGE_SIZE):
		var id := str(r.id)
		var price := ExtractionShop.make_buy_price(id)
		var buy := Widgets.small_button("Buy  %s" % ExtractionRules.make_money_text(price), func() -> void: _buy(id), Widgets.PRIMARY)
		buy.disabled = _profile.money < price
		_shop_box.add_child(ItemRow.make(ExtractionItems.make_stack_text(id, ExtractionShop.make_buy_units(id)),
			"%s  -  %.1f kg" % [Packs.pack_name(str(r.pack)) if str(r.pack) != "" else "any game", float(r.kg) * ExtractionShop.make_buy_units(id)], [buy]))
	_shop_box.add_child(_make_pager(offers.size(), _shop_page, func(p: int) -> void: _shop_page = p; _refresh()))


## "Previous  page 2 / 5  Next" (nothing when everything fits on one page).
func _make_pager(total: int, page: int, go_to: Callable) -> Control:
	var pages := int(ceil(float(total) / PAGE_SIZE))
	if pages <= 1:
		return Control.new()
	var prev := Widgets.small_button("Previous", func() -> void: go_to.call(page - 1))
	prev.disabled = page <= 0
	var next := Widgets.small_button("Next", func() -> void: go_to.call(page + 1))
	next.disabled = page >= pages - 1
	return Widgets.row([prev, Widgets.label("page %d / %d" % [page + 1, pages], "DimLabel"), next])


# ------------------------------------------------------------------ actions

## Runs `change` on the profile, saves it and redraws.
func _change(change: Callable) -> void:
	change.call()
	_profile.save()
	_refresh()


func _move_to_kit(id: String, units: int) -> void:
	var moved := _profile.apply_move_to_kit(id, units)
	_profile.save()
	set_status("" if moved > 0 else "No room in the kit for %s." % ExtractionItems.make_name(id))
	_refresh()


func _buy(id: String) -> void:
	if ExtractionShop.apply_buy(_profile, id):
		_profile.save()
		set_status("Bought %s." % ExtractionItems.make_stack_text(id, ExtractionShop.make_buy_units(id)))
	else:
		set_status("Not enough money.")
	_refresh()


func _done() -> void:
	Net.set_my_info("kit", _profile.make_kit_dict())
	router.back()


func _start_raid() -> void:
	if _profile.kit.is_empty():
		set_status("Your kit is empty: move something from the stash, or buy it.")
		return
	_profile.save()
	launcher().start_battle(MatchFlow.make_extraction_solo_config(_profile, _map.selected_config(), int(_soldiers.value),
		int(_vehicles.value)))

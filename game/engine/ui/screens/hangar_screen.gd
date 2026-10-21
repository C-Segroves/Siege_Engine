class_name HangarScreen
extends RoutedScreen
## The campaign hangar, one screen for every game (Earthsiege career and campaign, Earthsiege 2,
## Starsiege, the saga, the co-op campaign host). Two tabs:
##   Hercs  the garage's Hercs (select) with their condition, the selected Herc's name, repair (one /
##          all, for salvage), weapons per hardpoint (counted weapons move between the armory and the
##          hardpoints, fabricated ones cost salvage), Scrap (confirmed, pays its parts' worth) and
##          Build (the Hercs the campaign offers, with the reason, price and build time; disabled when
##          the pool can't pay), the armory stock;
##   Crew   pilots in the Hercs, the wingmen for the next mission, the roster and losses (CrewPanel).
## The salvage pool is shown above the tabs. What may be built, armed and what it costs comes from the
## campaign's availability context and its economy (GarageEconomy); nothing here depends on the game.
## The selected Herc stands in the 3D hangar with its damage showing; a Herc type picked under Build
## is previewed there.
##
## open(args):
##   garage         Garage to edit
##   availability   Callable() -> Dictionary: the campaign's CampaignAvailability context, its
##                  salvage_stock being the armory the garage draws from, its economy the prices
##   wingman_slots  wingmen the next mission takes (SquadRoster; default 0)
##   tab            "hercs" (default) or "crew"
##   player_name    who flies the selected Herc (default the app's pilot name)
##   heading        line under the title (campaign and mission)
##   done_text      primary action label ("Back to briefing")
##   on_done        Callable() leaving the screen (Back, menu_back and the primary action)
##   on_changed     Callable() after every change (optional: save the career)

const TAB_HERCS := "hercs"
const TAB_CREW := "crew"
const SCRAP_QUESTION := "Scrap %s? Its counted weapons go back to the armory%s."
const SCRAP_VALUE := " and its parts bring %s"
const UNLIMITED_ARMORY := "Every weapon this campaign offers is unlimited; nothing counted in stock."
const POOL_TEXT := "Salvage: %s"
const NO_ECONOMY := "No salvage economy: Hercs and weapons come from the campaign's inventories."
const PRICE_TEXT := "Price %s, ready %s  -  salvage %s"
const READY_AT_ONCE := "at once"
const READY_AFTER := "after %d mission(s)"
const CONDITION_TEXT := "Condition %d %%%s"
const FACTORY_TEXT := "  -  in the factory, ready after %d mission(s)"
const REPAIR_TEXT := "Repair to 100 %%: %s  -  all Hercs: %s"
const NOTHING_TO_REPAIR := "No repairs needed."
const SHORT_OF_SALVAGE := "Not enough salvage (%s needed)."

var garage: Garage
var _availability: Callable
var _on_changed: Callable
var _slots := 0
var _pool: Label
var _tab_buttons := {}
var _tabs := {}
var _hercs: VBoxContainer
var _details: VBoxContainer
var _editor: LoadoutEditor
var _build: VehiclePicker
var _build_button: Button
var _build_price: Label
var _armory: Label
var _crew: CrewPanel


func open(args: Dictionary) -> void:
	garage = args.garage
	_availability = args.availability
	_on_changed = args.get("on_changed", Callable())
	_slots = int(args.get("wingman_slots", 0))
	set_page_title("hangar")
	set_back("Back", args.on_done)
	set_primary(str(args.get("done_text", "Done")), args.on_done)
	show_hangar()
	content.add_child(Widgets.paragraph(str(args.get("heading", "")), "DimLabel"))
	_pool = Widgets.label("", "StatusLabel")
	content.add_child(_pool)
	content.add_child(_build_tab_bar())
	content.add_child(_build_hercs_tab())
	_crew = CrewPanel.new(garage, _slots, str(args.get("player_name", Net.player_name)))
	_crew.changed.connect(_notify_changed)
	_tabs[TAB_CREW] = _crew
	content.add_child(_crew)
	show_tab(str(args.get("tab", TAB_HERCS)))
	_refresh()


## The context the garage's rules use right now (rebuilt after every change: tech, stock).
func make_context() -> Dictionary:
	return _availability.call()


func economy() -> GarageEconomy:
	return GarageEconomy.of_context(make_context())


## Shows tab `tab` ("hercs" / "crew").
func show_tab(tab: String) -> void:
	var shown := tab if _tabs.has(tab) else TAB_HERCS
	for t in _tabs:
		(_tabs[t] as Control).visible = t == shown
		(_tab_buttons[t] as Button).theme_type_variation = Widgets.PRIMARY if t == shown else ""
	if shown == TAB_CREW:
		_crew.refresh()


# ------------------------------------------------------------------ layout

func _build_tab_bar() -> Control:
	for t in [TAB_HERCS, TAB_CREW]:
		_tab_buttons[t] = Widgets.small_button(t.capitalize(), show_tab.bind(t))
	return Widgets.row(_tab_buttons.values())


func _build_hercs_tab() -> Control:
	var box := VBoxContainer.new()
	_hercs = VBoxContainer.new()
	box.add_child(_hercs)
	_details = VBoxContainer.new()
	box.add_child(_details)
	box.add_child(_build_build_section())
	box.add_child(Widgets.section("Armory stock"))
	_armory = Widgets.paragraph("", "DimLabel")
	box.add_child(_armory)
	_tabs[TAB_HERCS] = box
	return box


func _refresh() -> void:
	var ctx := make_context()
	_pool.text = POOL_TEXT % GarageEconomy.make_tons_text(garage.salvage_kg) if economy().is_enabled() else NO_ECONOMY
	_fill_herc_list()
	_fill_details(ctx)
	_armory.text = make_armory_text(ctx)
	_update_build_price()
	_show_selected()


func _fill_herc_list() -> void:
	_clear(_hercs)
	_hercs.add_child(Widgets.section("Your Hercs  (%d of %d)" % [garage.vehicles.size(), Garage.MAX_VEHICLES]))
	for i in garage.vehicles.size():
		var b := Widgets.button(GaragePicker.make_entry_label(garage.vehicles[i]), _select_herc.bind(i),
			Widgets.PRIMARY if i == garage.selected else "")
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_hercs.add_child(b)


func _fill_details(ctx: Dictionary) -> void:
	_clear(_details)
	var e := garage.selected_entry()
	if e.is_empty():
		return
	_details.add_child(Widgets.section("Selected Herc"))
	var herc_name := Widgets.line_edit(str(e.name))
	herc_name.text_submitted.connect(_rename)
	herc_name.focus_exited.connect(func() -> void: _rename(herc_name.text))
	_details.add_child(OptionRow.new("Herc name", herc_name))
	_details.add_child(_build_condition_row(ctx, e))
	_editor = LoadoutEditor.new()
	_editor.setup(str(e.vehicle), e.loadout, ctx, e.get("mounts", []))
	_editor.changed.connect(_on_loadout_edited)
	_editor.mounts_changed.connect(_on_mounts_edited)
	_editor.hardpoint_focused.connect(func(i: int) -> void:
		_show_selected()
		hangar.highlight_hardpoint(i))
	_details.add_child(_editor)
	var scrap := Widgets.button("Scrap this Herc", _ask_scrap, Widgets.DANGER)
	scrap.disabled = not garage.can_scrap()
	_details.add_child(scrap)


## Condition, what repairing costs and the Repair / Repair all buttons.
func _build_condition_row(ctx: Dictionary, e: Dictionary) -> Control:
	var box := VBoxContainer.new()
	var factory := FACTORY_TEXT % int(e.build_left) if not Garage.is_ready(e) else ""
	box.add_child(Widgets.label(CONDITION_TEXT % [HercCondition.make_percent(str(e.vehicle), e.condition), factory]))
	var one := garage.make_repair_cost(ctx, garage.selected)
	var all := garage.make_repair_all_cost(ctx)
	if all <= 0:
		box.add_child(Widgets.label(NOTHING_TO_REPAIR, "DimLabel"))
		return box
	box.add_child(Widgets.label(REPAIR_TEXT % [GarageEconomy.make_tons_text(one), GarageEconomy.make_tons_text(all)], "DimLabel"))
	var repair := Widgets.small_button("Repair", _repair_selected)
	repair.disabled = one <= 0 or garage.make_affordable_repair(ctx, garage.selected) <= 0.0
	var repair_all := Widgets.small_button("Repair all", _repair_all)
	repair_all.disabled = garage.salvage_kg <= 0
	box.add_child(Widgets.row([repair, repair_all]))
	return box


func _build_build_section() -> Control:
	var box := VBoxContainer.new()
	box.add_child(Widgets.section("Build"))
	_build = VehiclePicker.new("Herc type")
	var ctx := make_context()
	_build.set_availability(ctx)
	var own_first := VehiclePicker.make_native_default(ctx)
	if own_first != "":
		_build.select_vehicle(own_first)   # the campaign's own Herc, not an older design from another game
	_build.vehicle_selected.connect(_preview_build)
	box.add_child(_build)
	_build_price = Widgets.label("", "DimLabel")
	box.add_child(_build_price)
	_build_button = Widgets.button("Build", _build_selected_type, Widgets.PRIMARY)
	box.add_child(_build_button)
	return box


## The picked type's price and build time; Build is disabled when it can't be built now.
func _update_build_price() -> void:
	var vid := _build.selected_id()
	var ctx := make_context()
	_build_button.disabled = vid == "" or not garage.can_build(ctx, vid)
	_build_price.visible = economy().is_enabled()
	if not _build_price.visible or vid == "":
		return
	var missions := economy().make_build_missions(vid)
	_build_price.text = PRICE_TEXT % [GarageEconomy.make_tons_text(economy().make_vehicle_price(vid)),
		READY_AFTER % missions if missions > 0 else READY_AT_ONCE, GarageEconomy.make_tons_text(garage.salvage_kg)]


## "ATC20 x4, LAS100 x5" - the counted weapons left in the armory.
static func make_armory_text(ctx: Dictionary) -> String:
	var parts: PackedStringArray = []
	var stock: Dictionary = ctx.get("salvage_stock", {})
	var ids := stock.keys()
	ids.sort()
	for wid in ids:
		if int(stock[wid]) > 0:
			var w := Packs.weapon(str(wid))
			parts.append("%s  [%s] x%d" % [w.get("display_name", w.get("name", wid)), Packs.pack_name(str(w.get("pack", ""))), int(stock[wid])])
	return ", ".join(parts) if not parts.is_empty() else UNLIMITED_ARMORY


func _show_selected() -> void:
	var e := garage.selected_entry()
	if e.is_empty():
		return
	hangar.show_herc(str(e.vehicle), e.loadout)
	_show_damage.call_deferred(str(e.vehicle), e.condition)
	var v := Packs.vehicle(str(e.vehicle))
	hangar.set_caption("%s  -  %s" % [GaragePicker.make_entry_name(e), Packs.pack_name(str(v.get("pack", "")))])


## The selected Herc's damaged parts on the bay's model (once the model is built).
func _show_damage(vid: String, condition: Array) -> void:
	if hangar != null and hangar.bay.vehicle_id == vid:
		HercCondition.apply_to_model(hangar.bay.model, vid, condition)


func _preview_build(vid: String) -> void:
	hangar.show_herc(vid, Packs.vehicle(vid).get("loadout", []))
	_show_damage.call_deferred(vid, [])
	var reason := _build.reason_of(vid)
	hangar.set_caption("Build: %s%s" % [VehiclePicker.make_caption(Packs.vehicle(vid)), "  -  " + reason if reason != "" else ""])
	_update_build_price()


# ------------------------------------------------------------------ actions

func _select_herc(i: int) -> void:
	garage.apply_select(i)
	_after_change()
	_focus_herc_button.call_deferred(i)


func _rename(text: String) -> void:
	if text.strip_edges() == "" or text == str(garage.selected_entry().get("name", "")):
		return
	garage.apply_rename(text.strip_edges())
	_fill_herc_list()
	_notify_changed()


## The editor reports the whole loadout; the one hardpoint that differs is armed through the garage.
func _on_loadout_edited(lo: Array) -> void:
	var current: Array = garage.selected_entry().loadout
	for i in mini(lo.size(), current.size()):
		if str(lo[i]) != str(current[i]):
			_arm(i, str(lo[i]))
			return


## The editor reports the component slots; the one that differs is fitted through the garage.
func _on_mounts_edited(fitted: Array) -> void:
	var current: Array = garage.selected_entry().get("mounts", [])
	for i in mini(fitted.size(), current.size()):
		if int(fitted[i]) != int(current[i]):
			garage.apply_mount(i, int(fitted[i]))
			set_status("")
			_after_change()
			_editor.focus_component.call_deferred(i)
			return


func _arm(i: int, wid: String) -> void:
	var ctx := make_context()
	if garage.can_arm(ctx, i, wid):
		garage.apply_arm(ctx, i, wid)
		set_status("")
	elif garage.make_arming_price(ctx, wid) > garage.salvage_kg:
		set_status(SHORT_OF_SALVAGE % GarageEconomy.make_tons_text(garage.make_arming_price(ctx, wid)))
	else:
		set_status("None left in the armory.")
	_after_change()
	_editor.focus_hardpoint.call_deferred(i)


func _repair_selected() -> void:
	garage.apply_repair(make_context(), garage.selected)
	set_status("%s repaired." % garage.selected_entry().name)
	_after_change()


func _repair_all() -> void:
	garage.apply_repair_all(make_context())
	set_status("Repairs done as far as the salvage goes.")
	_after_change()


func _ask_scrap() -> void:
	var value := economy().make_scrap_value(garage.selected_entry())
	ConfirmDialog.ask(self, SCRAP_QUESTION % [garage.selected_entry().name, SCRAP_VALUE % GarageEconomy.make_tons_text(value) if value > 0 else ""],
		_scrap, "Scrap", Widgets.DANGER)


func _scrap() -> void:
	var gone := str(garage.selected_entry().name)
	garage.apply_scrap(make_context())
	set_status("%s scrapped." % gone)
	_after_change()


func _build_selected_type() -> void:
	var vid := _build.selected_id()
	if garage.is_full():
		set_status("The hangar is full (%d Hercs)." % Garage.MAX_VEHICLES)
		return
	if economy().make_vehicle_price(vid) > garage.salvage_kg:
		set_status(SHORT_OF_SALVAGE % GarageEconomy.make_tons_text(economy().make_vehicle_price(vid)))
		return
	if garage.apply_build(make_context(), vid) < 0:
		set_status("This Herc can't be built now.")
		return
	set_status("%s ordered and moved to the bay." % Packs.vehicle(vid).get("name", vid))
	_after_change()


func _after_change() -> void:
	_refresh()
	_crew.refresh()
	_notify_changed()


func _notify_changed() -> void:
	if _on_changed.is_valid():
		_on_changed.call()


func _focus_herc_button(i: int) -> void:
	var buttons := _hercs.get_children().filter(func(c): return c is Button)
	if is_inside_tree() and i >= 0 and i < buttons.size():
		(buttons[i] as Button).grab_focus()


static func _clear(box: Container) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()

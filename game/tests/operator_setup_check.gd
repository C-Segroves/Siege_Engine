extends Node
## Operator Setup (docs/design/lobby_loadout_economy.md section 6): built for every source (owned, garage, stash, bot),
## weapons and ammunition free with no price (O2), buying and equipping with a confirmation, parts the mode forbids,
## the red "does not fit" mark, removing with menu_secondary, slot tabs and renaming, the raid kit and stash (O5 armour at
## risk), the narrow layout, the focus chain, and a keyboard / gamepad-only path that buys and equips a part.
##   godot --headless --audio-driver Dummy --path game res://tests/operator_setup_check.tscn
##   godot --audio-driver Dummy --path game res://tests/operator_setup_check.tscn -- --shots [--out=<dir>]
## --shots needs a window; it writes renders/operator_*.png at desktop and narrow width.

const SETTLE_FRAMES := 6
const STEP_FRAMES := 2
const NARROW_SIZE := Vector2(800, 640)
const DESKTOP_SIZE := Vector2(1280, 720)
const RICH := 200000
const MAX_PAD_STEPS := 60

var _fails := 0
var _name := "QA Operator %d" % OS.get_process_id()
var _host: Control
var _setup: OperatorSetup
var _closed: Array = []
var _out := ""


func _ready() -> void:
	_out = ProjectSettings.globalize_path("res://").path_join("../renders")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	await _frames(2)
	_expect(UserStore.is_test_store(), "a test runs on a test store")
	await _check_owned_mode()
	await _check_buying()
	await _check_forbidden_and_fit()
	await _check_slot_tabs()
	await _check_raid()
	await _check_garage_and_bot()
	await _check_vehicle_store()
	await _check_component_slots()
	await _check_narrow()
	await _check_focus_chain()
	await _check_keyboard_gamepad_path()
	await _check_close()
	if "--shots" in OS.get_cmdline_user_args():
		await _take_shots()
	print("operator_setup_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


# ------------------------------------------------------------------ helpers

func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _frames(n := STEP_FRAMES) -> void:
	for i in n:
		await get_tree().process_frame


func _send_action(action: String) -> void:
	for pressed in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames()


func _send_pad_button(button: JoyButton) -> void:
	for pressed in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.button_index = button
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames()


func _send_pad_axis(axis: JoyAxis, value: float) -> void:
	for v in [value, 0.0]:
		var ev := InputEventJoypadMotion.new()
		ev.axis = axis
		ev.axis_value = v
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames()


func _focus() -> Control:
	return get_viewport().gui_get_focus_owner()


## A fresh profile named `suffix` with `credits`, saved, then the screen over a host of `host_size`.
func _open(settings: Dictionary, suffix: String, credits := RICH, host_size := DESKTOP_SIZE, with_3d := false) -> OperatorSetup:
	var profile := OperatorProfile.new()
	profile.apply_new("%s %s" % [_name, suffix])
	profile.credits = credits
	profile.save()
	_host = Control.new()
	# a Control under a plain Node does not fill the window by itself: give it the size the lobby would
	_host.size = host_size
	_host.custom_minimum_size = host_size
	add_child(_host)
	var ctx := LoadoutContext.make_for(settings)
	_setup = OperatorSetup.open(_host, ctx, 0, profile, with_3d)
	_closed.clear()
	_setup.closed.connect(func(changed: bool) -> void: _closed.append(changed))
	await _frames(SETTLE_FRAMES)
	return _setup


func _shut() -> void:
	if is_instance_valid(_setup) and _setup.sheet.is_open:
		_setup.close()
	_host.queue_free()
	await _frames(2)


func _vs() -> Dictionary:
	return {"mode": "vs", "game_mode": "deathmatch", "infantry_pack": ""}


func _store_rows() -> Array:
	return _setup.store.make_controls().filter(func(c: Control) -> bool: return c is StoreRow)


func _loadout_rows() -> Array:
	return _setup.list.make_rows().filter(func(c: Control) -> bool: return c is LoadoutRow)


func _slot() -> CharacterSlot:
	return _setup.state.make_slot()


func _row_texts(row: RowButton) -> String:
	var parts := []
	for c in row.content.get_children():
		if c is Label:
			parts.append((c as Label).text)
	return " | ".join(PackedStringArray(parts))


## Opens category `id` in the store and waits for the rows.
func _show_category(id: String) -> void:
	_setup.store.apply_category(id)
	await _frames(SETTLE_FRAMES)


func _find_row(category: String, predicate: Callable) -> StoreRow:
	await _show_category(category)
	for r in _store_rows():
		if predicate.call(r):
			return r
	return null


func _tribes_installed() -> bool:
	return not InfantryCatalog.armor("tribes:LIGHT").is_empty()


func _find_dialog() -> ConfirmDialog:
	for c in _host.get_children():
		if c is ConfirmDialog:
			return c
	return null


# ------------------------------------------------------------------ checks

func _check_owned_mode() -> void:
	print("-- owned (versus):")
	await _open(_vs(), "owned")
	await _frames(12)
	_expect(_setup.sheet.is_open and not _setup.is_narrow and _setup.state.ctx.source == "owned", "it opens as a sheet, wide, source owned (open %s narrow %s source %s size %s)" % [_setup.sheet.is_open, _setup.is_narrow, _setup.state.ctx.source, _setup.sheet.size])
	_expect(_setup.sheet.title_bar.get_children().any(func(c: Node) -> bool: return c is CreditsBadge) and _setup.credits.text() == "CR 200,000", "credits are always visible in the title row")
	_expect(_setup.tabs.make_tabs().size() == 3 and (_setup.tabs.make_tabs()[0] as Button).button_pressed, "three character slot tabs, the first open")
	_expect(_setup.preview.make_side_buttons().size() == 2, "the side switch has INFANTRY and VEHICLE")
	if not _tribes_installed():
		print("    (Tribes not installed: infantry checks skipped)")
		await _shut()
		return
	var rows := _loadout_rows()
	_expect(rows.size() >= 3 and (rows[0] as LoadoutRow).row.key == "armour" and (rows[0] as LoadoutRow).row.locked, "the list starts with the fixed armour row (%d rows)" % rows.size())
	await _check_free_weapons()
	await _check_remove_and_equip()
	await _check_gear_fill_keys()
	await _check_hover_and_tooltip()
	await _shut()


func _check_free_weapons() -> void:
	await _show_category("weapons")
	var rows := _store_rows()
	_expect(rows.size() > 0, "the weapons category lists %d entries" % rows.size())
	var priced := rows.filter(func(r: StoreRow) -> bool: return r.entry.price != 0 or _row_texts(r).contains(" cr"))
	_expect(priced.is_empty(), "O2: no weapon shows a price outside extraction")
	await _show_category("ammo")
	_expect(_store_rows().all(func(r: StoreRow) -> bool: return not _row_texts(r).contains(" cr")), "O2: no ammunition shows a price")


## Fill and adjust on a gear row keep the whole "pack:ID" item key (a get_slice(":", 1) once cut it to the pack name).
func _check_gear_fill_keys() -> void:
	_expect(OperatorText.make_row_ref("gear:tribes:GRENADE") == "tribes:GRENADE", "a row key keeps the item's pack prefix")
	var gear_rows: Array = _setup.state.make_rows().filter(func(r: Dictionary) -> bool: return r.kind == "gear" and int(r.ammo_max) > 0)
	if gear_rows.is_empty():
		return
	var key := str(gear_rows[0].key)
	var ref := OperatorText.make_row_ref(key)
	_setup.state.apply_fill(key)
	await _frames()
	var gear: Dictionary = _slot().infantry.gear
	_expect(int(gear.get(ref, 0)) > 0 and gear.keys().all(func(k) -> bool: return str(k).contains(":")), "fill stores the full item id %s (%s)" % [ref, gear.keys()])
	_setup.state.apply_adjust(key, -1)
	await _frames()
	_expect(_slot().infantry.gear.keys().all(func(k) -> bool: return str(k).contains(":")), "adjust keeps full item ids (%s)" % [_slot().infantry.gear.keys()])


func _check_remove_and_equip() -> void:
	var slot := _slot()
	var before: int = slot.infantry.weapons.size()
	var weapon_row: LoadoutRow = _loadout_rows().filter(func(r: LoadoutRow) -> bool: return r.row.kind == "weapon" and r.row.current != "").front()
	weapon_row.grab_focus()
	await _frames()
	await _send_action("menu_secondary")
	_expect(_slot().infantry.weapons.size() == before - 1, "menu_secondary on a weapon row removes it (%d -> %d)" % [before, _slot().infantry.weapons.size()])
	var saved := OperatorProfile.load_for(_setup.state.profile.pilot)
	_expect((saved.slots[0] as CharacterSlot).infantry.weapons.size() == before - 1, "the removal is saved at once")
	var carried: Array = _slot().infantry.weapons
	var pick: StoreRow = await _find_row("weapons", func(r: StoreRow) -> bool:
		return r.entry.kind == "weapon" and r.entry.state == "free" and r.fit_reason == "" and not carried.has(UnlockId.ref_of(str(r.entry.id))))
	_expect(pick != null, "a free weapon that fits is on offer")
	if pick == null:
		return
	var picked: Dictionary = pick.entry
	pick.pressed.emit()
	await _frames(SETTLE_FRAMES)
	_expect(_slot().infantry.weapons.has(UnlockId.ref_of(str(picked.id))) and _slot().infantry.weapons.size() == before, "choosing it equips it into the free row, no confirmation, no cost (%s, now %s)" % [picked.id, _slot().infantry.weapons])
	_expect(_setup.state.profile.credits == RICH and _find_dialog() == null, "free means no credits are taken")
	await _check_ammo_row()
	await _check_remove_inputs()


## The same removal by a right mouse click and by pad X (both are menu_secondary).
func _check_remove_inputs() -> void:
	var rows := _loadout_rows().filter(func(r: LoadoutRow) -> bool: return r.row.kind == "weapon" and r.row.current != "")
	if rows.size() < 2:
		print("    (fewer than two weapons: skipped)")
		return
	var before: int = _slot().infantry.weapons.size()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	(rows[0] as LoadoutRow)._gui_input(click)
	await _frames(SETTLE_FRAMES)
	_expect(_slot().infantry.weapons.size() == before - 1, "a right mouse click on a weapon row removes it")
	var next: LoadoutRow = _loadout_rows().filter(func(r: LoadoutRow) -> bool: return r.row.kind == "weapon" and r.row.current != "").front()
	next.grab_focus()
	await _frames()
	await _send_pad_button(JOY_BUTTON_X)
	_expect(_slot().infantry.weapons.size() == before - 2, "pad X (menu_secondary) removes the focused weapon")
	var armour: LoadoutRow = _loadout_rows()[0]
	armour.grab_focus()
	await _frames()
	var weapons_now: Array = (_slot().infantry.weapons as Array).duplicate()
	await _send_action("menu_secondary")
	_expect(_slot().armor != "" and _slot().infantry.weapons == weapons_now, "menu_secondary on the armour row removes nothing")


func _check_ammo_row() -> void:
	var ammo_row: LoadoutRow = null
	for r in _loadout_rows():
		if (r as LoadoutRow).row.kind == "ammo":
			ammo_row = r
			break
	if ammo_row == null:
		print("    (no ammunition row: skipped)")
		return
	var key := str(ammo_row.row.key)
	var weapon_id := key.get_slice(":", 1) + ":" + key.get_slice(":", 2) if key.count(":") > 1 else key.get_slice(":", 1)
	ammo_row.grab_focus()
	await _frames()
	var full: int = ammo_row.row.ammo
	await _send_action("ui_left")
	var less := int(_setup.list.find_row(key).row.ammo)
	_expect(less < full, "ui_left on an ammunition row takes rounds away (%d -> %d)" % [full, less])
	_setup.list.find_row(key).grab_focus()
	await _send_action("ui_right")
	_expect(int(_setup.list.find_row(key).row.ammo) > less, "ui_right adds them again (%s)" % weapon_id)


func _check_hover_and_tooltip() -> void:
	await _frames(SETTLE_FRAMES)
	var rows := _store_rows()
	if rows.is_empty():
		return
	var row: StoreRow = rows[rows.size() - 1]
	row.mouse_entered.emit()
	await _frames()
	_expect(_setup.tooltip.is_shown_for(row) and _setup.state.last_entry.id == row.entry.id, "hovering a store entry shows its plate and fills the card")
	row.mouse_exited.emit()
	row.grab_focus()
	await _frames()
	await _send_action("menu_info")
	_expect(_setup.tooltip.pinned, "menu_info pins the detail plate of the focused entry (focus %s shown %s)" % [_focus(), _setup.tooltip.visible])
	await _send_action("menu_info")
	_expect(not _setup.tooltip.pinned, "menu_info again unpins it")
	_setup.tooltip.apply_hide()


func _check_buying() -> void:
	print("-- buying:")
	await _open(_vs(), "buyer", 100000)
	var vehicle := await _find_row("vehicles", func(r: StoreRow) -> bool: return r.entry.state == "for_sale")
	_expect(vehicle != null and _row_texts(vehicle).contains(" cr"), "a vehicle for sale shows its price")
	if vehicle != null:
		var entry: Dictionary = vehicle.entry
		var price := int(entry.price)
		vehicle.pressed.emit()
		await _frames()
		var dialog := _find_dialog()
		_expect(dialog != null and _setup.state.profile.credits == 100000, "choosing it asks first, nothing is taken yet")
		if dialog != null:
			dialog.confirm_button.pressed.emit()
			await _frames(SETTLE_FRAMES)
		_expect(_setup.state.profile.credits == 100000 - price and _setup.state.profile.unlocks.owned.has(str(entry.id)), "confirming takes %d cr and unlocks it" % price)
		_expect(_slot().vehicle == UnlockId.ref_of(str(entry.id)), "the bought vehicle is equipped")
		_expect(_setup.credits.text() == CreditsBadge.make_text(100000 - price), "the credits badge follows")
	await _shut()
	await _open(_vs(), "poor", 10)
	var dear := await _find_row("vehicles", func(r: StoreRow) -> bool: return r.entry.state == "for_sale")
	if dear != null:
		dear.pressed.emit()
		await _frames()
		_expect(_find_dialog() == null and _setup.state.profile.credits == 10, "too little credit: no dialog, nothing taken")
	await _shut()


func _check_forbidden_and_fit() -> void:
	print("-- forbidden parts and fit:")
	if not _tribes_installed():
		return
	await _open({"mode": "vs", "game_mode": "deathmatch", "infantry_pack": "tribes"}, "forbidden")
	var other := await _find_row("armour", func(r: StoreRow) -> bool: return r.entry.state == "not_allowed")
	if other != null:
		_expect(_row_texts(other).contains("NOT ALLOWED"), "an armour of another game carries a NOT ALLOWED badge")
		var armor_before := _slot().armor
		other.pressed.emit()
		await _frames()
		_expect(_slot().armor == armor_before, "choosing it changes nothing: the slot keeps its armour")
	else:
		print("    (only one infantry game installed: not-allowed armour skipped)")
	_slot().apply_armor_defaults("tribes:LIGHT")
	_setup.state.apply_changed()
	await _frames(SETTLE_FRAMES)
	var mortar := await _find_row("weapons", func(r: StoreRow) -> bool: return r.entry.id == "weapon/tribes:MORTAR")
	if mortar != null:
		_expect(mortar.fit_reason != "" and _row_texts(mortar).contains("DOES NOT FIT"), "a mortar is marked DOES NOT FIT on light armour")
		var carried_before := (_slot().infantry.weapons as Array).duplicate()
		mortar.pressed.emit()
		await _frames()
		_expect(_slot().infantry.weapons == carried_before, "and it is not equipped")
	await _shut()


func _check_slot_tabs() -> void:
	print("-- slot tabs:")
	await _open(_vs(), "tabs")
	var tabs := _setup.tabs.make_tabs()
	_loadout_rows()[0].grab_focus()
	await _send_action("menu_tab_next")
	_expect(_setup.state.profile.active_slot == 1 and (_setup.tabs.make_tabs()[1] as Button).button_pressed, "menu_tab_next (RB) opens the next slot")
	await _send_action("menu_tab_prev")
	_expect(_setup.state.profile.active_slot == 0, "menu_tab_prev (LB) goes back")
	tabs = _setup.tabs.make_tabs()
	tabs[2].grab_focus()
	await _frames()
	await _send_action("menu_secondary")
	_expect(_setup.tabs.is_editing(), "menu_secondary on a slot tab starts renaming it")
	var editor: LineEdit = null
	for c in _setup.tabs.get_children():
		if c is LineEdit:
			editor = c
	if editor != null:
		editor.text = "Scout"
		editor.text_submitted.emit("Scout")
		await _frames(SETTLE_FRAMES)
	_expect(_setup.state.profile.slots[2].label == "Scout" and not _setup.tabs.is_editing(), "Enter keeps the new name")
	_expect(OperatorProfile.load_for(_setup.state.profile.pilot).slots[2].label == "Scout", "the name is saved")
	_setup.tabs.make_tabs()[1].pressed.emit()
	await _frames(SETTLE_FRAMES)
	_expect(_setup.state.profile.active_slot == 1, "clicking a tab opens that slot")
	await _shut()
	_expect(_closed == [true], "closing reports that something changed")


func _check_raid() -> void:
	print("-- raid (extraction):")
	if not _tribes_installed():
		return
	await _open({"mode": "extraction"}, "raid", 50000)
	_expect(_setup.state.ctx.loss_on_death and _setup.preview.make_side_buttons().size() == 3, "a raid adds the STASH side")
	var ids := _setup.store._categories.map(func(c: Dictionary) -> String: return c.id)
	_expect(not ids.has("weapons") and not ids.has("ammo") and ids.has("supplies") and ids.has("armour"), "the store sells look parts and supplies, no unlock weapons (%s)" % [ids])
	var medium := await _find_row("armour", func(r: StoreRow) -> bool: return r.entry.id == "armor/tribes:MEDIUM")
	_expect(medium != null and medium.entry.state == "for_sale", "O5: medium armour is for sale in a raid")
	var light := await _find_row("armour", func(r: StoreRow) -> bool: return r.entry.id == "armor/tribes:LIGHT")
	_expect(light != null and light.entry.state == "free", "O5: light armour is free in a raid")
	if medium != null:
		medium.pressed.emit()
		await _frames()
		var dialog := _find_dialog()
		_expect(dialog != null, "buying it asks first")
		if dialog != null:
			dialog.confirm_button.pressed.emit()
			await _frames(SETTLE_FRAMES)
		_expect(_slot().armor == "tribes:MEDIUM", "the bought armour is worn")
		var armour_row: KitRow = _setup.list.find_kit_row("armour")
		var badges := armour_row.find_children("*", "Label", true, false).map(func(l: Label) -> String: return l.text)
		_expect(badges.has("AT RISK"), "the worn paid armour is marked AT RISK (%s)" % [badges])
	await _check_raid_dropdowns()
	await _check_stash_side()
	await _shut()


## In a raid the infantry rows are drop-downs; a choice moves stock and equals the spawn kit; the stash tab has no buttons that move stacks.
func _check_raid_dropdowns() -> void:
	print("-- raid drop-downs:")
	var kit_rows: Array = _setup.list.make_rows().filter(func(c: Control) -> bool: return c is OptionButton)
	_expect(kit_rows.size() >= 3, "the raid loadout rows are drop-downs (%d)" % kit_rows.size())
	var profile: ExtractionProfile = _setup.state.extraction
	var armor_id := profile.kit_armor
	var row: KitRow = _setup.list.find_kit_row("weapon:1")
	if row != null:
		var pick := -1
		for i in row.option.item_count:
			if str(row.option.get_item_metadata(i)) != "" and str(row.option.get_item_metadata(i)) != row.make_choice():
				pick = i
		if pick >= 0:
			var wid := str(row.option.get_item_metadata(pick))
			profile.stash.apply_add_unchecked(ExtractionItems.make_id("weapon", wid), 1)
			_setup.state.apply_changed()
			await _frames(SETTLE_FRAMES)
			row = _setup.list.find_kit_row("weapon:1")
			for i in row.option.item_count:
				if str(row.option.get_item_metadata(i)) == wid:
					row.option.select(i)
					row.option.item_selected.emit(i)
			await _frames(SETTLE_FRAMES)
			_expect(ExtractionLoadout.make_raid_weapons(armor_id, profile.kit).has(wid), "the drop-down choice %s is in the spawn kit" % wid)
			var shown: Array = []
			for r in _setup.state.make_rows():
				if r.kind == "weapon" and str(r.current) != "":
					shown.append(str(r.current))
			_expect(shown == ExtractionLoadout.make_raid_weapons(armor_id, profile.kit), "the rows equal the spawn weapons")
	await _check_raid_stock_choices()
	await _send_action("menu_switch_kind")
	await _send_action("menu_switch_kind")
	_expect(_setup.stash.visible and _setup.stash.find_children("*", "Button", true, false).all(func(b: Node) -> bool: return not (b as Button).text.begins_with("To ")), "the stash tab has no To kit / To stash buttons")
	await _send_action("menu_switch_kind")   # back to the infantry side


func _check_stash_side() -> void:
	await _send_action("menu_switch_kind")
	_expect(_setup.state.side == "vehicle", "menu_switch_kind (View) switches to the vehicle")
	await _send_action("menu_switch_kind")
	_expect(_setup.state.side == "stash" and _setup.stash.visible and not _setup.list.visible, "and again to the stash")
	_expect(_setup.stash.make_controls().size() >= 0 and _setup.state.extraction != null, "the kit and stash list is built from the extraction profile")
	await _show_category("supplies")
	var supply := _store_rows().front() as StoreRow if not _store_rows().is_empty() else null
	_expect(supply != null and supply.entry.stock and _row_texts(supply).contains(" cr"), "supplies are stock lots with a price")
	if supply != null:
		var before := _setup.state.profile.credits
		var entry: Dictionary = supply.entry
		var stash_before: int = _setup.state.extraction.stash.count(str(entry.id))
		supply.pressed.emit()
		await _frames()
		var dialog := _find_dialog()
		_expect(dialog != null, "buying supplies asks first")
		if dialog != null:
			dialog.confirm_button.pressed.emit()
			await _frames(SETTLE_FRAMES)
		_expect(_setup.state.profile.credits == before - int(entry.price) and _setup.state.extraction.stash.count(str(entry.id)) > stash_before, "the lot goes to the stash and its price comes off the credits")
	await _send_action("menu_switch_kind")
	_expect(_setup.state.side == "infantry", "the switch wraps to the infantry")


## The vehicle side: the store lists only weapons that fit the hardpoints, filters by the selected hardpoint, equips to
## it and removes from it (mouse and pad), for an ES1 Herc, a Starsiege Herc and a Tribes vehicle.
func _check_vehicle_store() -> void:
	print("-- vehicle store:")
	for pack in ["es1", "starsiege", "tribes"]:
		var vehicle := _pick_vehicle(pack)
		if vehicle.is_empty():
			print("    (no armed vehicle of %s installed: skipped)" % pack)
			continue
		await _open(_vs(), "veh " + pack)
		_slot().apply_vehicle_defaults(str(vehicle.id))
		_setup.state.apply_side("vehicle")
		await _frames(SETTLE_FRAMES)
		await _check_vehicle_pack(pack, vehicle)
		await _shut()


## Starsiege component slots (HercMounts): a row per slot, the store lists what fits it, equip and remove by mouse and pad.
func _check_component_slots() -> void:
	print("-- component slots:")
	var herc := {}
	for v in Packs.pilotable(["starsiege"]):
		if HercMounts.has_slots(v):
			herc = v
			break
	if herc.is_empty():
		print("    (no Starsiege Herc with component slots installed: skipped)")
		return
	await _open(_vs(), "mounts")
	_slot().apply_vehicle_defaults(str(herc.id))
	_setup.state.apply_side("vehicle")
	await _frames(SETTLE_FRAMES)
	var slots := HercMounts.make_slots(herc)
	var rows := _loadout_rows().filter(func(r: LoadoutRow) -> bool: return r.row.kind == "mount")
	_expect(rows.size() == slots.size(), "%s: the loadout lists its %d component slots" % [herc.id, slots.size()])
	(rows[0] as LoadoutRow).pressed.emit()
	await _frames(SETTLE_FRAMES)
	var entries := _store_rows()
	var options := HercMounts.make_options(herc, 0)
	_expect(entries.size() == options.size() + 2, "the store lists the factory fit, empty and %d cloaks that fit slot 1" % options.size())
	_expect(entries.all(func(r: StoreRow) -> bool: return r.fit_reason == "" and r.entry.kind == "mount_part"), "every component entry fits")
	var cloak: StoreRow = entries.filter(func(r: StoreRow) -> bool: return int(r.entry.mount_value) > 0).front()
	var value := int(cloak.entry.mount_value)
	cloak.pressed.emit()
	await _frames(SETTLE_FRAMES)
	_expect(int(_slot().herc_mounts[0]) == value, "choosing a cloak fits it into slot 1 (herc_mounts)")
	var row: LoadoutRow = _loadout_rows().filter(func(r: LoadoutRow) -> bool: return r.row.key == "mount:0").front()
	_expect(_row_texts(row).contains(HercMounts.make_part_name(herc, value)), "the row shows the fitted cloak")
	row.grab_focus()
	await _frames()
	await _send_pad_button(JOY_BUTTON_X)
	_expect(int(_slot().herc_mounts[0]) == HercMounts.EMPTIED, "pad X empties the slot")
	_slot().herc_mounts[0] = value
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	(_loadout_rows().filter(func(r: LoadoutRow) -> bool: return r.row.key == "mount:0").front() as LoadoutRow)._gui_input(click)
	await _frames(SETTLE_FRAMES)
	_expect(int(_slot().herc_mounts[0]) == HercMounts.EMPTIED, "a right click empties it too")
	await _shut()


func _pick_vehicle(pack: String) -> Dictionary:
	var fallback := {}
	for v in Packs.pilotable([pack]):
		if PackVehicleLoader.has_fixed_loadout(v) or WeaponFit.hardpoint_masks(v).is_empty():
			fallback = v if fallback.is_empty() else fallback
			continue
		return v
	return fallback


func _check_vehicle_pack(pack: String, v: Dictionary) -> void:
	var masks := WeaponFit.hardpoint_masks(v)
	var hardpoints := _loadout_rows().filter(func(r: LoadoutRow) -> bool: return r.row.kind == "hardpoint")
	_expect(hardpoints.size() == masks.size(), "%s %s: the loadout lists its %d hardpoints" % [pack, v.id, masks.size()])
	_expect(_setup.store.get_category() == "weapons", "%s: the store opens on weapons for the vehicle" % pack)
	if PackVehicleLoader.has_fixed_loadout(v) or masks.is_empty():
		_expect(_store_rows().all(func(r: StoreRow) -> bool: return r.fit_reason != "" or r.entry.kind != "herc_weapon"), "%s: a fixed loadout takes no store weapon" % pack)
		return
	var weapons := _store_rows()
	_expect(weapons.size() > 0 and weapons.all(func(r: StoreRow) -> bool: return r.entry.kind == "herc_weapon"), "%s: the store lists %d vehicle weapons only" % [pack, weapons.size()])
	_expect(weapons.all(func(r: StoreRow) -> bool: return r.fit_reason == ""), "%s: every listed weapon fits some hardpoint" % pack)
	(hardpoints[0] as LoadoutRow).pressed.emit()
	await _frames(SETTLE_FRAMES)
	var mask := int(masks[0])
	_expect(_setup.state.selected_row == "hardpoint:0", "%s: selecting a hardpoint row selects it" % pack)
	_expect(_store_rows().all(func(r: StoreRow) -> bool: return WeaponFit.fits_mask(Packs.weapon(UnlockId.ref_of(str(r.entry.id))), mask)), "%s: the store is filtered to hardpoint 1 (%s)" % [pack, WeaponFit.hardpoint_size(v, 0)])
	await _expect_unfit_marked(v, pack)
	var pick: StoreRow = _store_rows().filter(func(r: StoreRow) -> bool: return r.entry.state != "not_allowed" and UnlockId.ref_of(str(r.entry.id)) != _slot().herc_loadout[0]).front() if not _store_rows().is_empty() else null
	if pick == null:
		return
	var ref := UnlockId.ref_of(str(pick.entry.id))
	pick.pressed.emit()
	await _frames(SETTLE_FRAMES)
	_expect(_slot().herc_loadout[0] == ref and _find_dialog() == null, "%s: choosing %s mounts it on hardpoint 1, free" % [pack, ref])
	var row: LoadoutRow = _loadout_rows().filter(func(r: LoadoutRow) -> bool: return r.row.key == "hardpoint:0").front()
	_expect(_row_texts(row).contains(SlotCheck.make_name("herc_weapon/" + ref)), "%s: the row shows what is mounted" % pack)
	row.grab_focus()
	await _frames()
	await _send_pad_button(JOY_BUTTON_X)
	_expect(_slot().herc_loadout[0] == "", "%s: pad X removes it from the hardpoint" % pack)
	_setup.state.apply_select_row("hardpoint:0")
	await _frames(SETTLE_FRAMES)
	var again: StoreRow = _store_rows().filter(func(r: StoreRow) -> bool: return r.entry.state != "not_allowed" and r.fit_reason == "").front()
	var focused := _store_rows().find(again)
	again.grab_focus()
	await _frames()
	await _send_action("ui_accept")
	_expect(focused >= 0 and _slot().herc_loadout[0] != "", "%s: ui_accept on a store row mounts it by pad or keyboard" % pack)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	(_loadout_rows().filter(func(r: LoadoutRow) -> bool: return r.row.key == "hardpoint:0").front() as LoadoutRow)._gui_input(click)
	await _frames(SETTLE_FRAMES)
	_expect(_slot().herc_loadout[0] == "", "%s: a right click removes it too" % pack)


## With the "Fits slot" filter off, a weapon too big for the selected hardpoint is marked "does not fit".
func _expect_unfit_marked(v: Dictionary, pack: String) -> void:
	_setup.store._fits.button_pressed = false
	await _frames(SETTLE_FRAMES)
	var mask := int(WeaponFit.hardpoint_masks(v)[0])
	var too_big := _store_rows().filter(func(r: StoreRow) -> bool: return not WeaponFit.fits_mask(Packs.weapon(UnlockId.ref_of(str(r.entry.id))), mask))
	_expect(too_big.is_empty() or too_big.all(func(r: StoreRow) -> bool: return r.fit_reason != ""), "%s: a weapon too big for the hardpoint is marked does not fit (%d shown)" % [pack, too_big.size()])
	_setup.store._fits.button_pressed = true
	await _frames(SETTLE_FRAMES)


func _check_garage_and_bot() -> void:
	print("-- garage and bot cards:")
	await _open({"mode": "campaign"}, "garage", 0)
	_expect(not _setup.state.has_store() and _setup.store._title.text == "PARTS", "the campaign has a parts list, not a store")
	var any_sale := false
	for r in _store_rows():
		any_sale = any_sale or (r as StoreRow).entry.state == "for_sale"
	_expect(not any_sale and _setup.store._categories.size() == StoreCatalog.CATEGORIES.size(), "nothing is for sale there, every category is listed")
	await _shut()
	await _open(_vs(), "bot", 0)
	_setup.state.ctx.source = "bot"
	_setup.state.ctx.store_enabled = false
	_setup.store.refresh()
	await _frames()
	var vehicles := await _find_row("vehicles", func(r: StoreRow) -> bool: return true)
	_expect(vehicles == null or (vehicles as StoreRow).entry.state != "for_sale", "a bot card is limited by the mode, never by ownership")
	await _shut()


func _check_narrow() -> void:
	print("-- narrow layout:")
	await _open(_vs(), "narrow", RICH, NARROW_SIZE)
	_expect(_setup.is_narrow and _setup.pane == 0, "under 1000 px the three columns become panes")
	_expect(_setup.store.is_visible_in_tree() == false and _setup.list.is_visible_in_tree(), "only the loadout pane shows first")
	await _send_pad_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_expect(_setup.pane == 1 and _setup.store.is_visible_in_tree() and not _setup.list.is_visible_in_tree(), "RT (menu_zone_next) opens the store pane")
	_expect(_focus() != null and _setup.store.is_ancestor_of(_focus()), "and focuses inside it")
	await _send_pad_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_expect(_setup.pane == 2 and _setup.look.is_visible_in_tree(), "RT again opens the look pane")
	await _send_pad_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)
	_expect(_setup.pane == 1, "LT goes back")
	_expect(_setup.sheet.size.x <= NARROW_SIZE.x + 1.0, "nothing is wider than the sheet")
	await _shut()
	await _open(_vs(), "wide-again", RICH, DESKTOP_SIZE)
	_expect(not _setup.is_narrow and _setup.store.is_visible_in_tree() and _setup.look.is_visible_in_tree() and _setup.list.is_visible_in_tree(), "a wide host shows all three columns")
	await _shut()


func _check_focus_chain() -> void:
	print("-- focus chain:")
	await _open(_vs(), "focus", RICH, DESKTOP_SIZE)
	_expect(_focus() != null and _setup.sheet.is_ancestor_of(_focus()), "focus starts inside the sheet (%s)" % [_focus()])
	var seen := {}
	for z in 3:
		var chain := _setup.make_zone_controls(z)
		_expect(not chain.is_empty(), "zone %d has controls (%d)" % [z, chain.size()])
		_expect(_walks_down(chain), "zone %d: ui_down visits every control in order" % z)
		for c in chain:
			seen[c] = true
	for c in _setup.tabs.make_tabs():
		seen[c] = true
	seen[_setup.sheet.back_button] = true
	seen[_setup.sheet.primary_button] = true
	var stray := UiActions.focusables(_setup.sheet).filter(func(c: Control) -> bool: return not seen.has(c))
	_expect(stray.is_empty(), "every focusable control is in a zone, the tabs or the footer (%d stray)" % stray.size())
	var first_zone := _setup.make_zone_controls(0)[0] as Control
	first_zone.grab_focus()
	await _frames()
	await _send_pad_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_expect(_setup.store.is_ancestor_of(_focus()), "RT jumps from the loadout to the store")
	await _send_pad_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_expect(_setup.look.is_ancestor_of(_focus()), "and on to the look pickers")
	await _send_pad_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_expect(_setup.list.is_ancestor_of(_focus()) or _setup.preview.is_ancestor_of(_focus()), "and round to the loadout")
	await _shut()


## True when following focus_neighbor_bottom from the first control of `chain` visits all of it in order.
func _walks_down(chain: Array[Control]) -> bool:
	var at := chain[0]
	for i in chain.size():
		if at != chain[i]:
			return false
		var next := at.get_node_or_null(at.focus_neighbor_bottom)
		if i + 1 < chain.size():
			at = next as Control
		elif next != null and next != at and not (next is Button and (next as Button) == _setup.sheet.primary_button):
			return false
	return true


func _check_keyboard_gamepad_path() -> void:
	print("-- keyboard and gamepad only:")
	await _open(_vs(), "pad", 100000, DESKTOP_SIZE)
	_loadout_rows()[0].grab_focus()
	await _frames()
	await _send_pad_button(JOY_BUTTON_RIGHT_SHOULDER)
	_expect(_setup.state.profile.active_slot == 1, "pad RB switches the slot")
	await _send_pad_button(JOY_BUTTON_LEFT_SHOULDER)
	await _send_pad_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_expect(_setup.store.is_ancestor_of(_focus()), "pad RT reaches the store")
	for i in 3:
		await _send_pad_button(JOY_BUTTON_RIGHT_SHOULDER)
		if _setup.store.get_category() == "vehicles":
			break
	for i in 6:
		if _setup.store.get_category() == "vehicles":
			break
		await _send_pad_button(JOY_BUTTON_RIGHT_SHOULDER)
	_expect(_setup.store.get_category() == "vehicles", "pad RB steps the store categories (now %s)" % _setup.store.get_category())
	var reached := await _pad_down_until(func() -> bool: return _focus() is StoreRow and (_focus() as StoreRow).entry.state == "for_sale")
	_expect(reached, "the d-pad walks down to a vehicle for sale")
	if not reached:
		await _shut()
		return
	var entry: Dictionary = (_focus() as StoreRow).entry
	var credits := _setup.state.profile.credits
	await _send_pad_button(JOY_BUTTON_A)
	_expect(_find_dialog() != null and _focus() is Button and _find_dialog().is_ancestor_of(_focus()), "pad A asks to buy, focus is in the dialog")
	await _send_pad_button(JOY_BUTTON_A)
	await _frames(SETTLE_FRAMES)
	_expect(_setup.state.profile.credits == credits - int(entry.price) and _slot().vehicle == UnlockId.ref_of(str(entry.id)), "pad A on Buy takes the price and equips the vehicle")
	_expect(_setup.sheet.is_ancestor_of(_focus()) or _focus() == null or _find_dialog() == null, "focus is back in the screen")
	await _shut()


## Presses the d-pad down until `done` holds; false after MAX_PAD_STEPS.
func _pad_down_until(done: Callable) -> bool:
	for i in MAX_PAD_STEPS:
		if done.call():
			return true
		await _send_pad_button(JOY_BUTTON_DPAD_DOWN)
	return done.call()


func _check_close() -> void:
	print("-- closing:")
	await _open(_vs(), "close")
	await _send_action("menu_back")
	_expect(_closed == [false], "menu_back (B) closes; nothing changed")
	await _shut()
	await _open(_vs(), "close2")
	_setup.sheet.primary_button.pressed.emit()
	await _frames()
	_expect(_closed == [false], "Done closes too")
	await _shut()


# ------------------------------------------------------------------ screenshots

func _take_shots() -> void:
	print("-- screenshots to %s:" % _out)
	DirAccess.make_dir_recursive_absolute(_out)
	await _shot_set("operator_desktop", DESKTOP_SIZE, _vs(), 0)
	await _shot_set("operator_narrow", NARROW_SIZE, _vs(), 0)
	await _shot_set("operator_raid", DESKTOP_SIZE, {"mode": "extraction"}, 0)
	await _shot_set("operator_raid_narrow", Vector2(900, 720), {"mode": "extraction"}, 0)
	await _shot_set("operator_garage", DESKTOP_SIZE, {"mode": "campaign"}, 0)
	await _shot_components()


## The vehicle side of a Starsiege Herc with component slots, slot 1 selected so the store lists the cloaks that fit it.
func _shot_components() -> void:
	for v in Packs.pilotable(["starsiege"]):
		if HercMounts.has_slots(v):
			await _open(_vs(), "operator_components", 4250, DESKTOP_SIZE, true)
			_slot().apply_vehicle_defaults(str(v.id))
			_setup.state.apply_side("vehicle")
			_setup.state.apply_select_row("mount:0")
			await _frames(40)
			await _save("operator_components")
			await _shut()
			return


func _shot_set(shot_name: String, size: Vector2, settings: Dictionary, credits: int) -> void:
	await _open(settings, shot_name, credits if credits > 0 else 4250, size, true)
	await _frames(40)
	await _save(shot_name)
	if size.x < OperatorSetup.PANES_BELOW:
		_setup.state.apply_side("vehicle")
		_setup.state.apply_select_row("hardpoint:0")
		await _frames(20)
		await _save(shot_name + "_vehicle")
		_setup.apply_zone(1)
		await _frames(20)
		await _save(shot_name + "_vehicle_store")
		for pane_index in [1, 2]:
			_setup.apply_zone(pane_index)
			await _frames(20)
			await _save("%s_pane%d" % [shot_name, pane_index])
		_setup.apply_zone(0)
		_setup.state.apply_side("stash")
		await _frames(20)
		if _setup.state.side == "stash":
			await _save(shot_name + "_stash")
	else:
		await _show_category("skins")
		await _frames(20)
		await _save(shot_name + "_skins")
		for side in ["vehicle", "stash"]:
			_setup.state.apply_side(side)
			if side == "vehicle":
				_setup.state.apply_select_row("hardpoint:0")
			await _frames(30)
			if _setup.state.side == side:
				await _save("%s_%s" % [shot_name, side])
	await _shut()


func _save(shot_name: String) -> void:
	for i in 3:
		await RenderingServer.frame_post_draw
	var path := _out.path_join("%s.png" % shot_name)
	get_viewport().get_texture().get_image().save_png(path)
	print("   ", path)


## Ammunition, a hand item, the pack and the insured slot are drop-downs too: each choice lands in the kit the spawn reads.
func _check_raid_stock_choices() -> void:
	var profile: ExtractionProfile = _setup.state.extraction
	var armor_id := profile.kit_armor
	var ammo_rows: Array = _setup.state.make_rows().filter(func(r: Dictionary) -> bool: return r.kind == "ammo")
	if not ammo_rows.is_empty():
		var key := str(ammo_rows[0].key)
		_choose(key, "0")
		await _frames(SETTLE_FRAMES)
		_expect(profile.kit.count(ExtractionItems.make_id("ammo", OperatorText.make_row_ref(key))) == 0, "choosing no rounds empties the ammunition from the kit")
	var packs := InfantryGear.packs_of(InfantryCatalog.armor(armor_id))
	if not packs.is_empty():
		profile.stash.apply_add_unchecked(ExtractionItems.make_id("pack", str(packs[0])), 1)
		_setup.state.apply_changed()
		await _frames(SETTLE_FRAMES)
		_choose("pack", str(packs[0]))
		await _frames(SETTLE_FRAMES)
		_expect(ExtractionLoadout.make_kit_pack(armor_id, profile.kit) == str(packs[0]), "the pack drop-down puts the pack in the spawn kit")
		_expect(_setup.list.find_kit_row("pack").make_choice() == str(packs[0]), "and the row shows it")
	var insured_row := _setup.list.find_kit_row("insured")
	_expect(insured_row != null and insured_row.option.item_count >= 2, "an insured slot drop-down lists the kit stacks")
	if insured_row != null and insured_row.option.item_count >= 2:
		var wanted := str(insured_row.option.get_item_metadata(1))
		_choose("insured", wanted)
		await _frames(SETTLE_FRAMES)
		_expect(profile.make_insured_id() == wanted, "choosing insures it")
	_expect(_setup.state.make_fit().kg == profile.kit.make_used_kg(), "the fit line weighs the kit")


## Picks choice `choice` in the drop-down of row `row_key` as a click would.
func _choose(row_key: String, choice: String) -> void:
	var row := _setup.list.find_kit_row(row_key)
	for i in row.option.item_count:
		if str(row.option.get_item_metadata(i)) == choice:
			row.option.select(i)
			row.option.item_selected.emit(i)
			return

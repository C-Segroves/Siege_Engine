class_name OperatorState
extends RefCounted
## What Operator Setup edits and shows, shared by its panels: the operator's profile, the match context, the open
## slot, the side (infantry, vehicle or the raid stash), the selected loadout row and the entry on the detail card.
## Every change goes through here: it is applied to the profile, saved at once and announced with `changed`.
## Buying asks first (`confirm_requested`); the screen shows the dialog and calls the apply_ function on yes.

signal changed
signal selection_changed
signal side_changed
signal preview_changed(entry: Dictionary)
signal status_changed(text: String)
signal confirm_requested(message: String, confirm_text: String, on_confirm: Callable)

const SIDE_STASH := "stash"
const AMMO_STEPS := 10
const GEAR_STEP := 1

var profile: OperatorProfile
var ctx: LoadoutContext
var extraction: ExtractionProfile = null
var side := LoadoutLayout.SIDE_INFANTRY
var selected_row := ""
var last_entry := {}
var is_dirty := false


## The state of `p_profile` in match context `p_ctx`; a raid (stash source) also loads the extraction profile.
static func make_for(p_profile: OperatorProfile, p_ctx: LoadoutContext) -> OperatorState:
	var s := OperatorState.new()
	s.profile = p_profile
	s.ctx = p_ctx
	p_ctx.unlocks = p_profile.unlocks
	if p_ctx.source == LoadoutContext.SOURCE_GARAGE:
		s.side = LoadoutLayout.SIDE_VEHICLE   # the campaign flies Hercs: the garage opens on the vehicle
	if p_ctx.source == LoadoutContext.SOURCE_STASH:
		s.extraction = ExtractionProfile.load_for(p_profile.pilot)
		p_ctx.apply_raid_kit(s.extraction.kit)
	return s


func make_slot() -> CharacterSlot:
	return profile.make_active_slot()


func make_sides() -> Array:
	var out := [LoadoutLayout.SIDE_INFANTRY, LoadoutLayout.SIDE_VEHICLE]
	if extraction != null:
		out.append(SIDE_STASH)
	return out


func has_store() -> bool:
	return ctx.store_enabled


## SlotCheck blocks of the open slot by LoadoutLayout row key: {row key: text}.
func make_block_texts() -> Dictionary:
	var out := {}
	for b in make_slot().make_blocks(ctx):
		var key := OperatorText.make_row_key_of_part(str(b.part))
		if not (is_kit_mode() and key != "armour"):
			out[key] = str(b.text)   # a raid kit is checked by what it holds, not by the slot's wish list
	return out


## True on the infantry side of a raid: the loadout rows are the kit (ExtractionKitEditor), chosen from the stash.
func is_kit_mode() -> bool:
	return extraction != null and side == LoadoutLayout.SIDE_INFANTRY


## {slots, slots_max, kg, kg_max, ok} of what is shown: the raid kit, or the open slot.
func make_fit() -> Dictionary:
	return ExtractionKitEditor.make_fit(extraction) if is_kit_mode() else LoadoutLayout.make_fit(side, make_slot())


## The unlock ids the open slot would put at risk in a raid (nothing outside one).
func make_at_risk_ids() -> Array:
	return profile.make_raid_start_risk(ctx) if ctx.loss_on_death else []


# ------------------------------------------------------------------ view state

func apply_side(p_side: String) -> void:
	if p_side == side or not make_sides().has(p_side):
		return
	side = p_side
	selected_row = ""
	side_changed.emit()
	selection_changed.emit()


func apply_select_row(row_key: String) -> void:
	if row_key == selected_row:
		return
	selected_row = row_key
	selection_changed.emit()


func apply_preview(entry: Dictionary) -> void:
	last_entry = entry
	preview_changed.emit(entry)


func apply_status(text: String) -> void:
	status_changed.emit(text)


# ------------------------------------------------------------------ slots

func apply_select_slot(i: int) -> void:
	var target := clampi(i, 0, profile.slots.size() - 1)
	if target == profile.active_slot:
		return
	profile.apply_select_slot(target)
	selected_row = ""
	apply_changed()


func apply_rename_slot(i: int, text: String) -> void:
	var s: CharacterSlot = profile.slots[clampi(i, 0, profile.slots.size() - 1)]
	var clean := text.strip_edges().left(CharacterSlot.MAX_LABEL)
	s.label = clean if clean != "" else CharacterSlot.DEFAULT_LABEL % (s.index + 1)
	apply_changed()


# ------------------------------------------------------------------ equipping and buying

## The click on a store entry: equips it, or asks first when it costs credits.
func request_equip(entry: Dictionary) -> void:
	apply_preview(entry)
	match str(entry.state):
		StoreCatalog.STATE_NOT_ALLOWED:
			apply_status(str(entry.reason))
		StoreCatalog.STATE_FOR_SALE:
			_request_purchase(entry)
		StoreCatalog.STATE_LOST:
			_request_rebuy(entry)
		_:
			apply_equip(entry)


func apply_equip(entry: Dictionary) -> void:
	var result := OperatorEquip.apply_entry(make_slot(), entry, selected_row)
	apply_status(str(result.text))
	if bool(result.ok):
		apply_changed()


func apply_buy_and_equip(entry: Dictionary) -> void:
	var result := StoreService.apply_buy(profile, str(entry.id), ctx)
	apply_status(str(result.text))
	if not bool(result.ok):
		return
	apply_changed()
	apply_equip(_make_refreshed(entry))


func apply_rebuy_and_equip(entry: Dictionary) -> void:
	var result := StoreService.apply_rebuy(profile, str(entry.id))
	apply_status(str(result.text))
	if not bool(result.ok):
		return
	apply_changed()
	apply_equip(_make_refreshed(entry))


func apply_buy_supply(entry: Dictionary) -> void:
	if extraction == null:
		return
	var result := SupplyService.apply_buy(profile, extraction, str(entry.id))
	apply_status(str(result.text))
	if bool(result.ok):
		extraction.save()
		apply_changed()


func _request_purchase(entry: Dictionary) -> void:
	var price := int(entry.price)
	if not profile.is_affordable(price):
		apply_status(StoreService.NOT_ENOUGH % EconomyRules.make_money_text(price))
		return
	var message := "Buy %s for %s?" % [entry.name, EconomyRules.make_money_text(price)]
	if bool(entry.get("stock", false)):
		confirm_requested.emit(message + " It goes to the stash.", "Buy", apply_buy_supply.bind(entry))
	else:
		confirm_requested.emit(message, "Buy", apply_buy_and_equip.bind(entry))


func _request_rebuy(entry: Dictionary) -> void:
	var price := int(entry.price)
	if not profile.is_affordable(price):
		apply_status(StoreService.NOT_ENOUGH % EconomyRules.make_money_text(price))
		return
	confirm_requested.emit("Buy back %s for %s?" % [entry.name, EconomyRules.make_money_text(price)], "Buy back", apply_rebuy_and_equip.bind(entry))


## The same entry after a purchase: owned now.
func _make_refreshed(entry: Dictionary) -> Dictionary:
	return StoreCatalog.make_entry(str(entry.id), ctx, profile)


# ------------------------------------------------------------------ removing and adjusting

## Right click / pad X on a row: empties it (the armour and an empty row do nothing).
func apply_remove(row_key: String) -> void:
	var row := find_row(row_key)
	if row.is_empty() or bool(row.locked):
		return
	if is_kit_mode():
		if str(row.kind) != "armour":
			apply_choose(row_key, str((row.choices as Array)[0].id))   # the first choice is the empty one
		return
	if str(row.kind) == MountEntries.KIND_ROW:
		_apply_empty_mount(row_key)
		return
	if str(row.current) == "" or str(row.kind) == "armour":
		return
	if str(row.kind) == "ammo":
		return
	LoadoutLayout.apply_clear(make_slot(), row_key)
	apply_status("Removed %s" % SlotCheck.make_name(OperatorText.make_row_unlock_id(row)))
	if selected_row == row_key:
		selected_row = ""
		selection_changed.emit()
	apply_changed()


func _apply_empty_mount(row_key: String) -> void:
	var slot := make_slot()
	var mounts := slot.make_mounts()
	var index: int = MountEntries.make_slot_index(row_key)
	if mounts[index] == HercMounts.EMPTIED:
		return
	if HercMounts.apply_set(Packs.vehicle(slot.vehicle), mounts, index, HercMounts.EMPTIED):
		slot.herc_mounts = mounts
		apply_status("Emptied component slot %d" % (index + 1))
		apply_changed()


## Left / right on an ammunition or gear row: `direction` -1 or +1.
func apply_adjust(row_key: String, direction: int) -> void:
	var row := find_row(row_key)
	if row.is_empty() or int(row.ammo_max) <= 0:
		return
	var step := maxi(int(ceil(float(row.ammo_max) / AMMO_STEPS)), 1) if str(row.kind) == "ammo" else GEAR_STEP
	var target := clampi(int(row.ammo) + direction * step, 0, int(row.ammo_max))
	if str(row.kind) == "ammo":
		LoadoutLayout.apply_set_ammo(make_slot(), str(row.current), target)
	elif target <= 0:
		LoadoutLayout.apply_clear(make_slot(), row_key)
	else:
		make_slot().infantry.gear[OperatorText.make_row_ref(row_key)] = target
	apply_changed()


## Accept on an ammunition or gear row: fill it up (a gear row not carried yet is taken).
func apply_fill(row_key: String) -> void:
	var row := find_row(row_key)
	if row.is_empty() or int(row.ammo_max) <= 0:
		return
	if str(row.kind) == "gear" and str(row.current) == "":
		LoadoutLayout.apply_set(make_slot(), row_key, OperatorText.make_row_ref(row_key))
	elif str(row.kind) == "ammo":
		LoadoutLayout.apply_set_ammo(make_slot(), str(row.current), int(row.ammo_max))
	else:
		make_slot().infantry.gear[OperatorText.make_row_ref(row_key)] = int(row.ammo_max)
	apply_changed()


## Chooses `choice` (a row's choice id) for loadout row `row_key` of a raid: the kit takes it from the stash, what it
## replaces goes back. The armour is the operator's own (unlocks), the rest is stock.
func apply_choose(row_key: String, choice: String) -> void:
	if not is_kit_mode():
		return
	var ok := _apply_kit_choice(row_key, choice)
	apply_status("" if ok else ExtractionKitEditor.NO_ROOM % row_key.get_slice(":", 0))
	apply_changed()


func _apply_kit_choice(row_key: String, choice: String) -> bool:
	match row_key:
		"armour":
			return _apply_armour_choice(choice)
		InsuredRow.KEY:
			return InsuredRow.apply_choice(extraction, make_at_risk_ids(), choice)
	return ExtractionKitEditor.apply_choice(extraction, row_key, choice)


func _apply_armour_choice(armor_id: String) -> bool:
	if not make_armour_choices().any(func(c: Dictionary) -> bool: return str(c.id) == armor_id):
		return false
	var slot := make_slot()
	LoadoutLayout.apply_set(slot, "armour", armor_id)
	extraction.apply_slot_armor(profile)
	return true


## The armours a raider may field: the match's game, free in a raid or owned and not lost ([{id, text}]).
func make_armour_choices() -> Array:
	var out := []
	for pack in InfantryCatalog.INFANTRY_PACKS:
		for a in InfantryCatalog.armors_of(pack):
			var unlock := UnlockId.make("armor", str(a.id))
			if str(a.id) == make_slot().armor or (ctx.make_block_reason(unlock) == "" and ctx.is_usable(unlock) and Assets.has_pack(pack)):
				out.append({"id": str(a.id), "text": str(a.name) if ctx.pack != "" else "%s (%s)" % [a.name, Packs.pack_name(pack)]})
	return out


func make_rows() -> Array:
	if side == SIDE_STASH:
		return []
	if is_kit_mode():
		return _make_kit_rows()
	var rows := LoadoutLayout.make_rows(side, make_slot(), ctx)
	if side == LoadoutLayout.SIDE_VEHICLE:
		rows.append_array(MountEntries.make_rows(make_slot(), ctx))
	return rows


## The armour row (chosen from the owned armours) followed by the kit's rows.
func _make_kit_rows() -> Array:
	var rows := []
	for r in LoadoutLayout.make_rows(side, make_slot(), ctx):
		if str(r.kind) == "armour":
			r.locked = false
			r.label = "Armour"   # the drop-down names the armour; the row says what it is for
			r.choices = make_armour_choices()
			r.choice = r.current
			rows.append(r)
	rows.append_array(ExtractionKitEditor.make_rows(extraction))
	rows.append(InsuredRow.make_row(extraction, make_at_risk_ids()))
	return rows


func find_row(row_key: String) -> Dictionary:
	for r in make_rows():
		if r.key == row_key:
			return r
	return {}


## Saves the profile (and the raid stash) and tells the panels.
func apply_changed() -> void:
	is_dirty = true
	profile.save()
	if extraction != null:
		_apply_raid_armour()
		extraction.save()
	changed.emit()


## The raid kit wears the armour of the open slot (a store purchase or the Look tab may have changed it); the context checks the new kit.
func _apply_raid_armour() -> void:
	extraction.apply_slot_armor(profile)
	ctx.apply_raid_kit(extraction.kit)


## Back to the free default of a look row ("skin" or "herc_skin").
func apply_default_look(row_key: String) -> void:
	LoadoutLayout.apply_clear(make_slot(), row_key)
	apply_changed()
